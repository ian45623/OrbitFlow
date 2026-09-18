import OrbitFlowDictionary
import OrbitFlowAIRewrite
import OrbitFlowHotkey
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    /// Whether the event tap is actually live.
    ///
    /// `false` means the hotkey is dead — almost always a missing Accessibility grant, and
    /// on an ad-hoc-signed build a grant that was working can silently stop satisfying TCC's
    /// stored code-signing requirement. The UI has to say so out loud, because nothing else
    /// about the app looks broken when this happens: the window opens, the record button
    /// works, the key picker offers choices, and holding the key just does nothing.
    private(set) var isHotkeyArmed = false

    /// True while a cloud round-trip is in flight, so the HUD can say "Rewriting…"
    /// instead of showing a resolved-but-frozen transcript for up to eight seconds.
    private(set) var isRewriting = false

    /// A transient message for the pill, shown when no dictation is running.
    ///
    /// The on-demand rewrite's only way to speak. It must not steal focus — the user is
    /// mid-edit in another app and a panel that activates would move their cursor — and the
    /// HUD is already a non-activating panel, so it is the one surface that qualifies.
    private(set) var notice: String?

    /// What the pill's ▶ would read.
    enum ReadAloudOffer: Equatable {
        /// Text Accessibility already handed over.
        case text(String)
        /// A selection in an app that won't share it through Accessibility; ▶ copies it.
        case copy

        var label: String {
            switch self {
            case .text(let text): text
            case .copy: "Read selection"
            }
        }
    }

    /// What the pill is offering to read aloud, or nil.
    ///
    /// Cleared once ▶ has something to speak, and put back by any failure so ▶ retries.
    /// It is separate from whatever `Speaker` is doing on purpose: a highlight made while
    /// the previous passage is still being read is a new offer, and the pill's ▶ belongs to
    /// it rather than to the speech it would otherwise have stopped.
    private(set) var readAloudOffer: ReadAloudOffer?

    /// What the capsule says while a transform is working: the mode's status label, such
    /// as "Summarizing…". Nil once the transform hands off to `Speaker` — including while
    /// ElevenLabs renders, which `HUDView` shows itself from `Speaker.shared.isPreparing`
    /// rather than through this property. Non-nil is also what makes the left disc a ■,
    /// so a transform can be cancelled from the button that started it.
    private(set) var readAloudStatus: String?

    /// A failure the user must see — a rejected key, an exhausted quota, a transform that
    /// timed out. Shown in place of the menu label, in caution amber, and cleared by the
    /// next ▶ or ✕. Unlike an offer, this never fades on a timer: once ▶ is pressed the
    /// user is owed an answer.
    private(set) var readAloudError: String?

    /// Whether the pill is in read-aloud mode: something offered, something transforming,
    /// something being read, or a failure the user hasn't dismissed yet — from the pill,
    /// the History page, or the Settings preview.
    ///
    /// `readAloudStatus` and `readAloudError` have to be here too: a transform can run for
    /// the length of a network round trip between the offer being cleared and `Speaker`
    /// starting, and without this the pill would vanish for that whole window, hiding the
    /// "Summarizing…" label, every error, and the ✕ that is the only way to cancel it.
    ///
    /// `Speaker.shared.isPreparing` and `.failure` are here for the same reason on the far
    /// side of the handoff: a networked voice has its own window where `isSpeaking` is
    /// still false — after `speak()` returns, before the first word — and a failure that
    /// lands after that window must not be shown on a pill that has already dismissed for
    /// having nothing left to say.
    var isReadAloudShowing: Bool {
        readAloudOffer != nil
            || readAloudStatus != nil
            || readAloudError != nil
            || Speaker.shared.isSpeaking
            || Speaker.shared.isPreparing
            || Speaker.shared.failure != nil
    }

    /// True when the read-aloud capsule is carrying words rather than its two menus.
    ///
    /// Lives here rather than in the view because `HUDPanel` sizes the window from it and
    /// `HUDView` draws the capsule from it: if the two disagreed by even one term, the
    /// NSPanel's bounds and what SwiftUI draws inside it would not match, and the capsule
    /// would be clipped or float in a larger transparent window that still eats clicks.
    var isReadAloudMessage: Bool {
        readAloudError != nil || readAloudStatus != nil || Speaker.shared.failure != nil
    }

    /// Whether the pill needs full width right now regardless of the Compact setting.
    ///
    /// A notice — a refusal, a failure, "also copied to clipboard" — is the on-demand
    /// path's only feedback channel, and Compact's 104×26 was sized for a waveform, not a
    /// sentence. `HUDView` (the label) and `HUDPanel` (the window's actual size) both read
    /// this, so the two can never disagree about how big the pill is.
    var needsFullHUD: Bool {
        if notice != nil { return true }
        if case .idle = state, isRewriting { return true }
        return false
    }

    /// Whether the pill is the round read-aloud button rather than the dictation capsule.
    ///
    /// Anything the pill already had a job for comes first. `HUDView` (what's drawn) and
    /// `HUDPanel` (the window's size) both read this, so they can't disagree.
    ///
    /// Stored rather than computed, and refreshed only while the pill has something to show
    /// (see `refreshPillShape`). Pressing ■ stops the speech and starts a 160ms fade-out, and
    /// a live computation would flip to the dictation capsule for exactly that fade —
    /// flashing a pill the user isn't dictating into on their way out of reading.
    private(set) var showsReadAloudButton = false

    /// Called just before the pill is shown, by whoever decides it should be on screen.
    func refreshPillShape() {
        showsReadAloudButton = !state.isActive && notice == nil && !isRewriting && isReadAloudShowing
    }

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so a tier or mode change applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        let settings = Settings.shared
        // Cloud during dictation is exactly `.always`, and nothing else. Reading the
        // setting that owns that decision — rather than inferring it from the tier —
        // is what makes it impossible for `onDemand` to leak an utterance.
        guard settings.aiRewriteUse.rewritesDictation else {
            switch settings.cleanupTier {
            case .rules: return RuleBasedFormatter()
            case .onDevice: return FoundationModelFormatter()
            }
        }
        // Read on the main actor, here, because CloudFormatter's format() is not
        // main-actor isolated and Settings is.
        return CloudFormatter(
            provider: settings.aiProvider,
            model: settings.aiModel,
            key: KeyStore.read(account: settings.aiProvider.rawValue) ?? "",
            mode: settings.rewriteMode
        )
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    /// How long the key can be held before it counts as a hold rather than a tap.
    ///
    /// Below this, the release *latches* recording on instead of ending it, so a tap starts
    /// dictation and the next tap stops it. Above it, the release ends the utterance the way
    /// push-to-talk always has. 0.4s is comfortably longer than a deliberate tap and shorter
    /// than the briefest useful spoken phrase, so neither gesture can be mistaken for the
    /// other.
    private static let tapLatchThreshold: TimeInterval = 0.4

    /// True when a tap latched recording on and only another tap will stop it.
    private var isLatched = false

    /// Identifies the current utterance.
    ///
    /// Discarding has to work *during* `.finishing`, which is exactly when the tail of the
    /// previous run is still in flight — Parakeet transcribes inside `finish()` and smart
    /// cleanup adds seconds on top. Cancelling the tasks isn't enough on its own, because
    /// the work already past its last suspension point will still run to completion and
    /// paste. So the tail re-checks this token before it writes anything, and discarding
    /// simply issues a new one.
    private var runToken = UUID()

    /// Identifies the notice currently on screen, so `flash` can tell "my message is
    /// still showing" from "a message with identical text showed up after mine."
    private var noticeToken = UUID()

    /// The last selection offered, so the pill's own ▶ — a mouse-up made while the
    /// selection is still there — doesn't re-offer it. Cleared by a mouse-up that finds no
    /// selection, so deselecting and re-selecting the same passage offers it again.
    private var lastOfferedSelection: String?

    /// Identifies the offer on screen, for the same reason `noticeToken` exists: an old
    /// offer's fade timer must not clear a newer one.
    private var offerToken = UUID()

    /// Identifies the latest mouse-up. Selection reads finish in whatever order the apps
    /// answer, so a slow read from an earlier click must not offer — or un-remember — a
    /// selection that a later click has already replaced.
    private var mouseUpToken = UUID()

    /// A ▶ on a copy offer is waiting for the app to fill the clipboard. A second press in
    /// that half-second would post a second ⌘C over the first one's restore.
    private var isCopyingSelection = false

    /// The pointer is over the read-aloud button, so an offer must not fade from under it.
    private var isHoveringReadAloud = false

    /// Transformed text for the current selection, keyed by mode.
    ///
    /// You will cycle modes to find the one you want, and every cycle back to a mode you
    /// already heard would otherwise be a second charge for text we already have. Dropped
    /// whenever the selection changes, so it holds at most nine entries and needs no
    /// eviction policy.
    private var transformCache: [ReadingMode: String] = [:]

    /// Set once the long-selection warning has been shown for this selection, so the
    /// second ▶ plays instead of asking again.
    private var lengthConfirmed = false

    /// Identifies the running transform, so a selection change or a mode switch abandons
    /// the old one rather than letting it arrive and speak over the new one.
    private var transformToken = UUID()

    /// The run this selection was filed under, so a completed transform can be appended
    /// to it rather than creating a second History entry.
    private var readAloudRunID: UUID?

    /// The passage the current playback came from, so a mode switch has something to
    /// re-transform. Held rather than re-read from the run log: switching mode would
    /// otherwise decode the user's entire history from disk to recover a string we were
    /// just holding.
    private var readAloudSource: String?

    private var holdStarted: Date?

    /// Where this dictation is going, captured when the key goes down.
    ///
    /// Read at the *start* rather than at insertion on purpose: a cloud rewrite can take
    /// seconds, and by the time the text lands the user may have clicked into something
    /// else. The app they were in when they started talking is the one they meant. The HUD
    /// is a non-activating panel, so the frontmost app is never us.
    private var destination: (name: String, bundleID: String?)?
    private var releasedAt: Date?
    private var engineName = ""

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        hotkey.keys = Settings.shared.shortcutKeys
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onChord = { [weak self] in self?.hotkeyChorded() }
        hotkey.onMouseUp = { [weak self] isGesture in self?.mouseReleased(isGesture: isGesture) }
        // Escape does what the pill's ✕ does, but the swallow decision needs the answer up
        // front: Escape must reach the app underneath unless it cancelled a recording or
        // silenced speech. An offer on its own is cleared and the key still goes through —
        // text selected in a dialog or search field is exactly where Escape means something
        // to that app, and the offer is one the user may not even have looked at.
        hotkey.onEscape = { [weak self] in
            guard let self else { return false }
            if self.state.isActive {
                self.discard()
                return true
            }
            // `isPreparing` covers ElevenLabs rendering: `speak()` returns before any
            // sound is made, and without this Escape would fall through to the app
            // underneath and leave a billed request running uncancelled.
            if Speaker.shared.isSpeaking || Speaker.shared.isPreparing {
                self.stopReadingAloud()
                return true
            }
            // Between the offer being cleared and Speaker starting, a transform can be
            // running with nothing else to show it's there — this is what Escape has to
            // reach to cancel a summary mid-flight.
            if self.readAloudStatus != nil {
                self.stopReadingAloud()
                return true
            }
            // An error holds the pill open until it is dismissed — so Escape has to be
            // able to dismiss it, or ✕ is the only way out.
            if self.readAloudError != nil || Speaker.shared.failure != nil {
                self.stopReadingAloud()
                return true
            }
            if self.readAloudOffer != nil { self.stopReadingAloud() }
            return false
        }
        isHotkeyArmed = hotkey.start()
        return isHotkeyArmed
    }

    func deactivate() {
        hotkey.stop()
        isHotkeyArmed = false
        cancelDictation()
    }

    /// Stops the tap without touching dictation or `isHotkeyArmed`, so Settings can record
    /// a new shortcut without the current ones firing. `reloadHotkey()` resumes it.
    func pauseHotkey() {
        hotkey.stop()
    }

    /// Re-arms the tap after the user changes the shortcut keys.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard case .idle = state else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation()
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    // MARK: - Hotkey gestures

    /// The key went down.
    ///
    /// While anything is running this always means stop — that's the second tap of a latched
    /// recording. Otherwise it starts one.
    private func hotkeyPressed() {
        if state.isActive {
            isLatched = false
            endDictation()
        } else {
            beginDictation()
        }
    }

    /// The key came up.
    ///
    /// A release this soon after the press was a tap, not a hold, so recording stays on and
    /// waits for the next tap. Anything longer is push-to-talk and ends here.
    private func hotkeyReleased() {
        guard state.isActive, !isLatched else { return }

        if let holdStarted, Date().timeIntervalSince(holdStarted) < Self.tapLatchThreshold {
            isLatched = true
            return
        }
        endDictation()
    }

    /// A lone-modifier shortcut turned out to be half of a chord, like ⌘ in ⌘C. Throw away
    /// the recording that press just started — but not one it was stopping, which is
    /// already `.finishing`, nor one a tap latched on earlier.
    private func hotkeyChorded() {
        guard state == .starting || state == .listening, !isLatched else { return }
        discard()
    }

    // MARK: - Pill controls

    /// Stop and paste. The tick on the pill, and exactly what a second tap of the key does.
    func stopAndInsert() {
        guard state.isActive else { return }
        isLatched = false
        endDictation()
    }

    /// Throw this utterance away: nothing is transcribed, nothing is pasted, nothing is
    /// written to the history. The cross on the pill.
    func discard() {
        guard state.isActive else { return }
        runToken = UUID()
        cancelDictation()
    }

    /// Shows `message` in the pill for three seconds.
    ///
    /// The token check matters: two rewrites in quick succession would otherwise have the
    /// first one's timer clear the second one's message three seconds early — including
    /// two identical messages in a row, which is why this compares a token and not the
    /// text.
    func flash(_ message: String) {
        // A notice is feedback for something the user just did; an offer is a guess about
        // what they might want. The notice wins.
        readAloudOffer = nil
        // The user has moved on to whatever produced this notice — abandon any transform
        // still running so it can't arrive later and speak over something else.
        transformToken = UUID()
        readAloudStatus = nil
        notice = message
        noticeToken = UUID()
        let token = noticeToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if noticeToken == token { notice = nil }
        }
    }

    /// Clears any notice and shows or hides "Rewriting…" for an on-demand run.
    ///
    /// Separate from the private `isRewriting` writes in `endDictation`, which are gated on
    /// the dictation run token and must stay that way.
    func setRewriting(_ running: Bool) {
        if running {
            notice = nil
            readAloudOffer = nil
            // The user has moved on to an on-demand rewrite — abandon any read-aloud
            // transform still running so it can't arrive later and speak over it.
            transformToken = UUID()
            readAloudStatus = nil
        }
        isRewriting = running
    }

    // MARK: - Read aloud

    /// ▶ on the capsule: get the text if it isn't in hand yet, file it in History,
    /// transform it if the mode asks for that, then read it.
    ///
    /// Filed only here, never on highlight. Selecting text is constant — to delete it,
    /// drag it, copy an address — and History should hold what the user chose to hear.
    func readAloud() {
        guard let offer = readAloudOffer else {
            // A voice failure lands after the offer is gone: `Speaker` fails asynchronously,
            // so unlike a transform failure there is nothing to put back at the time it
            // happens. The passage is still here, so ▶ retries it rather than being a disc
            // that is drawn and does nothing. The transform is cached, so this costs one
            // voice call, not two.
            if Speaker.shared.failure != nil, let source = readAloudSource {
                Speaker.shared.clearFailure()
                begin(source)
            }
            return
        }
        // Pressed, so it must not fade out from under a copy that's still running.
        offerToken = UUID()
        readAloudError = nil

        switch offer {
        case .text(let text):
            readAloudOffer = nil
            begin(text)
        case .copy:
            guard !isCopyingSelection else { return }
            isCopyingSelection = true
            Task { @MainActor in
                let text = await SelectedText.copy()
                isCopyingSelection = false
                // ✕, Escape, the talk key or a notice may have taken the pill while the app
                // was copying; any of them means the user has moved on.
                guard readAloudOffer == .copy else { return }
                readAloudOffer = nil
                guard let text else {
                    flash("Couldn't copy that selection.")
                    return
                }
                begin(text)
            }
        }
    }

    /// The length gate, then History, then the pipeline.
    private func begin(_ text: String) {
        let mode = Settings.shared.readingMode

        // Only As-is can reach this: every other mode shrinks the passage before a
        // character is billed, so warning about the input length would be the wrong number.
        let words = text.split(whereSeparator: \.isWhitespace).count
        if ReadingMode.needsLengthConfirm(
            mode: mode, wordCount: words, alreadyAsked: lengthConfirmed
        ) {
            lengthConfirmed = true
            // Put the offer back so ▶ is still there to press a second time, and hold the
            // capsule open — a question that fades before it can be answered is worse than
            // no question.
            readAloudOffer = .text(text)
            // "3,000 words?" rather than a sentence: the capsule is sized for a mode
            // name, and the number is the whole question.
            readAloudError = "\(words.formatted()) words?"
            return
        }

        // Filed before the transform, so a failed summary still leaves the passage saved —
        // and filed once per passage: a ▶ that retries after a failure, or after a mode
        // switch, is the same passage and belongs in the same entry.
        if readAloudSource != text {
            let run = DictationRun(
                date: Date(),
                engine: "Read aloud",
                audioSeconds: 0,
                processSeconds: 0,
                text: text
            )
            RunLog.record(run)
            readAloudRunID = run.id
            readAloudSource = text
        }

        transformAndSpeak(text, mode: mode)
    }

    /// Stage one: get the text this mode wants spoken. Stage two is `Speaker`.
    private func transformAndSpeak(_ source: String, mode: ReadingMode) {
        guard mode.usesAI else {
            readAloudStatus = nil
            Speaker.shared.speak(source)
            return
        }

        if let cached = transformCache[mode] {
            readAloudStatus = nil
            Speaker.shared.speak(cached)
            return
        }

        // The menu disables Custom while the instruction is blank, but Settings can leave
        // `readingMode` on `.custom` after the user clears the field there — and a blank
        // instruction still produces a preamble-only prompt, which would bill for nothing.
        if mode == .custom,
           Settings.shared.readingModeCustomInstruction
               .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failed("No prompt", source: source)
            return
        }

        let target = resolvedTarget()
        let engine = OnDemandRewrite.engine(
            use: Settings.shared.aiRewriteUse,
            hasKey: KeyStore.hasKey(account: target.provider.rawValue),
            model: target.model,
            onDeviceAvailable: OnDeviceRewriter.isAvailable
        )

        let chosen: OnDemandRewrite.Engine
        switch engine {
        case .success(let value):
            chosen = value
        case .failure(let unavailable):
            failed(unavailable.keyword, source: source)
            return
        }

        let system = mode == .custom
            ? ReadingMode.customSystemPrompt(Settings.shared.readingModeCustomInstruction)
            : mode.systemPrompt
        let key = chosen == .cloud
            ? (KeyStore.read(account: target.provider.rawValue) ?? "")
            : ""
        let engineLabel = chosen == .cloud
            ? "\(target.provider.displayName) · \(target.model)"
            : "Apple on-device"
        let runID = readAloudRunID

        transformToken = UUID()
        let token = transformToken
        readAloudStatus = ReadingMode.workingKeyword

        Task { @MainActor in
            do {
                let output: String
                // 30 s, not dictation's 8 s. Nothing is waiting to be typed, and a
                // page-length summary legitimately takes longer than a sentence cleanup.
                // The guard is `nil` on purpose: every reading mode violates the
                // invented-words and length-ratio checks by construction.
                if chosen == .cloud {
                    output = try await CloudRewriter(
                        provider: target.provider, key: key, timeout: .seconds(30)
                    ).rewrite(source, model: target.model, system: system, checking: nil)
                } else {
                    output = try await OnDeviceRewriter.rewrite(
                        source, system: system, timeout: .seconds(60)
                    )
                }

                // A newer selection or mode switch superseded this one while it ran.
                guard transformToken == token else { return }

                // `enforce` before anything else sees it — the cache, History, the voice — so
                // a model that ignored One line's word limit is still held to one line, and
                // what is saved is what was heard.
                let trimmed = mode.enforce(output.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !trimmed.isEmpty else {
                    failed("Empty", source: source)
                    return
                }

                transformCache[mode] = trimmed
                if let runID {
                    RunLog.modify(runID) { run in
                        var rewrites = run.rewrites ?? []
                        rewrites.append(
                            Rewrite(
                                date: Date(),
                                instruction: mode.displayName,
                                engine: engineLabel,
                                source: source,
                                text: trimmed
                            )
                        )
                        run.rewrites = rewrites
                    }
                }

                readAloudStatus = nil
                Speaker.shared.speak(trimmed)
            } catch {
                guard transformToken == token else { return }
                // Never fall back to reading the original: you asked for a summary, and
                // being handed the whole page instead is the one outcome this feature
                // exists to prevent.
                // The keyword, not the sentence: the capsule has room for a mode name.
                // On-device failures have no keyword of their own and are rare enough to
                // share one.
                failed((error as? RewriteFailure)?.keyword ?? "Failed", source: source)
            }
        }
    }

    /// Shows `message` and leaves the passage on offer, so ▶ tries it again — with another
    /// mode picked from the menu beside it, or the same one once a key is in place. The
    /// pill is the whole interface here; a failure that removes its only two controls is a
    /// dead end you can't even retry your way out of. The run stays filed under
    /// `readAloudRunID`, so the retry appends to that entry instead of making a second one.
    private func failed(_ message: String, source: String) {
        readAloudStatus = nil
        readAloudError = message
        readAloudOffer = .text(source)
    }

    /// Which provider and model read aloud bills — the shared pair unless the user split
    /// them. See `AITarget`.
    private func resolvedTarget() -> AITarget.Resolved {
        let settings = Settings.shared
        return AITarget.resolve(
            sharedProvider: settings.aiProvider,
            sharedModel: settings.aiModel,
            overrideProvider: settings.readAloudProviderOverride,
            overrideModel: settings.readAloudModelOverride
        )
    }

    /// ✕, ■ and Escape: stop speaking and drop any offer.
    func stopReadingAloud() {
        offerToken = UUID()
        transformToken = UUID()
        readAloudOffer = nil
        readAloudStatus = nil
        readAloudError = nil
        readAloudSource = nil
        transformCache = [:]
        lengthConfirmed = false
        readAloudRunID = nil
        Speaker.shared.stop()
    }

    /// The capsule's speed menu.
    ///
    /// Unlike the mode, this needs no re-transform and no re-render: speed is applied on
    /// playback, so the change is free. It still restarts the passage, because
    /// `AVSpeechUtterance.rate` and `AVAudioPlayer.rate` are both fixed for the life of the
    /// thing playing — there is no way to change either mid-sentence. The ElevenLabs audio
    /// comes straight back out of the cache, so restarting costs nothing.
    func setReadingSpeed(_ speed: Double) {
        guard speed != Settings.shared.readAloudSpeed else { return }
        Settings.shared.readAloudSpeed = speed

        guard Speaker.shared.isSpeaking || Speaker.shared.isPreparing,
              let text = Speaker.shared.spokenText
        else { return }
        Speaker.shared.speak(text)
    }

    /// The capsule's mode menu. A live control, not a preference for next time: change it
    /// mid-playback and the same passage is re-transformed and spoken from the top. Going
    /// back to a mode you already heard is served from the cache — free and instant.
    func setReadingMode(_ mode: ReadingMode) {
        guard mode != Settings.shared.readingMode else { return }
        Settings.shared.readingMode = mode
        readAloudError = nil

        // A transform in flight counts as "already playing" here — `wasSpeaking` alone is
        // false for the whole window between the offer clearing and `Speaker` starting,
        // which would otherwise abandon the in-flight call below and start nothing to
        // replace it.
        let wasSpeaking = Speaker.shared.isSpeaking
            || Speaker.shared.isPreparing
            || readAloudStatus != nil
        let source = readAloudSource
        Speaker.shared.stop()
        transformToken = UUID()
        readAloudStatus = nil

        // Through `begin`, not straight to the transform: the ≥2,000-word confirm lives
        // there, and switching to As-is mid-playback is exactly how a whole page reaches
        // the voice without being asked about. `begin` files no second run for a passage
        // it has already filed.
        guard wasSpeaking, let source else { return }
        begin(source)
    }

    private func mouseReleased(isGesture: Bool) {
        guard Settings.shared.readAloudEnabled else { return }
        mouseUpToken = UUID()
        let token = mouseUpToken
        Task { @MainActor in
            // The tap sees the mouse-up before the app under the cursor has handled it, so
            // the selection isn't final yet at this instant.
            try? await Task.sleep(for: .milliseconds(50))
            // A click that came in during the wait has its own read coming.
            guard mouseUpToken == token else { return }

            guard let pid = SelectedText.frontmostAppPID() else { return }
            var reading = await Task.detached(priority: .userInitiated) {
                SelectedText.read(pid: pid)
            }.value

            // Chrome updates its Accessibility selection a beat after the mouse-up, so a
            // selection gesture that came back with nothing gets one more look. Plain clicks
            // don't: they can't have selected anything, and they are most clicks.
            if isGesture, reading == .empty || reading == .unknown {
                try? await Task.sleep(for: .milliseconds(250))
                guard mouseUpToken == token else { return }
                reading = await Task.detached(priority: .userInitiated) {
                    SelectedText.read(pid: pid)
                }.value
            }
            guard mouseUpToken == token else { return }

            let decision = readAloudDecision(
                reading: reading,
                isGesture: isGesture,
                lastOffered: lastOfferedSelection,
                enabled: Settings.shared.readAloudEnabled,
                isBusy: state.isActive || isRewriting || notice != nil
            )
            switch decision {
            case .none:
                if reading == .empty || reading == .unknown { lastOfferedSelection = nil }
            case .offerText(let text):
                lastOfferedSelection = text
                offerReadAloud(.text(text))
            case .offerCopy:
                lastOfferedSelection = nil
                offerReadAloud(.copy)
            }
        }
    }

    /// Shows ▶ for `offer`, fading after five seconds if it isn't pressed.
    private func offerReadAloud(_ offer: ReadAloudOffer) {
        readAloudOffer = offer
        // A new selection invalidates everything derived from the old one — including a
        // transform still in flight for the old one, which must not be allowed to resume,
        // speak over this offer, and poison this selection's cache with the old text.
        transformCache = [:]
        lengthConfirmed = false
        readAloudRunID = nil
        readAloudSource = nil
        readAloudError = nil
        // The other half of the same error: `Speaker`'s failure outranks the status in the
        // capsule and is only cleared by `speak` or `stop`, neither of which runs here —
        // `offerReadAloud` deliberately leaves the previous passage playing.
        Speaker.shared.clearFailure()
        transformToken = UUID()
        readAloudStatus = nil
        // A new offer appears where the last one was; a pointer left resting there from
        // before shouldn't pin it open, and SwiftUI won't report the exit of a view it
        // already replaced.
        isHoveringReadAloud = false
        scheduleOfferFade()
    }

    private func scheduleOfferFade() {
        offerToken = UUID()
        let token = offerToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if offerToken == token, !isHoveringReadAloud { readAloudOffer = nil }
        }
    }

    /// The pointer entered or left the read-aloud button. Leaving gives an offer a fresh
    /// five seconds rather than whatever was left of the first, which may already be gone.
    func setHoveringReadAloud(_ hovering: Bool) {
        isHoveringReadAloud = hovering
        // Anything the user is owed an answer to — the long-selection question, a failure
        // with ▶ still there to retry — stays up until it is answered. Both set
        // `readAloudError`, both skipped their own fade when they put the offer back, and
        // re-arming one here on mouse-out would dismiss them behind the user's back.
        if !hovering, readAloudOffer != nil, !isCopyingSelection, readAloudError == nil {
            scheduleOfferFade()
        }
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        // An offer is a guess about what the user wants next, and this press says otherwise.
        // Speech is left alone until just before capture — see there.
        offerToken = UUID()
        readAloudOffer = nil
        // The talk key means the user is dictating now — a transform that resumes after
        // this must not call `Speaker.shared.speak` into the microphone that's about to
        // open.
        transformToken = UUID()
        readAloudStatus = nil
        isLatched = false
        runToken = UUID()
        state = .starting
        transcript = ""
        holdStarted = Date()
        destination = Self.frontmostApp()
        isComparing = Settings.shared.compareMode
        recorded.removeAll(keepingCapacity: true)
        engineName = isComparing ? "Comparing…" : Settings.shared.engine.displayName

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                guard let format = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                let comparing = isComparing
                self.feedTask = Task.detached(priority: .userInitiated) {
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        if comparing { recording.append(chunk) }
                        await engine.feed(chunk)
                    }
                    return recording
                }

                // Before the microphone opens, or it transcribes the voice reading aloud.
                // Not at the top of `beginDictation`: a lone-modifier talk key goes down as
                // the first half of every chord that uses it (⌥-characters, ⌃-shortcuts), and
                // `hotkeyChorded` throws that dictation away — but stopped speech would
                // already be gone. Waiting for the engine to spin up gives the chord's other
                // key time to arrive and move the state off `.starting`.
                if case .starting = self.state { Speaker.shared.stop() }
                try capture.start(
                    outputFormat: format,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        let token = runToken
        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            recorded = await feedTask?.value ?? []
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil

            guard token == runToken else { return }

            if isComparing {
                await runComparison()
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                transcript = ""
                return
            }

            // Only the cloud rewrite triggered by Always is slow enough to need saying
            // out loud; rules are instant and the on-device pass is bounded at four
            // seconds.
            //
            // Both writes are gated on the run token. Discarding does not cancel the tail
            // — it issues a new token and lets the in-flight work finish, suppressing only
            // the paste. So a discarded utterance's cloud call can return *after* the user
            // has started a new dictation, and an ungated reset would clear the flag out
            // from under the live run: the HUD would stop saying "Rewriting…" while it is
            // still, in fact, rewriting.
            if token == runToken {
                isRewriting = Settings.shared.cleanupEnabled
                    && Settings.shared.aiRewriteUse.rewritesDictation
            }
            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw)
                : raw
            if token == runToken { isRewriting = false }

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            // Last check before anything leaves the app: cleanup and the dictionary are
            // both awaits, so the discard button may have been pressed since the guard above.
            guard token == runToken else { return }

            // `cleaned != raw` is the only honest test for "the rewrite did something":
            // the tier can be off, and a cloud call can fail and fall back to the raw text.
            recordRun(
                text: output,
                corrections: corrections,
                original: cleaned == raw ? nil : raw,
                draft: cleaned == raw ? nil : draftRecord(source: raw, text: cleaned)
            )
            TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
        }
    }

    private func cancelDictation() {
        isLatched = false
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
    }

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
    }

    // MARK: - Helpers

    private func retainForComparison(_ chunk: AudioChunk) {
        guard isComparing else { return }
        recorded.append(chunk)
    }

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                RunLog.record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    /// The dictation-time rewrite, described the way the detail page describes the ones
    /// run by hand — so the stack there starts with what actually produced the text that
    /// got pasted, rather than an unlabelled first entry.
    private func draftRecord(source: String, text: String) -> Rewrite {
        let settings = Settings.shared
        let instruction: String
        let engine: String
        if settings.aiRewriteUse.rewritesDictation {
            instruction = settings.rewriteMode.displayName
            engine = "\(settings.aiProvider.displayName) · \(settings.aiModel)"
        } else {
            instruction = "Cleanup"
            engine = settings.cleanupTier == .onDevice ? "Apple on-device" : "Rules"
        }
        return Rewrite(
            date: Date(),
            instruction: instruction,
            engine: engine,
            source: source,
            text: text
        )
    }

    private func recordRun(
        text: String,
        corrections: [AppliedCorrection] = [],
        original: String? = nil,
        draft: Rewrite? = nil
    ) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections,
                original: original,
                rewrites: draft.map { [$0] },
                destinationApp: destination?.name,
                destinationBundleID: destination?.bundleID
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
        self.destination = nil
    }

    /// The app in front right now, unless that is us — dictating into Orbit Flow's own
    /// window (onboarding's test box, the compose row) has no external destination.
    private static func frontmostApp() -> (name: String, bundleID: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName
        else { return nil }
        return (name, app.bundleIdentifier)
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}

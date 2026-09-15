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

    /// Highlighted text the pill is offering to read aloud, or nil.
    ///
    /// Cleared the moment ▶ is pressed: from then on the pill shows `Speaker.shared.text`,
    /// which is what is actually being spoken. Keeping the two apart is what lets a new
    /// highlight be offered while the previous one is still being read.
    private(set) var readAloudOffer: String?

    /// Whether the pill is in read-aloud mode: something offered, or something being read —
    /// from the pill, the History page, or the Settings preview.
    var isReadAloudShowing: Bool {
        readAloudOffer != nil || Speaker.shared.isSpeaking
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
        // An offer is only useful if you can see what it's offering, and Compact has no
        // room for a word of it. Ignored while a dictation is active: the pill belongs to
        // the recording then (`HUDView.isReadingAloud` already hides the read-aloud
        // controls), so speech started elsewhere must not resize a Compact pill out from
        // under it.
        if isReadAloudShowing, !state.isActive { return true }
        return false
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
            key: Keychain.read(account: settings.aiProvider.rawValue) ?? "",
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

    private var holdStarted: Date?
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
        // Escape does exactly what the pill's ✕ does. `discard()` already ignores a call
        // when nothing is running, but the swallow decision needs the answer up front:
        // Escape must reach the app underneath whenever there's no recording to cancel.
        hotkey.onMouseUp = { [weak self] in self?.mouseReleased() }
        // Escape is also the keyboard ✕ for read aloud. Still swallowed only when there is
        // something of ours to cancel.
        hotkey.onEscape = { [weak self] in
            guard let self else { return false }
            if self.state.isActive {
                self.discard()
                return true
            }
            if self.isReadAloudShowing {
                self.stopReadingAloud()
                return true
            }
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
        }
        isRewriting = running
    }

    // MARK: - Read aloud

    /// ▶ on the pill: file the offered text in History, then read it.
    ///
    /// Filed only here, never on highlight. Selecting text is constant — to delete it, drag
    /// it, copy an address — and History should hold what the user chose to hear.
    func readAloud() {
        guard let text = readAloudOffer else { return }
        offerToken = UUID()
        readAloudOffer = nil
        RunLog.record(
            DictationRun(
                date: Date(),
                engine: "Read aloud",
                audioSeconds: 0,
                processSeconds: 0,
                text: text
            )
        )
        Speaker.shared.speak(text)
    }

    /// ✕, ■ and Escape: stop speaking and drop any offer.
    func stopReadingAloud() {
        offerToken = UUID()
        readAloudOffer = nil
        Speaker.shared.stop()
    }

    private func mouseReleased() {
        guard Settings.shared.readAloudEnabled else { return }
        mouseUpToken = UUID()
        let token = mouseUpToken
        Task { @MainActor in
            // The tap sees the mouse-up before the app under the cursor has handled it, so
            // the selection isn't final yet at this instant.
            try? await Task.sleep(for: .milliseconds(50))
            // A click that came in during the wait has its own read coming.
            guard mouseUpToken == token else { return }

            let pid = SelectedText.frontmostAppPID()
            let read = await Task.detached(priority: .userInitiated) {
                pid.flatMap { SelectedText.read(pid: $0) }
            }.value
            guard mouseUpToken == token else { return }

            guard let text = read else {
                lastOfferedSelection = nil
                return
            }
            guard shouldOfferReadAloud(
                text: text,
                lastOffered: lastOfferedSelection,
                enabled: Settings.shared.readAloudEnabled,
                isBusy: state.isActive || isRewriting || notice != nil
            ) else { return }

            offerReadAloud(text)
        }
    }

    /// Shows ▶ for `text`, fading after four seconds if it isn't pressed.
    private func offerReadAloud(_ text: String) {
        lastOfferedSelection = text
        readAloudOffer = text
        offerToken = UUID()
        let token = offerToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if offerToken == token { readAloudOffer = nil }
        }
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        // An offer is a guess about what the user wants next, and this press says otherwise.
        // Speech is left alone until just before capture — see there.
        offerToken = UUID()
        readAloudOffer = nil
        isLatched = false
        runToken = UUID()
        state = .starting
        transcript = ""
        holdStarted = Date()
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
                rewrites: draft.map { [$0] }
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
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

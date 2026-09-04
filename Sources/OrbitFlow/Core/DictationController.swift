import OrbitFlowDictionary
import OrbitFlowAIRewrite
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

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so a tier or mode change applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        let settings = Settings.shared
        switch settings.cleanupTier {
        case .rules:
            return RuleBasedFormatter()
        case .onDevice:
            return FoundationModelFormatter()
        case .cloud:
            // Read on the main actor, here, because CloudFormatter's format() is not
            // main-actor isolated and Settings is.
            return CloudFormatter(
                provider: settings.aiProvider,
                model: settings.aiModel,
                key: Keychain.read(account: settings.aiProvider.rawValue) ?? "",
                mode: settings.rewriteMode
            )
        }
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
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        // Escape does exactly what the pill's ✕ does. `discard()` already ignores a call
        // when nothing is running, but the swallow decision needs the answer up front:
        // Escape must reach the app underneath whenever there's no recording to cancel.
        hotkey.onEscape = { [weak self] in
            guard let self, self.state.isActive else { return false }
            self.discard()
            return true
        }
        isHotkeyArmed = hotkey.start()
        return isHotkeyArmed
    }

    func deactivate() {
        hotkey.stop()
        isHotkeyArmed = false
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
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

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
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

            // Only the cloud tier is slow enough to need saying out loud; rules are
            // instant and the on-device pass is bounded at four seconds.
            //
            // Both writes are gated on the run token. Discarding does not cancel the tail
            // — it issues a new token and lets the in-flight work finish, suppressing only
            // the paste. So a discarded utterance's cloud call can return *after* the user
            // has started a new dictation, and an ungated reset would clear the flag out
            // from under the live run: the HUD would stop saying "Rewriting…" while it is
            // still, in fact, rewriting.
            if token == runToken {
                isRewriting = Settings.shared.cleanupEnabled
                    && Settings.shared.cleanupTier == .cloud
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
        switch settings.cleanupTier {
        case .cloud:
            instruction = settings.rewriteMode.displayName
            engine = "\(settings.aiProvider.displayName) · \(settings.aiModel)"
        case .onDevice:
            instruction = "Cleanup"
            engine = "Apple on-device"
        case .rules:
            instruction = "Cleanup"
            engine = "Rules"
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

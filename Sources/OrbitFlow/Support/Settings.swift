import AVFoundation
import Foundation
import Observation
import OrbitFlowAIRewrite
import OrbitFlowHistory
import OrbitFlowHotkey
import OrbitFlowModels

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

/// Which *local* pass cleans a transcript before it's injected.
///
/// No longer expresses the cloud: `AIRewriteUse` owns that decision now, and having two
/// properties able to disagree about whether text leaves the Mac is not a risk worth
/// carrying. The `cloud` case that used to live here is migrated away in `init`.
///
/// No UI sets this any more, either — the Rules/On-device picker went away with the
/// `cloud` case it used to disambiguate. `Settings.init`'s migration is now the only
/// writer: on-device for a user who had `smartCleanup` on, rules for everyone else.
/// Reintroducing a picker for it is new scope, not a fix for the dead end this
/// migration leaves behind.
enum CleanupTier: String, Sendable {
    /// Deterministic, zero-latency, always available.
    case rules
    /// Apple's on-device Foundation Model. Nothing leaves the Mac.
    case onDevice
}

/// How much of the dictation pill to show while you're talking.
enum HUDSize: String, CaseIterable, Sendable {
    /// Just the waveform. Small enough to ignore, big enough to confirm it's hearing you.
    case compact
    /// Waveform, record lamp, and the transcript as it resolves.
    case full

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .full: "Full"
        }
    }

    /// The size of the visible capsule. The panel behind it is larger — see
    /// `HUDPanel.shadowMargin`.
    var pillSize: CGSize {
        switch self {
        case .compact: CGSize(width: 104, height: 26)
        case .full: CGSize(width: 300, height: 36)
        }
    }

    /// Diameter of the discard and confirm discs.
    var controlSize: CGFloat {
        switch self {
        case .compact: 18
        case .full: 24
        }
    }

    /// Width given to the level trace. The rest of the pill is controls, and in `full`
    /// whatever is left over goes to the transcript.
    var waveWidth: CGFloat {
        switch self {
        case .compact: 46
        case .full: 60
        }
    }
}

/// Which synthesizer speaks.
///
/// A setting rather than an automatic fallback: switching voice, speed and character
/// mid-passage because a network call failed is more confusing than an error that says
/// the key is wrong.
enum VoiceEngine: String, CaseIterable, Sendable {
    /// `AVSpeechSynthesizer`. Free, offline, installed voices only.
    case system
    /// ElevenLabs over the network, billed per character.
    case elevenLabs
    /// Kokoro-82M on the Neural Engine. Downloaded, and nothing leaves the Mac.
    case kokoro

    var displayName: String {
        switch self {
        case .system: "System"
        case .elevenLabs: "ElevenLabs"
        case .kokoro: "Kokoro"
        }
    }
}

/// Which auto-delete rule the History & privacy section is running.
///
/// Off is a case here rather than a sentinel number, so "nothing is being deleted" is as
/// explicit in storage as it is on screen.
enum HistoryRetentionMode: String, CaseIterable, Sendable {
    case off
    case count
    case age

    var displayName: String {
        switch self {
        case .off: "Off"
        case .count: "Keep the newest dictations"
        case .age: "Keep recent dictations"
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var shortcutKeys: [Shortcut] {
        didSet { defaults.set(try? JSONEncoder().encode(shortcutKeys), forKey: Keys.shortcuts) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Install a newer build as soon as the periodic check finds one and nothing is in
    /// flight. Off by default: quitting and relaunching is something to opt into.
    var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) }
    }

    /// The user has been through onboarding — finished it or skipped it. Onboarding still
    /// reopens on a later launch if a permission has gone missing, so this records "don't
    /// greet me again", not "setup is complete".
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Which cleanup pass runs. Gated by `cleanupEnabled` — off means raw engine output
    /// whatever this says.
    var cleanupTier: CleanupTier {
        didSet { defaults.set(cleanupTier.rawValue, forKey: Keys.cleanupTier) }
    }

    /// When the AI rewrite runs: never, only when asked from the Services menu, or on
    /// every dictation.
    var aiRewriteUse: AIRewriteUse {
        didSet { defaults.set(aiRewriteUse.rawValue, forKey: Keys.aiRewriteUse) }
    }

    /// Which cloud provider the rewrite tier calls. The API key lives in the key store,
    /// never here.
    var aiProvider: AIProvider {
        didSet { defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }

    /// Which rewrite engine runs — the AI Models page's Rewrite row.
    ///
    /// New in this build. Before it, the engine was implicit: a stored key and model
    /// meant cloud, anything else meant on-device. That rule is reproduced in `init`, and
    /// `init` writes the result back to defaults itself — `didSet` does not fire during
    /// initialization — so it is stored, not just inferred fresh every launch. Without
    /// that write, a user who pastes in a key and a model gets Apple on-device until they
    /// quit and relaunch, because the in-memory value from this launch's inference never
    /// reaches disk. From here it is a choice.
    var rewriteSource: ModelSource {
        didSet { defaults.set(rewriteSource.rawValue, forKey: Keys.rewriteSource) }
    }

    /// Free text, because the model list is fetched from the provider and a provider may
    /// serve a model our parsing missed.
    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Keys.aiModel) }
    }

    /// The tone AI rewrite uses — for dictation under Always, and for the default
    /// right-click Services row whenever the setting isn't Off.
    var rewriteMode: RewriteMode {
        didSet { defaults.set(rewriteMode.rawValue, forKey: Keys.rewriteMode) }
    }

    /// How much the floating dictation pill shows.
    var hudSize: HUDSize {
        didSet { defaults.set(hudSize.rawValue, forKey: Keys.hudSize) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Offer to read highlighted text aloud from the pill.
    ///
    /// Off by default: with it on, the pill appears every time a selection is made with the
    /// mouse in any app, which is only welcome if you asked for it.
    var readAloudEnabled: Bool {
        didSet { defaults.set(readAloudEnabled, forKey: Keys.readAloudEnabled) }
    }

    /// An `AVSpeechSynthesisVoice` identifier. Nil means the system default voice — and so
    /// does an identifier whose voice has since been uninstalled, because
    /// `AVSpeechSynthesisVoice(identifier:)` returns nil for it and the utterance falls back.
    var readAloudVoice: String? {
        didSet { defaults.set(readAloudVoice, forKey: Keys.readAloudVoice) }
    }

    /// Which Kokoro voice speaks. Separate from `readAloudVoice`, which names an
    /// AVSpeechSynthesis voice — the two vocabularies have nothing in common.
    var readAloudLocalVoice: String {
        didSet { defaults.set(readAloudLocalVoice, forKey: Keys.readAloudLocalVoice) }
    }

    /// How fast the voice reads, as a multiple of its natural rate.
    ///
    /// One setting for both engines, because it is applied as a playback rate rather than
    /// asked of the synthesizer or of ElevenLabs — see `ReadingMode.speeds`. It replaced a
    /// pair of sliders (an `AVSpeechUtterance` rate and ElevenLabs' own `speed`) that
    /// disagreed about what "1.5×" meant and could not both be shown on the pill.
    var readAloudSpeed: Double {
        didSet { defaults.set(readAloudSpeed, forKey: Keys.readAloudSpeed) }
    }

    /// How the selection is transformed before it is spoken.
    ///
    /// `.asIs` by default, which makes no network call at all — the feature must not start
    /// spending the user's AI credits, or sending their selections anywhere, on an upgrade
    /// they didn't ask for.
    var readingMode: ReadingMode {
        didSet { defaults.set(readingMode.rawValue, forKey: Keys.readingMode) }
    }

    var readingModeCustomLabel: String {
        didSet { defaults.set(readingModeCustomLabel, forKey: Keys.readingModeCustomLabel) }
    }

    var readingModeCustomInstruction: String {
        didSet {
            defaults.set(readingModeCustomInstruction, forKey: Keys.readingModeCustomInstruction)
        }
    }

    /// `nil` — the default — means read aloud uses `aiProvider` and `aiModel`, so no API
    /// key is ever entered twice. Set it only to split read aloud onto a different
    /// provider than the rewrite tier. Resolved through `AITarget.resolve`.
    var readAloudProviderOverride: AIProvider? {
        didSet {
            defaults.set(readAloudProviderOverride?.rawValue, forKey: Keys.readAloudProviderOverride)
        }
    }

    /// Read only when `readAloudProviderOverride` is set. See `AITarget.resolve`.
    var readAloudModelOverride: String {
        didSet { defaults.set(readAloudModelOverride, forKey: Keys.readAloudModelOverride) }
    }

    var readAloudEngine: VoiceEngine {
        didSet { defaults.set(readAloudEngine.rawValue, forKey: Keys.readAloudEngine) }
    }

    var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: Keys.elevenLabsVoiceID) }
    }

    var elevenLabsModel: String {
        didSet { defaults.set(elevenLabsModel, forKey: Keys.elevenLabsModel) }
    }

    /// Which auto-delete rule runs, if any. Off by default — a feature that deletes the
    /// user's own data without asking has to be opted into.
    ///
    /// The mode is stored apart from the two numbers it selects between, so switching
    /// count → age → count comes back to the count you had rather than to a default.
    var historyMode: HistoryRetentionMode {
        didSet { defaults.set(historyMode.rawValue, forKey: Keys.historyMode) }
    }

    /// How many dictations `historyMode == .count` keeps.
    var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) }
    }

    /// How many days `historyMode == .age` keeps. One of `RetentionRule.dayPresets`.
    var historyDays: Int {
        didSet { defaults.set(historyDays, forKey: Keys.historyDays) }
    }

    /// Pinned dictations are exempt from `historyLimit`: never auto-deleted, and never
    /// counted against it. On by default — pinning is the only undo this feature has.
    var historyKeepsPinned: Bool {
        didSet { defaults.set(historyKeepsPinned, forKey: Keys.historyKeepsPinned) }
    }

    /// What `RunLog` enforces after each dictation. Assembling the rule here is what keeps
    /// the two numbers from ever being live at once — only the mode decides which is read.
    var retentionPolicy: RetentionPolicy {
        let rule: RetentionRule = switch historyMode {
        case .off: .keepEverything
        case .count: .newest(historyLimit)
        case .age: .within(days: historyDays)
        }
        return RetentionPolicy(rule: rule, keepsPinned: historyKeepsPinned)
    }

    /// The slider's travel. The floor is deliberately not 1: a cap low enough to delete
    /// this morning's work before lunch is a mistake the UI shouldn't offer.
    static let historyLimitRange = 50...2000
    /// Where the slider lands the first time auto-delete is switched on. High enough that
    /// one click can't vaporise a month of history.
    static let defaultHistoryLimit = 250
    /// Slider granularity. Fine enough to stop on 145 or 175, coarse enough to drag.
    ///
    /// Applied by rounding in the binding rather than by `Slider`'s `step:`, which draws a
    /// tick per step — 390 of them merge into a solid line under the track.
    static let historyLimitStep = 5
    /// Where the age slider lands the first time that mode is chosen.
    static let defaultHistoryDays = 30

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let shortcuts = "shortcuts"
        /// Read only to migrate: the preset-name list, then the original single key.
        static let previousShortcutKeys = "shortcutKeys"
        static let legacyPushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        /// Read once, never written: migrated into `cleanupTier` in `init`.
        static let legacySmartCleanup = "smartCleanup"
        static let cleanupTier = "cleanupTier"
        static let aiRewriteUse = "aiRewriteUse"
        /// Read once, never written: the restore slot the old AI-rewrite toggle used,
        /// consumed by the migration in `init`.
        static let legacyTierBeforeCloud = "tierBeforeCloud"
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        static let rewriteSource = "rewriteSource"
        static let rewriteMode = "rewriteMode"
        static let autoUpdate = "autoUpdate"
        static let onboardingCompleted = "onboardingCompleted"
        static let hudSize = "hudSize"
        static let readAloudEnabled = "readAloudEnabled"
        static let readAloudVoice = "readAloudVoice"
        static let readAloudLocalVoice = "readAloudLocalVoice"
        static let readAloudSpeed = "readAloudSpeed"
        static let readingMode = "readingMode"
        static let readingModeCustomLabel = "readingModeCustomLabel"
        static let readingModeCustomInstruction = "readingModeCustomInstruction"
        static let readAloudProviderOverride = "readAloudProviderOverride"
        static let readAloudModelOverride = "readAloudModelOverride"
        static let readAloudEngine = "readAloudEngine"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let elevenLabsModel = "elevenLabsModel"
        static let historyMode = "historyMode"
        static let historyLimit = "historyLimit"
        static let historyDays = "historyDays"
        static let historyKeepsPinned = "historyKeepsPinned"
    }

    private init() {
        let resolvedKeys = ShortcutKeys.resolved(
            stored: defaults.data(forKey: Keys.shortcuts),
            previous: defaults.array(forKey: Keys.previousShortcutKeys) as? [String],
            legacy: defaults.string(forKey: Keys.legacyPushToTalkKey)
        )
        shortcutKeys = resolvedKeys
        defaults.set(try? JSONEncoder().encode(resolvedKeys), forKey: Keys.shortcuts)
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        // `cloud` is no longer a tier. A user who had it selected was saying "rewrite every
        // dictation", which is now `aiRewriteUse == .always`, and the tier underneath goes back
        // to whatever the old toggle would have restored.
        let storedTier = defaults.string(forKey: Keys.cleanupTier)
        let tierWasCloud = storedTier == "cloud"

        aiRewriteUse = AIRewriteUse.resolve(
            stored: defaults.string(forKey: Keys.aiRewriteUse),
            legacyTierWasCloud: tierWasCloud
        )

        if tierWasCloud {
            cleanupTier = CleanupTier(
                rawValue: defaults.string(forKey: Keys.legacyTierBeforeCloud) ?? ""
            ) ?? .rules
        } else if let storedTier, let tier = CleanupTier(rawValue: storedTier) {
            cleanupTier = tier
        } else {
            let wasSmart = defaults.object(forKey: Keys.legacySmartCleanup) as? Bool ?? false
            cleanupTier = wasSmart ? .onDevice : .rules
        }
        // Resolved into a local first: `aiProvider` is an @Observable-backed computed
        // property, and reading it back via `self.aiProvider` here — before every stored
        // property finishes initializing — is a compile error, not just bad style.
        let resolvedProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.aiProvider) ?? ""
        ) ?? .anthropic
        aiProvider = resolvedProvider
        // Resolved into a local for the same reason `resolvedProvider` is: reading
        // `aiModel` back through its @Observable-backed getter here, before every stored
        // property finishes initializing, is a compile error.
        let resolvedModel = defaults.string(forKey: Keys.aiModel) ?? resolvedProvider.defaultModel
        aiModel = resolvedModel
        // Reproduces exactly what OnDemandRewrite.engine used to decide on its own: a
        // working key and model meant cloud, everything else meant on-device. Without
        // this, every existing user with a key would silently move to Apple Intelligence.
        // Trimmed exactly as `engine(...)` trims `model` before its own check — a
        // whitespace-only stored model is not a working cloud setup, and without matching
        // the trim here this migration would derive `.cloud` for a setup `engine(...)`
        // itself resolves to on-device.
        let hasResolvedModel = !resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        rewriteSource = ModelSource(rawValue: defaults.string(forKey: Keys.rewriteSource) ?? "")
            ?? (KeyStore.hasKey(account: resolvedProvider.rawValue) && hasResolvedModel
                ? .cloud
                : .apple)
        // Faithful by default, so turning AI rewrite on can't change the user's words
        // until they ask it to.
        rewriteMode = RewriteMode(
            rawValue: defaults.string(forKey: Keys.rewriteMode) ?? ""
        ) ?? .faithful
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? false
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hudSize = HUDSize(rawValue: defaults.string(forKey: Keys.hudSize) ?? "") ?? .full
        readAloudEnabled = defaults.object(forKey: Keys.readAloudEnabled) as? Bool ?? false
        readAloudVoice = defaults.string(forKey: Keys.readAloudVoice)
        readAloudLocalVoice = defaults.string(forKey: Keys.readAloudLocalVoice) ?? "af_heart"
        // Through NSNumber, not `as? Float`: UserDefaults hands a stored number back as
        // NSNumber, and bridging that straight to Float fails for any value it can't
        // represent exactly — which would silently reset the speed on every launch.
        readAloudSpeed = (defaults.object(forKey: Keys.readAloudSpeed) as? NSNumber)?
            .doubleValue ?? 1.0

        readingMode = ReadingMode(rawValue: defaults.string(forKey: Keys.readingMode) ?? "")
            ?? .asIs
        readingModeCustomLabel = defaults.string(forKey: Keys.readingModeCustomLabel) ?? ""
        readingModeCustomInstruction =
            defaults.string(forKey: Keys.readingModeCustomInstruction) ?? ""
        // A nil raw value is the common case — no override — and an unrecognised one means
        // a provider that no longer exists, which is also "no override" rather than a crash.
        readAloudProviderOverride = defaults.string(forKey: Keys.readAloudProviderOverride)
            .flatMap { AIProvider(rawValue: $0) }
        readAloudModelOverride = defaults.string(forKey: Keys.readAloudModelOverride) ?? ""
        readAloudEngine = VoiceEngine(rawValue: defaults.string(forKey: Keys.readAloudEngine) ?? "")
            ?? .system
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        elevenLabsModel = defaults.string(forKey: Keys.elevenLabsModel) ?? ElevenLabs.defaultModel
        // A stored limit with no stored mode is a user who set one before the age rule
        // existed: they chose a number of dictations, so that is the mode they get.
        let storedLimit = defaults.object(forKey: Keys.historyLimit) as? Int
        historyLimit = (storedLimit ?? 0) > 0 ? storedLimit! : Settings.defaultHistoryLimit
        historyDays = defaults.object(forKey: Keys.historyDays) as? Int
            ?? Settings.defaultHistoryDays
        if let stored = defaults.string(forKey: Keys.historyMode),
           let mode = HistoryRetentionMode(rawValue: stored) {
            historyMode = mode
        } else {
            historyMode = (storedLimit ?? 0) > 0 ? .count : .off
        }
        historyKeepsPinned = defaults.object(forKey: Keys.historyKeepsPinned) as? Bool ?? true

        // `didSet` does not fire during initialization, so without these writes the
        // migrations above would re-run on every launch: a legacy `cloud` string would sit
        // in defaults forever, and `rewriteSource` would stay a launch-time guess that a
        // freshly pasted key and model couldn't change until the next relaunch — the
        // in-memory result of this launch's inference would never reach disk.
        defaults.set(aiRewriteUse.rawValue, forKey: Keys.aiRewriteUse)
        defaults.set(cleanupTier.rawValue, forKey: Keys.cleanupTier)
        defaults.set(rewriteSource.rawValue, forKey: Keys.rewriteSource)
    }
}

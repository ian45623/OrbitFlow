import AVFoundation
import Foundation
import Observation
import OrbitFlowAIRewrite
import OrbitFlowHotkey

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

    var displayName: String {
        switch self {
        case .system: "System"
        case .elevenLabs: "ElevenLabs"
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

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
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
        static let rewriteMode = "rewriteMode"
        static let compareMode = "compareMode"
        static let hudSize = "hudSize"
        static let readAloudEnabled = "readAloudEnabled"
        static let readAloudVoice = "readAloudVoice"
        static let readAloudSpeed = "readAloudSpeed"
        static let readingMode = "readingMode"
        static let readingModeCustomLabel = "readingModeCustomLabel"
        static let readingModeCustomInstruction = "readingModeCustomInstruction"
        static let readAloudProviderOverride = "readAloudProviderOverride"
        static let readAloudModelOverride = "readAloudModelOverride"
        static let readAloudEngine = "readAloudEngine"
        static let elevenLabsVoiceID = "elevenLabsVoiceID"
        static let elevenLabsModel = "elevenLabsModel"
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
        aiModel = defaults.string(forKey: Keys.aiModel) ?? resolvedProvider.defaultModel
        // Faithful by default, so turning AI rewrite on can't change the user's words
        // until they ask it to.
        rewriteMode = RewriteMode(
            rawValue: defaults.string(forKey: Keys.rewriteMode) ?? ""
        ) ?? .faithful
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hudSize = HUDSize(rawValue: defaults.string(forKey: Keys.hudSize) ?? "") ?? .full
        readAloudEnabled = defaults.object(forKey: Keys.readAloudEnabled) as? Bool ?? false
        readAloudVoice = defaults.string(forKey: Keys.readAloudVoice)
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

        // `didSet` does not fire during initialization, so without these two writes the
        // migration above would re-run on every launch and a legacy `cloud` string would
        // sit in defaults forever.
        defaults.set(aiRewriteUse.rawValue, forKey: Keys.aiRewriteUse)
        defaults.set(cleanupTier.rawValue, forKey: Keys.cleanupTier)
    }
}

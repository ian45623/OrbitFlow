import Foundation
import Observation
import OrbitFlowAIRewrite

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

/// Which pass cleans a transcript before it's injected.
///
/// Replaces the old `smartCleanup` boolean, which could only express two of these three.
enum CleanupTier: String, CaseIterable, Sendable {
    /// Deterministic, zero-latency, always available.
    case rules
    /// Apple's on-device Foundation Model. Nothing leaves the Mac.
    case onDevice
    /// A cloud provider of the user's choosing. Text leaves the Mac — see the note in
    /// Settings and the privacy section of the README.
    case cloud

    var displayName: String {
        switch self {
        case .rules: "Rules"
        case .onDevice: "On-device"
        case .cloud: "Cloud AI"
        }
    }
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

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
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

    /// The tier to return to when the AI rewrite switch is turned off.
    ///
    /// Without this, switching the cloud tier off would silently demote a user who had
    /// chosen on-device cleanup all the way down to rules.
    var tierBeforeCloud: CleanupTier {
        didSet { defaults.set(tierBeforeCloud.rawValue, forKey: Keys.tierBeforeCloud) }
    }

    /// Which cloud provider the rewrite tier calls. The API key lives in the Keychain,
    /// never here.
    var aiProvider: AIProvider {
        didSet { defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }

    /// Free text, because the model list is fetched from the provider and a provider may
    /// serve a model our parsing missed.
    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Keys.aiModel) }
    }

    /// The tone the cloud tier rewrites into.
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

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        /// Read once, never written: migrated into `cleanupTier` in `init`.
        static let legacySmartCleanup = "smartCleanup"
        static let cleanupTier = "cleanupTier"
        static let tierBeforeCloud = "tierBeforeCloud"
        static let aiProvider = "aiProvider"
        static let aiModel = "aiModel"
        static let rewriteMode = "rewriteMode"
        static let compareMode = "compareMode"
        static let hudSize = "hudSize"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        // Migrate the old boolean exactly once: after the first launch on this build,
        // `cleanupTier` is present and this branch never runs again. Note that no user
        // can land on `.cloud` by migration — that requires an explicit opt-in.
        if let raw = defaults.string(forKey: Keys.cleanupTier),
           let tier = CleanupTier(rawValue: raw) {
            cleanupTier = tier
        } else {
            let wasSmart = defaults.object(forKey: Keys.legacySmartCleanup) as? Bool ?? false
            cleanupTier = wasSmart ? .onDevice : .rules
        }

        tierBeforeCloud = CleanupTier(
            rawValue: defaults.string(forKey: Keys.tierBeforeCloud) ?? ""
        ) ?? .rules
        // Resolved into a local first: `aiProvider` is an @Observable-backed computed
        // property, and reading it back via `self.aiProvider` here — before every stored
        // property finishes initializing — is a compile error, not just bad style.
        let resolvedProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.aiProvider) ?? ""
        ) ?? .anthropic
        aiProvider = resolvedProvider
        aiModel = defaults.string(forKey: Keys.aiModel) ?? resolvedProvider.defaultModel
        // Faithful by default, so switching the tier on can't change the user's words
        // until they ask it to.
        rewriteMode = RewriteMode(
            rawValue: defaults.string(forKey: Keys.rewriteMode) ?? ""
        ) ?? .faithful
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hudSize = HUDSize(rawValue: defaults.string(forKey: Keys.hudSize) ?? "") ?? .full
    }
}

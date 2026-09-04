import Foundation
import Observation

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

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
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
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let hudSize = "hudSize"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hudSize = HUDSize(rawValue: defaults.string(forKey: Keys.hudSize) ?? "") ?? .full
    }
}

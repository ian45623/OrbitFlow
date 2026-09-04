import Foundation

/// When the AI rewrite runs.
///
/// Splits two things the old `AI rewrite` toggle fused: whether a rewrite is *configured*
/// and *when* it fires. `onDemand` is the case that earns this type — a fully configured
/// rewrite that dictation deliberately does not use, reached from the Services menu
/// instead.
///
/// This is the single owner of "does my text leave this Mac during dictation".
/// `CleanupTier` no longer expresses that; it chooses between the two local passes and
/// nothing else. Two properties expressing one decision is how they drift.
public enum AIRewriteUse: String, CaseIterable, Sendable {
    case off
    case onDemand
    case always

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .onDemand: "On demand"
        case .always: "Always"
        }
    }

    /// One line, shown under the picker in Settings.
    public var summary: String {
        switch self {
        case .off:
            "No AI rewrite anywhere. The right-click rows stay in the Services menu — "
                + "macOS builds that list from the app bundle, not from this setting — "
                + "but they'll tell you it's off."
        case .onDemand:
            "Dictation pastes cleaned text, untouched by AI. Select text anywhere and "
                + "right-click ▸ Services ▸ Orbit Flow to rewrite it when you want to."
        case .always:
            "Every dictation is rewritten before it's pasted, and the right-click rows "
                + "work too. Your text leaves this Mac."
        }
    }

    /// Whether dictation itself sends the transcript to the cloud.
    public var rewritesDictation: Bool { self == .always }

    /// Whether the Services rows should do anything when clicked.
    public var servesOnDemand: Bool { self != .off }

    /// What a user of the previous build lands on, first time this build runs.
    ///
    /// - Parameters:
    ///   - stored: The persisted raw value. Absent on the first launch of this build,
    ///     and unreadable if a future build wrote something this one doesn't know.
    ///   - legacyTierWasCloud: Whether the stored `cleanupTier` was `cloud`, which is the
    ///     only way the previous build could express "rewrite every dictation".
    public static func resolve(stored: String?, legacyTierWasCloud: Bool) -> AIRewriteUse {
        if let stored, let use = AIRewriteUse(rawValue: stored) { return use }
        return legacyTierWasCloud ? .always : .off
    }
}

import Foundation
import OrbitFlowModels

/// When the AI rewrite runs.
///
/// Splits two things the old `AI rewrite` toggle fused: whether a rewrite is *configured*
/// and *when* it fires. `onDemand` is the case that earns this type — a fully configured
/// rewrite that dictation deliberately does not use, reached from the Services menu
/// instead.
///
/// This *was* the single owner of "does my text leave this Mac during dictation", and the
/// warning below was right about the risk: `.always` alone used to be sufficient, because
/// there was nowhere else to point Rewrite but the cloud. The AI Models page changed that —
/// `rewriteSource` now also has to say Cloud before dictation may leave the Mac, so the
/// decision has a second owner whether this comment likes it or not. `CleanupTier` still
/// owns nothing here; it only chooses between the two local passes. What used to be one
/// property is now `sendsDictationToCloud(rewriteSource:)` below — call *that*, not
/// `rewritesDictation` alone, or the four places that used to call the old single owner will
/// drift from each other exactly the way this comment always warned a second property would.
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
                + "work too. If Rewrite is set to Cloud on the AI Models page, your text "
                + "leaves this Mac."
        }
    }

    /// Whether Always-mode rewriting is switched on at all. On its own this does **not**
    /// tell you whether dictation goes to the cloud — see `sendsDictationToCloud(rewriteSource:)`,
    /// which is what every call site actually needs.
    public var rewritesDictation: Bool { self == .always }

    /// The one true answer to "does this utterance leave the Mac", combining both
    /// properties that jointly own the decision. `.always` says a cloud rewrite is
    /// *allowed* to run during dictation; `rewriteSource` (the AI Models page's Rewrite
    /// row) says whether Rewrite is actually pointed at Cloud. Either alone overclaims:
    /// `.always` with Rewrite=Apple must take the local branch, and this is the single
    /// place that says so, so the formatter chosen, the "Rewriting…" indicator, and the
    /// history entry recorded for the run can never disagree about which one happened.
    public func sendsDictationToCloud(rewriteSource: ModelSource) -> Bool {
        rewritesDictation && rewriteSource == .cloud
    }

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

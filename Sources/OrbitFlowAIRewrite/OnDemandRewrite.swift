import Foundation

/// Which engine an on-demand rewrite uses, and why it can't run when it can't.
///
/// Pure and here rather than beside `Settings` for the same reason `RewriteMode` is: the
/// app target is an executable and cannot be imported by a test target, so logic that
/// lives there cannot be tested at all.
public enum OnDemandRewrite {
    public enum Engine: Equatable, Sendable {
        case cloud
        case onDevice
    }

    /// Why an on-demand rewrite can't run. Both cases are shown to the user, so both
    /// have to say what to do about it rather than just what went wrong.
    public enum Unavailable: Equatable, Sendable, Error {
        /// The setting is `off`. Reachable because `NSServices` rows are declared in
        /// `Info.plist` and cannot be hidden at runtime — this refusal is what makes the
        /// setting mean anything.
        case turnedOff
        /// No API key and no on-device model.
        case nothingAvailable

        /// Shown in the HUD pill, which is one line wide. Keep it short.
        public var summary: String {
            switch self {
            case .turnedOff: "AI rewrite is off — turn it on in Settings."
            case .nothingAvailable: "No rewrite available — add an API key in Settings."
            }
        }
    }

    /// - Parameters:
    ///   - hasKey: Whether the Keychain holds a key for the *current* provider. Switching
    ///     providers switches which key this asks about.
    ///   - model: The configured model id. Blank is not a working cloud setup — the
    ///     request would fail — so it falls back exactly as a missing key does.
    ///   - onDeviceAvailable: `OnDeviceRewriter.isAvailable`, which is false on a Mac
    ///     without Apple Intelligence or with it switched off.
    public static func engine(
        use: AIRewriteUse,
        hasKey: Bool,
        model: String,
        onDeviceAvailable: Bool
    ) -> Result<Engine, Unavailable> {
        guard use.servesOnDemand else { return .failure(Unavailable.turnedOff) }
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasKey, hasModel { return .success(Engine.cloud) }
        if onDeviceAvailable { return .success(Engine.onDevice) }
        return .failure(Unavailable.nothingAvailable)
    }
}

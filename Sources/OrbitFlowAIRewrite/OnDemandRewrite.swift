import Foundation
import OrbitFlowModels

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

        /// Two words for the read-aloud capsule, which has room for a mode name and no
        /// more. The sentence version below is for the wider notice pill, where a
        /// right-click rewrite has space to say what to do about it.
        public var keyword: String {
            switch self {
            case .turnedOff: "AI off"
            case .nothingAvailable: "No key"
            }
        }

        /// Shown in the HUD pill, which is one line wide. Keep it short.
        public var summary: String {
            switch self {
            case .turnedOff: "AI rewrite is off — turn it on in Settings."
            case .nothingAvailable: "No rewrite available — add an API key in Settings."
            }
        }
    }

    /// - Parameters:
    ///   - source: What the user picked on the AI Models page. `.local` maps to
    ///     on-device: for rewriting, Apple Intelligence *is* the local model, so that is
    ///     the honest mapping rather than a placeholder for something missing.
    ///   - hasKey: Whether a key is stored for the *current* provider.
    ///   - model: The configured model id. Blank is not a working cloud setup.
    ///   - onDeviceAvailable: `OnDeviceRewriter.isAvailable`.
    public static func engine(
        use: AIRewriteUse,
        source: ModelSource,
        hasKey: Bool,
        model: String,
        onDeviceAvailable: Bool
    ) -> Result<Engine, Unavailable> {
        guard use.servesOnDemand else { return .failure(Unavailable.turnedOff) }
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cloudWorks = hasKey && hasModel

        // Each branch still falls back rather than refusing. This runs from the Services
        // menu, where doing nothing reads as a broken feature rather than a setting.
        switch source {
        case .apple, .local:
            if onDeviceAvailable { return .success(Engine.onDevice) }
            if cloudWorks { return .success(Engine.cloud) }
        case .cloud:
            if cloudWorks { return .success(Engine.cloud) }
            if onDeviceAvailable { return .success(Engine.onDevice) }
        }
        return .failure(Unavailable.nothingAvailable)
    }
}

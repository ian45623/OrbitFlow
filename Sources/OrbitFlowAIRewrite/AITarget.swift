import Foundation

/// Which provider and model a given feature actually calls.
///
/// This exists so that no API key is ever entered twice. `KeyStore` is keyed by *provider*
/// rather than by feature, so the moment a key exists for a provider, every feature
/// pointing at that provider can use it. The shared `aiProvider`/`aiModel` pair is what
/// every feature follows by default; an override is for the user who wants read aloud on
/// a different (cheaper, larger, faster) model than their dictation cleanup.
///
/// Twelve lines, but it decides which key gets billed for a call, so it is here with a
/// test rather than inlined at each of the four call sites.
public enum AITarget {
    public struct Resolved: Equatable, Sendable {
        public let provider: AIProvider
        public let model: String

        public init(provider: AIProvider, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// - Parameters:
    ///   - overrideProvider: `nil` means "whatever AI rewrite uses" — the default.
    ///   - overrideModel: Read *only* when `overrideProvider` is set, so clearing an
    ///     override can't leave its model pointed at the shared provider. Blank falls back
    ///     to the provider's `defaultModel`, which is itself blank for the four providers
    ///     whose model IDs are fetched rather than pinned; the caller's existing
    ///     missing-model check handles that, exactly as it does for the shared pair.
    public static func resolve(
        sharedProvider: AIProvider,
        sharedModel: String,
        overrideProvider: AIProvider?,
        overrideModel: String
    ) -> Resolved {
        guard let provider = overrideProvider else {
            return Resolved(provider: sharedProvider, model: sharedModel)
        }
        let model = overrideModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return Resolved(provider: provider, model: model.isEmpty ? provider.defaultModel : model)
    }
}

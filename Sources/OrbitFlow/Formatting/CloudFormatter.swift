import Foundation
import OrbitFlowAIRewrite

/// Cleanup and tone rewriting via a cloud provider of the user's choosing.
///
/// Deliberately thin: every decision lives in `OrbitFlowAIRewrite`, which is unit-tested.
/// What's here is the fallback contract and the log line.
///
/// Configuration is passed in at construction rather than read from `Settings` inside
/// `format`, because `Settings` is `@MainActor` and `format` is not — the controller
/// builds this on the main actor, per utterance, so a mode change applies to the very
/// next hold.
struct CloudFormatter: TextFormatter {
    let provider: AIProvider
    let model: String
    let key: String
    let mode: RewriteMode

    /// Used whenever the cloud path can't produce usable text. Not optional behavior:
    /// a network hiccup must never cost the user an utterance they already spoke.
    private let fallback = RuleBasedFormatter()

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard !key.isEmpty, !model.isEmpty else {
            Log.speech.info("cloud rewrite skipped — no API key or model configured")
            return await fallback.format(trimmed)
        }

        do {
            let rewriter = CloudRewriter(provider: provider, key: key)
            return try await rewriter.rewrite(trimmed, model: model, mode: mode)
        } catch let failure as RewriteFailure {
            // `summary` never contains the key — see RewriteFailure.
            Log.speech.info(
                "cloud rewrite failed (\(failure.summary, privacy: .public)) — falling back"
            )
            return await fallback.format(trimmed)
        } catch {
            Log.speech.info(
                "cloud rewrite failed (\(error.localizedDescription, privacy: .public)) — falling back"
            )
            return await fallback.format(trimmed)
        }
    }
}

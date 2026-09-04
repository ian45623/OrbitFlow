import Foundation
import FoundationModels

/// One round-trip to Apple's on-device model, with a timeout and no opinions.
///
/// The counterpart to `CloudRewriter`: same shape, same contract — you hand it a system
/// prompt and text, it gives you the model's answer or throws. Everything policy-ish
/// (guards, fallbacks, which prompt) belongs to the caller, because the two callers want
/// opposite things. Dictation wants a bounded cleanup that silently degrades to rules;
/// the detail page wants the real failure on screen.
enum OnDeviceRewriter {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is still downloading."
            @unknown default: return "The on-device model is unavailable."
            }
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    /// - Parameter timeout: A stalled model must never hang the caller. Dictation passes
    ///   a short one because an utterance is waiting; the detail page passes a long one
    ///   because nothing is.
    static func rewrite(
        _ text: String,
        system: String,
        timeout: Duration
    ) async throws -> String {
        guard isAvailable else { throw Failure.unavailable(unavailableReason ?? "") }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(
                    to: text,
                    options: GenerationOptions(
                        // Near-deterministic: this is a text pass, not a creative one.
                        temperature: 0.1,
                        // Output should never run far past the input; this bounds a runaway.
                        maximumResponseTokens: 1_200
                    )
                )
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            // Whichever finishes first wins; cancel the loser.
            guard let first = try await group.next() else { throw Failure.timedOut }
            group.cancelAll()
            return first
        }
    }

    enum Failure: LocalizedError {
        case timedOut
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .timedOut: "The on-device model timed out."
            case .unavailable(let reason): reason
            }
        }
    }

    /// Readable reasons for the generation errors. They mean very different things:
    /// `guardrailViolation` and `refusal` are the model declining content — expected
    /// occasionally, not a bug — while `assetsUnavailable` means the feature is off.
    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? "" }
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "input exceeded the context window"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "blocked by safety guardrails"
        case .unsupportedGuide: return "unsupported generation guide"
        case .unsupportedLanguageOrLocale: return "unsupported language"
        case .decodingFailure: return "decoding failure"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent request on one session"
        case .refusal: return "model refused the content"
        @unknown default: return error.localizedDescription
        }
    }
}

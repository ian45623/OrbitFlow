import Foundation

/// Reading the three things we need out of a provider's JSON.
///
/// `JSONSerialization` rather than `Decodable` structs because we want exactly three
/// fields out of two response shapes, and every failure mode is "return nil and let the
/// caller fall back" — which is a dictionary lookup, not a decoding contract.
public enum AIResponse {
    /// The rewritten text, or `nil` if the payload isn't the shape we expect.
    public static func text(from data: Data, dialect: Dialect) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch dialect {
        case .anthropic:
            // NEVER index content[0]. With thinking enabled — the default on Opus 5 —
            // the first block is a thinking block, and indexing returns the wrong text
            // or nothing at all. Filter by type.
            guard let blocks = root["content"] as? [[String: Any]] else { return nil }
            return blocks.first { $0["type"] as? String == "text" }?["text"] as? String

        case .openAI:
            guard let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else { return nil }
            return message["content"] as? String
        }
    }

    /// Model IDs from `GET {base}/models`. Both dialects return `{"data":[{"id":…}]}`.
    public static func modelIDs(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["id"] as? String }
    }

    /// The provider's own error text, surfaced verbatim in Settings so a bad key reads as
    /// a bad key. Anthropic and the OpenAI-compatible providers share this envelope.
    public static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}

import Foundation

/// The ElevenLabs text-to-speech wire format: requests in, parsed values out.
///
/// Pure, like `AIProvider` and `AIResponse` beside it, and for the same reason — the
/// caller owns the `URLSession` so every shape here is testable with no network.
///
/// This lives in `OrbitFlowAIRewrite` despite being speech rather than rewriting. The
/// module is in practice "cloud services the user points at with their own API key", and
/// a new target to hold one file costs a `Package.swift` entry, a test target and a build
/// edge. Rename the module if a third kind of service lands in it.
public enum ElevenLabs {
    private static let base = URL(string: "https://api.elevenlabs.io")!

    /// ~75 ms and half the credit cost of the quality tier. The quality tiers are one
    /// pick away in Settings for anyone who wants them, and the model list is fetched
    /// rather than hardcoded for the same reason `AIProvider.defaultModel` is mostly
    /// blank: model IDs go stale in months.
    public static let defaultModel = "eleven_flash_v2_5"

    public struct Voice: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let category: String?

        public init(id: String, name: String, category: String?) {
            self.id = id
            self.name = name
            self.category = category
        }
    }

    // MARK: - Requests

    /// The key goes in a header and never in the URL: URLs reach logs, crash reports and
    /// proxy access logs, and a leaked TTS key is a bill.
    private static func authorized(_ url: URL, key: String, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// No `voice_settings` at all: the voice's own saved defaults apply, so what the user
    /// tuned on the ElevenLabs site is what they hear. Speed in particular is deliberately
    /// absent — the API accepts only 0.7–1.2 there, while the app's speed menu goes to 2×,
    /// so it is applied on playback instead (`AVAudioPlayer.rate`). That also means the
    /// rendered bytes are speed-independent and one render serves every speed.
    public static func speechRequest(
        voiceID: String,
        key: String,
        model: String,
        text: String
    ) -> URLRequest {
        var request = authorized(
            base.appending(path: "v1/text-to-speech").appending(path: voiceID),
            key: key,
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
        ]
        // .sortedKeys so the golden-body test is deterministic, matching AIProvider.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys]
        )
        return request
    }

    /// `GET /v2/voices`. There is no `/v1/voices` — v1 was withdrawn, and calling it
    /// returns a 404 that reads to the user as a rejected key.
    public static func voicesRequest(key: String) -> URLRequest {
        authorized(base.appending(path: "v2/voices"), key: key, method: "GET")
    }

    /// `GET /v1/models`. Doubles as the connection test: models back means the key, the
    /// host and the network all work — the same trick `AIProvider.modelsRequest` plays.
    public static func modelsRequest(key: String) -> URLRequest {
        authorized(base.appending(path: "v1/models"), key: key, method: "GET")
    }

    // MARK: - Responses

    /// `JSONSerialization` rather than `Decodable`, matching `AIResponse`: we want three
    /// fields out of a large payload and every failure is "return nothing and let the
    /// caller say so".
    ///
    // ponytail: first page only. /v2/voices paginates via next_page_token, and an account
    // with more than a page of voices will see the list truncated. Add the loop if anyone
    // has that many.
    public static func voices(from data: Data) -> [Voice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["voices"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["voice_id"] as? String,
                  let name = entry["name"] as? String
            else { return nil }
            return Voice(id: id, name: name, category: entry["category"] as? String)
        }
    }

    public static func models(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["model_id"] as? String }
    }

    /// The provider's own error text, surfaced verbatim.
    ///
    /// Worth the two shapes: a bad key and an exhausted quota are both HTTP 401, and this
    /// string is the only thing that tells them apart. Telling a user to check a key that
    /// is perfectly fine is the failure this prevents.
    /// ElevenLabs' machine-readable reason, e.g. `quota_exceeded`.
    ///
    /// Worth reading separately from the message: a rejected key and an exhausted account
    /// are both HTTP 401, and in a capsule with room for two words the difference between
    /// "Bad key" and "No credit" is the whole of what the user needs.
    public static func failureStatus(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = root["detail"] as? [String: Any]
        else { return nil }
        return detail["status"] as? String
    }

    public static func failureMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = root["detail"]
        else { return nil }
        if let message = detail as? String { return message }
        return (detail as? [String: Any])?["message"] as? String
    }
}

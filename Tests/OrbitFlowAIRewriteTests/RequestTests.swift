import Foundation
import Testing

@testable import OrbitFlowAIRewrite

/// The two-dialect branch is the core of this design — five providers, one client. These
/// tests are the thing that notices when someone "simplifies" it into one shape.
struct RequestTests {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Anthropic rewrite request carries the documented headers")
    func anthropicHeaders() {
        let request = AIProvider.anthropic.rewriteRequest(
            model: "claude-haiku-4-5", key: "sk-test", system: "SYS", text: "hello"
        )
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // A Bearer header here means someone collapsed the dialects.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Anthropic rewrite body carries max_tokens and nothing optional")
    func anthropicBody() throws {
        let request = AIProvider.anthropic.rewriteRequest(
            model: "claude-haiku-4-5", key: "sk-test", system: "SYS", text: "hello"
        )
        let json = try body(request)
        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["max_tokens"] as? Int == 8000)
        #expect(json["system"] as? String == "SYS")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hello"]])
        // output_config is deliberately absent. Haiku 4.5 rejects it with a 400 and
        // Haiku is the default model, so sending it would break the fast path outright.
        // Same reasoning as the OpenAI body below.
        #expect(!json.keys.contains("output_config"))
        #expect(json.keys.sorted() == ["max_tokens", "messages", "model", "system"])
    }

    @Test("OpenAI-dialect rewrite request uses Bearer auth and chat/completions")
    func openAIHeaders() {
        let request = AIProvider.openAI.rewriteRequest(
            model: "some-model", key: "sk-test", system: "SYS", text: "hello"
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("OpenAI-dialect body carries system and user turns and nothing else")
    func openAIBody() throws {
        let request = AIProvider.openAI.rewriteRequest(
            model: "some-model", key: "sk-test", system: "SYS", text: "hello"
        )
        let json = try body(request)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "hello"],
        ])
        // Deliberately absent: these two fields are exactly where OpenAI-compatible
        // providers diverge, and a rejected field is a 400 the user reads as "broken".
        // Checked via `keys` rather than `json["temperature"] == nil` — the values are
        // `Any`, which isn't Equatable, so the comparison wouldn't compile.
        #expect(!json.keys.contains("temperature"))
        #expect(!json.keys.contains("max_tokens"))
        #expect(json.keys.sorted() == ["messages", "model"])
    }

    @Test("Every OpenAI-dialect provider posts to chat/completions with Bearer auth",
          arguments: [AIProvider.openAI, .openRouter, .gemini, .deepSeek])
    func openAIDialectProviders(provider: AIProvider) {
        #expect(provider.dialect == .openAI)
        let request = provider.rewriteRequest(model: "m", key: "k", system: "s", text: "t")
        #expect(request.url?.path().hasSuffix("/chat/completions") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test("Model-list requests are GETs to /models with the dialect's auth")
    func modelsRequests() {
        let anthropic = AIProvider.anthropic.modelsRequest(key: "sk-a")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropic.httpMethod == "GET")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "sk-a")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let gemini = AIProvider.gemini.modelsRequest(key: "sk-g")
        #expect(gemini.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/openai/models")
        #expect(gemini.value(forHTTPHeaderField: "Authorization") == "Bearer sk-g")
    }

    @Test("Only Anthropic ships a pre-filled default model, and it is the fast one")
    func defaultModels() {
        #expect(AIProvider.anthropic.defaultModel == "claude-haiku-4-5")
        for provider in AIProvider.allCases where provider != .anthropic {
            #expect(provider.defaultModel.isEmpty)
        }
    }
}

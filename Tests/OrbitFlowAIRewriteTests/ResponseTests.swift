import Foundation
import Testing

@testable import OrbitFlowAIRewrite

struct ResponseTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test("OpenAI-dialect text comes from choices[0].message.content")
    func openAIText() {
        let payload = data("""
        {"choices":[{"message":{"role":"assistant","content":"Rewritten."}}]}
        """)
        #expect(AIResponse.text(from: payload, dialect: .openAI) == "Rewritten.")
    }

    /// The trap this design most wants to avoid. With thinking enabled — which is the
    /// default on Opus 5 — the first content block is a thinking block. Indexing
    /// content[0].text works in a hand-written fixture without thinking and returns the
    /// wrong thing in production.
    @Test("Anthropic text is found past a leading thinking block")
    func anthropicTextAfterThinking() {
        let payload = data("""
        {"content":[
          {"type":"thinking","thinking":"considering the tone"},
          {"type":"text","text":"Rewritten."}
        ]}
        """)
        #expect(AIResponse.text(from: payload, dialect: .anthropic) == "Rewritten.")
    }

    @Test("Anthropic text is found when it is the only block")
    func anthropicTextOnly() {
        let payload = data("""
        {"content":[{"type":"text","text":"Rewritten."}]}
        """)
        #expect(AIResponse.text(from: payload, dialect: .anthropic) == "Rewritten.")
    }

    @Test("A response with no text block yields nil rather than an empty string")
    func anthropicNoTextBlock() {
        let payload = data("""
        {"content":[{"type":"thinking","thinking":"only thinking"}]}
        """)
        #expect(AIResponse.text(from: payload, dialect: .anthropic) == nil)
    }

    @Test("Malformed JSON yields nil, not a crash", arguments: [Dialect.anthropic, .openAI])
    func malformed(dialect: Dialect) {
        #expect(AIResponse.text(from: data("not json at all"), dialect: dialect) == nil)
        #expect(AIResponse.text(from: Data(), dialect: dialect) == nil)
    }

    /// The parser preserves the provider's order. Sorting is CloudRewriter's job, not
    /// this function's — keeping that split is why the fixture here is deliberately not
    /// in sorted order.
    @Test("Model IDs parse from the shared data[].id shape, in provider order")
    func modelIDs() {
        let payload = data("""
        {"data":[{"id":"claude-opus-5"},{"id":"claude-haiku-4-5"}]}
        """)
        #expect(AIResponse.modelIDs(from: payload) == ["claude-opus-5", "claude-haiku-4-5"])
    }

    @Test("Model-list entries without an id are skipped, not fatal")
    func modelIDsPartial() {
        let payload = data("""
        {"data":[{"id":"good"},{"nope":1},{"id":"also-good"}]}
        """)
        #expect(AIResponse.modelIDs(from: payload) == ["good", "also-good"])
    }

    @Test("Model IDs from a malformed body are empty")
    func modelIDsMalformed() {
        #expect(AIResponse.modelIDs(from: data("{}")).isEmpty)
        #expect(AIResponse.modelIDs(from: data("garbage")).isEmpty)
    }

    /// Anthropic and every OpenAI-compatible provider use the same error envelope, so
    /// this needs no dialect argument.
    @Test("Error messages parse from the shared error.message shape")
    func errorMessage() {
        let payload = data("""
        {"error":{"type":"authentication_error","message":"invalid x-api-key"}}
        """)
        #expect(AIResponse.errorMessage(from: payload) == "invalid x-api-key")
    }

    @Test("A body with no error envelope yields nil")
    func noErrorMessage() {
        #expect(AIResponse.errorMessage(from: data("{\"ok\":true}")) == nil)
        #expect(AIResponse.errorMessage(from: data("garbage")) == nil)
    }
}

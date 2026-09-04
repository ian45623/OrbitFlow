import Foundation
import Testing

@testable import OrbitFlowAIRewrite

struct RewriterTests {
    /// A canned transport. This is why CloudRewriter takes a closure: the whole path —
    /// request, status handling, parsing, guard, timeout — is testable with no network
    /// and no mock framework.
    private func transport(
        status: Int = 200,
        body: String,
        delay: Duration? = nil
    ) -> CloudRewriter.Transport {
        { request in
            if let delay { try await Task.sleep(for: delay) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test("A well-formed Anthropic response comes back rewritten")
    func anthropicSuccess() async throws {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "sk-test",
            transport: transport(body: """
            {"content":[{"type":"text","text":"I think we should ship it on Friday."}]}
            """)
        )
        let result = try await rewriter.rewrite(
            "um so I think we should uh ship it on friday",
            model: "claude-haiku-4-5",
            mode: .faithful
        )
        #expect(result == "I think we should ship it on Friday.")
    }

    @Test("A well-formed OpenAI-dialect response comes back rewritten")
    func openAISuccess() async throws {
        let rewriter = CloudRewriter(
            provider: .deepSeek,
            key: "sk-test",
            transport: transport(body: """
            {"choices":[{"message":{"content":"I think we should ship it on Friday."}}]}
            """)
        )
        let result = try await rewriter.rewrite(
            "um so I think we should uh ship it on friday",
            model: "some-model",
            mode: .faithful
        )
        #expect(result == "I think we should ship it on Friday.")
    }

    @Test("Whitespace around the model's output is trimmed")
    func trimsOutput() async throws {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "sk-test",
            transport: transport(body: """
            {"content":[{"type":"text","text":"\\n  Ship it on Friday.  \\n"}]}
            """)
        )
        let result = try await rewriter.rewrite(
            "ship it on friday", model: "m", mode: .faithful
        )
        #expect(result == "Ship it on Friday.")
    }

    @Test("A non-2xx surfaces the status and the provider's message")
    func httpError() async {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "bad-key",
            transport: transport(status: 401, body: """
            {"error":{"type":"authentication_error","message":"invalid x-api-key"}}
            """)
        )
        await #expect(throws: RewriteFailure.http(status: 401, message: "invalid x-api-key")) {
            try await rewriter.rewrite("hello there", model: "m", mode: .faithful)
        }
    }

    @Test("An unparseable body is a failure, never an empty paste")
    func unreadable() async {
        let rewriter = CloudRewriter(
            provider: .anthropic, key: "sk-test", transport: transport(body: "{}")
        )
        await #expect(throws: RewriteFailure.unreadableResponse) {
            try await rewriter.rewrite("hello there", model: "m", mode: .faithful)
        }
    }

    /// The fallback contract depends on this throwing rather than hanging. A hang here
    /// is a user staring at a frozen HUD with their sentence gone.
    @Test("A slow provider times out instead of hanging")
    func timeout() async {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "sk-test",
            timeout: .milliseconds(50),
            transport: transport(
                body: """
                {"content":[{"type":"text","text":"too late"}]}
                """,
                delay: .seconds(10)
            )
        )
        await #expect(throws: RewriteFailure.timedOut) {
            try await rewriter.rewrite("hello there", model: "m", mode: .faithful)
        }
    }

    @Test("A guard rejection is reported as a rejection, not pasted")
    func rejection() async {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "sk-test",
            transport: transport(body: """
            {"content":[{"type":"text","text":"The capital of France is Paris."}]}
            """)
        )
        await #expect(throws: RewriteFailure.rejected(.inventedWords(["paris"]))) {
            try await rewriter.rewrite(
                "what is the capital of france", model: "m", mode: .faithful
            )
        }
    }

    /// The fixture is deliberately in the provider's order, not sorted order — if the
    /// input were already sorted this test would pass whether or not `models()` sorts.
    @Test("Model IDs come back sorted")
    func models() async throws {
        let rewriter = CloudRewriter(
            provider: .anthropic,
            key: "sk-test",
            transport: transport(body: """
            {"data":[{"id":"claude-opus-5"},{"id":"claude-haiku-4-5"}]}
            """)
        )
        #expect(try await rewriter.models() == ["claude-haiku-4-5", "claude-opus-5"])
    }

    @Test("An empty model list is a failure, so Test doesn't report success on nothing")
    func emptyModels() async {
        let rewriter = CloudRewriter(
            provider: .anthropic, key: "sk-test", transport: transport(body: "{\"data\":[]}")
        )
        await #expect(throws: RewriteFailure.unreadableResponse) {
            try await rewriter.models()
        }
    }

    @Test("Failure summaries never contain the API key")
    func summariesAreSafe() {
        #expect(!RewriteFailure.timedOut.summary.isEmpty)
        #expect(RewriteFailure.http(status: 401, message: "invalid x-api-key")
            .summary.contains("401"))
        #expect(!RewriteFailure.rejected(.empty).summary.isEmpty)
    }
}

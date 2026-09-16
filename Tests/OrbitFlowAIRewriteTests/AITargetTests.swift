import Testing

@testable import OrbitFlowAIRewrite

struct AITargetTests {
    /// The whole point of the feature: no override means read aloud bills the same key
    /// AI rewrite already uses, so nothing is entered twice.
    @Test("No override follows the shared provider and model")
    func noOverride() {
        let target = AITarget.resolve(
            sharedProvider: .openRouter,
            sharedModel: "anthropic/claude-haiku-4.5",
            overrideProvider: nil,
            overrideModel: ""
        )
        #expect(target.provider == .openRouter)
        #expect(target.model == "anthropic/claude-haiku-4.5")
    }

    /// A stale override model must not leak through when the override is cleared —
    /// that would bill the shared provider for a model it has never heard of.
    @Test("A leftover override model is ignored when no override provider is set")
    func staleOverrideModelIgnored() {
        let target = AITarget.resolve(
            sharedProvider: .anthropic,
            sharedModel: "claude-haiku-4-5",
            overrideProvider: nil,
            overrideModel: "gpt-5"
        )
        #expect(target.provider == .anthropic)
        #expect(target.model == "claude-haiku-4-5")
    }

    @Test("An override takes its own provider and model")
    func override() {
        let target = AITarget.resolve(
            sharedProvider: .anthropic,
            sharedModel: "claude-haiku-4-5",
            overrideProvider: .deepSeek,
            overrideModel: "deepseek-chat"
        )
        #expect(target.provider == .deepSeek)
        #expect(target.model == "deepseek-chat")
    }

    /// Picking a provider and forgetting the model is the obvious user slip. A blank
    /// model is a 400 from every provider, which reads as "the feature is broken".
    @Test("An override with a blank model falls back to that provider's default")
    func overrideBlankModel() {
        let target = AITarget.resolve(
            sharedProvider: .openAI,
            sharedModel: "gpt-5",
            overrideProvider: .anthropic,
            overrideModel: "   "
        )
        #expect(target.provider == .anthropic)
        #expect(target.model == AIProvider.anthropic.defaultModel)
        #expect(target.model.isEmpty == false)
    }

    /// Four of five providers have no compile-time default, on purpose. Resolving one
    /// with a blank model can only return blank — the caller's missing-model check is
    /// what catches it, and this test pins that we don't invent an ID instead.
    @Test("A provider with no default model resolves blank rather than guessing")
    func overrideBlankModelNoDefault() {
        let target = AITarget.resolve(
            sharedProvider: .anthropic,
            sharedModel: "claude-haiku-4-5",
            overrideProvider: .openRouter,
            overrideModel: ""
        )
        #expect(target.provider == .openRouter)
        #expect(target.model.isEmpty)
    }
}

import Testing

@testable import OrbitFlowAIRewrite

struct GuardTests {
    /// The real reproduced failure: dictate a question, the model answers it, and the
    /// answer gets typed into the user's document. "Paris" is the tell — it was never
    /// spoken.
    @Test("Faithful rejects an answered question")
    func faithfulRejectsAnswer() {
        let reason = RewriteGuard.rejection(
            original: "what is the capital of france",
            output: "The capital of France is Paris.",
            mode: .faithful
        )
        #expect(reason == .inventedWords(["paris"]))
    }

    @Test("Faithful accepts a filler-stripping cleanup")
    func faithfulAcceptsCleanup() {
        let reason = RewriteGuard.rejection(
            original: "um so I think we should uh ship it on friday",
            output: "I think we should ship it on Friday.",
            mode: .faithful
        )
        #expect(reason == nil)
    }

    /// The whole reason the guard is mode-dependent. This output is a good casual
    /// rewrite and would be rejected outright by the faithful check.
    @Test("Rewrite modes accept output that introduces words")
    func rewriteAcceptsNewWords() {
        let original = "tell the team the build is broken and I will look at it"
        let output = "Heads up — the build's broken. I'll take a look."
        #expect(RewriteGuard.rejection(original: original, output: output, mode: .casual) == nil)
        // Same text under the strict check must fail, or the modes aren't actually
        // being distinguished.
        #expect(RewriteGuard.rejection(original: original, output: output, mode: .faithful) != nil)
    }

    @Test("Empty output is rejected in every mode", arguments: RewriteMode.allCases)
    func emptyRejected(mode: RewriteMode) {
        #expect(RewriteGuard.rejection(original: "hello there", output: "", mode: mode) == .empty)
        #expect(RewriteGuard.rejection(original: "hello there", output: "   \n ", mode: mode) == .empty)
    }

    @Test("Empty input is rejected — there is nothing to compare against")
    func emptyOriginalRejected() {
        #expect(RewriteGuard.rejection(original: "", output: "Something.", mode: .casual) == .empty)
    }

    @Test("A model that starts explaining itself is rejected", arguments: RewriteMode.allCases)
    func preambleTellRejected(mode: RewriteMode) {
        let reason = RewriteGuard.rejection(
            original: "ship it on friday please",
            output: "Here's the rewritten text: Please ship it on Friday.",
            mode: mode
        )
        #expect(reason == .preambleTell("here's the rewritten"))
    }

    @Test("Runaway expansion is rejected even in rewrite modes")
    func runawayRejected() {
        let original = "ship it friday"
        let output = String(repeating: "Please ship the build on Friday afternoon. ", count: 12)
        guard case .lengthRatio = RewriteGuard.rejection(
            original: original, output: output, mode: .professional
        ) else {
            Issue.record("expected a lengthRatio rejection")
            return
        }
    }

    /// Rewrite modes get a wider band than faithful precisely so a legitimate
    /// tightening or expansion isn't thrown away.
    @Test("A moderate expansion passes in a rewrite mode but not in faithful")
    func bandsDiffer() {
        let original = "cant make it"
        let output = "I'm afraid I can't make it."
        #expect(RewriteGuard.rejection(original: original, output: output, mode: .professional) == nil)
        // "afraid" was never spoken, so the strict check catches it.
        #expect(RewriteGuard.rejection(original: original, output: output, mode: .faithful) != nil)
    }

    /// Found in review. This output introduces no new content word and sits inside the
    /// length band, so every other check passes it — and it says the opposite of what was
    /// dictated.
    @Test("Faithful rejects a dropped negation that would invert the meaning")
    func faithfulRejectsDroppedNegation() {
        let reason = RewriteGuard.rejection(
            original: "the meeting is not canceled",
            output: "The meeting is canceled.",
            mode: .faithful
        )
        #expect(reason == .droppedNegation(["not"]))
    }

    @Test("Faithful accepts output that keeps the negation")
    func faithfulKeepsNegation() {
        #expect(RewriteGuard.rejection(
            original: "um the meeting is not canceled",
            output: "The meeting is not canceled.",
            mode: .faithful
        ) == nil)
    }

    /// Why the negation check is faithful-only: "not able" to "unable" is a good
    /// professional rewrite, and demanding the literal token would refuse it.
    @Test("Rewrite modes are not held to the literal negation token")
    func rewriteMayRephraseNegation() {
        #expect(RewriteGuard.rejection(
            original: "i am not able to make it",
            output: "I am unable to attend.",
            mode: .professional
        ) == nil)
    }

    @Test("Rejection summaries are non-empty so the log line says something")
    func summaries() {
        #expect(!Rejection.empty.summary.isEmpty)
        #expect(!Rejection.inventedWords(["paris"]).summary.isEmpty)
        #expect(!Rejection.droppedNegation(["not"]).summary.isEmpty)
        #expect(!Rejection.lengthRatio(4.2).summary.isEmpty)
        #expect(!Rejection.preambleTell("sure,").summary.isEmpty)
    }
}

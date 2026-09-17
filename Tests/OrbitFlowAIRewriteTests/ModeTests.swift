import Testing

@testable import OrbitFlowAIRewrite

struct ModeTests {
    @Test("Every mode's prompt carries the shared preamble")
    func allCarryPreamble() {
        for mode in RewriteMode.allCases {
            #expect(mode.systemPrompt.contains("You are a text processor, not an assistant."))
            #expect(mode.systemPrompt.contains("Return ONLY the rewritten text"))
        }
    }

    /// Guards against a mode wired to the wrong string — the failure where two modes
    /// silently produce identical output and the picker looks broken.
    @Test("Mode prompts are distinct and non-empty")
    func distinctPrompts() {
        let prompts = RewriteMode.allCases.map(\.systemPrompt)
        #expect(Set(prompts).count == RewriteMode.allCases.count)
        #expect(prompts.allSatisfy { !$0.isEmpty })
    }

    @Test("Display names and summaries are present and distinct")
    func labels() {
        let names = RewriteMode.allCases.map(\.displayName)
        #expect(Set(names).count == RewriteMode.allCases.count)
        #expect(RewriteMode.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    /// isRewrite is what selects the guard in RewriteGuard. Getting it backwards would
    /// either reject every good rewrite or stop policing faithful cleanup.
    @Test("Only faithful is a non-rewrite")
    func rewriteFlag() {
        #expect(RewriteMode.faithful.isRewrite == false)
        #expect(RewriteMode.casual.isRewrite)
        #expect(RewriteMode.professional.isRewrite)
        #expect(RewriteMode.problemSolver.isRewrite)
    }

    /// The clause that stops the mode's own framing from inventing a solution the
    /// speaker never proposed — the same class of failure as answering a dictated
    /// question, but wearing a more helpful face.
    @Test("Problem-solver forbids inventing a solution")
    func problemSolverGuardClause() {
        #expect(RewriteMode.problemSolver.systemPrompt.contains("do not invent one"))
    }

    @Test("Faithful is the raw value used as the stored default")
    func faithfulRawValue() {
        #expect(RewriteMode.faithful.rawValue == "faithful")
    }
}

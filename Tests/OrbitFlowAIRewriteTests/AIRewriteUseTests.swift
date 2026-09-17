import Testing

@testable import OrbitFlowAIRewrite

struct AIRewriteUseTests {
    /// The whole point of the type: exactly one state sends dictation to the cloud.
    /// Getting this backwards would either leak every utterance or silently disable
    /// the feature for users who paid for a key.
    @Test("Only .always rewrites dictation")
    func rewritesDictation() {
        #expect(AIRewriteUse.always.rewritesDictation)
        #expect(!AIRewriteUse.onDemand.rewritesDictation)
        #expect(!AIRewriteUse.off.rewritesDictation)
    }

    @Test("Only .off refuses the on-demand rows")
    func servesOnDemand() {
        #expect(AIRewriteUse.always.servesOnDemand)
        #expect(AIRewriteUse.onDemand.servesOnDemand)
        #expect(!AIRewriteUse.off.servesOnDemand)
    }

    /// A user of the previous build expressed "rewrite everything" as cleanupTier ==
    /// .cloud. Landing them anywhere but .always would silently turn off a feature
    /// they had switched on.
    @Test("A legacy cloud tier migrates to .always")
    func migratesFromCloudTier() {
        #expect(AIRewriteUse.resolve(stored: nil, legacyTierWasCloud: true) == .always)
    }

    @Test("Everyone else starts off")
    func migratesToOff() {
        #expect(AIRewriteUse.resolve(stored: nil, legacyTierWasCloud: false) == .off)
    }

    /// The migration must run once. Once a real choice is stored it wins outright,
    /// or a user who picked On demand would be dragged back to Always every launch
    /// for as long as the legacy tier value sat in defaults.
    @Test("A stored choice beats the legacy tier")
    func storedWins() {
        #expect(AIRewriteUse.resolve(stored: "onDemand", legacyTierWasCloud: true) == .onDemand)
        #expect(AIRewriteUse.resolve(stored: "off", legacyTierWasCloud: true) == .off)
        #expect(AIRewriteUse.resolve(stored: "always", legacyTierWasCloud: false) == .always)
    }

    /// Defaults can hold anything — a value written by a future build, or garbage.
    /// Falling through to the migration beats crashing or forcing .off.
    @Test("An unreadable stored value falls back to the migration")
    func garbageStoredValue() {
        #expect(AIRewriteUse.resolve(stored: "banana", legacyTierWasCloud: true) == .always)
        #expect(AIRewriteUse.resolve(stored: "", legacyTierWasCloud: false) == .off)
    }

    @Test("Labels are present and distinct")
    func labels() {
        let names = AIRewriteUse.allCases.map(\.displayName)
        #expect(Set(names).count == AIRewriteUse.allCases.count)
        #expect(AIRewriteUse.allCases.allSatisfy { !$0.summary.isEmpty })
    }
}

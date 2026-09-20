import Testing

@testable import OrbitFlowAIRewrite
import OrbitFlowModels

struct OnDemandRewriteTests {
    private func decide(
        use: AIRewriteUse = .onDemand,
        source: ModelSource = .cloud,
        hasKey: Bool = true,
        model: String = "claude-sonnet-4-5",
        onDevice: Bool = true
    ) -> Result<OnDemandRewrite.Engine, OnDemandRewrite.Unavailable> {
        OnDemandRewrite.engine(
            use: use, source: source, hasKey: hasKey, model: model, onDeviceAvailable: onDevice
        )
    }

    /// Cloud wins when it's configured, because configuring it was deliberate work.
    /// On-device is the fallback, not a preference.
    @Test("A configured key and model select cloud")
    func prefersCloud() {
        #expect(decide() == .success(.cloud))
    }

    @Test("No key falls back to on-device")
    func noKey() {
        #expect(decide(hasKey: false) == .success(.onDevice))
    }

    /// A key with no model is not a working cloud setup — the request would 400.
    /// It has to fall back exactly as a missing key does.
    @Test("A key with no model falls back to on-device")
    func noModel() {
        #expect(decide(model: "") == .success(.onDevice))
        #expect(decide(model: "   ") == .success(.onDevice))
    }

    @Test("Nothing configured and no on-device model is a refusal")
    func nothingAvailable() {
        #expect(decide(hasKey: false, onDevice: false) == .failure(.nothingAvailable))
    }

    /// Off must refuse before anything else is considered. The Services rows cannot be
    /// hidden — Info.plist is static — so this refusal is the only thing that makes
    /// "off" mean off.
    @Test("Off refuses even when everything is configured")
    func offRefusesFirst() {
        #expect(decide(use: .off) == .failure(.turnedOff))
        #expect(decide(use: .off, hasKey: false, onDevice: false) == .failure(.turnedOff))
    }

    /// Always is a superset of on demand: dictation rewrites *and* the rows work.
    @Test("Always serves the on-demand rows too")
    func alwaysAlsoServes() {
        #expect(decide(use: .always) == .success(.cloud))
        #expect(decide(use: .always, hasKey: false) == .success(.onDevice))
    }

    @Test("Refusal reasons are non-empty and distinct")
    func reasons() {
        let summaries = [
            OnDemandRewrite.Unavailable.turnedOff.summary,
            OnDemandRewrite.Unavailable.nothingAvailable.summary,
        ]
        #expect(Set(summaries).count == 2)
        #expect(summaries.allSatisfy { !$0.isEmpty })
    }

    /// The point of the new setting: a user with a working key can now say "use Apple
    /// Intelligence anyway". Before this, having a key meant getting cloud, always.
    @Test("Apple is honoured even when a key is configured")
    func appleWinsOverConfiguredKey() {
        #expect(decide(source: .apple) == .success(.onDevice))
    }

    /// For rewriting, Apple Intelligence *is* the local model. A stored `.local` from a
    /// future build must still produce an engine rather than falling off the end.
    @Test("Local maps to on-device")
    func localIsOnDevice() {
        #expect(decide(source: .local) == .success(.onDevice))
    }

    /// Apple selected on a Mac that cannot run it still has to do something. Falling
    /// back to a configured cloud beats refusing.
    @Test("Apple without Apple Intelligence falls back to a configured cloud")
    func appleFallsBackToCloud() {
        #expect(decide(source: .apple, onDevice: false) == .success(.cloud))
    }

    @Test("Apple with neither Apple Intelligence nor a key is unavailable")
    func appleWithNothing() {
        #expect(decide(source: .apple, hasKey: false, onDevice: false) == .failure(.nothingAvailable))
    }

    /// Unchanged: cloud without a working key still falls back rather than failing,
    /// because this path is reached from the Services menu where a silent no-op reads
    /// as a broken feature.
    @Test("Cloud without a key still falls back to on-device")
    func cloudWithoutKey() {
        #expect(decide(source: .cloud, hasKey: false) == .success(.onDevice))
    }

    /// Fix round 1, finding 1: a read-aloud override is a deliberate "use cloud" choice,
    /// made independently of the shared `rewriteSource`. Before this, a shared source of
    /// `.apple` (as it is after migration when the *shared* provider has no key) silently
    /// dropped a working override, because the override's own key was never consulted.
    @Test("An override selects cloud even when the shared source is Apple")
    func overrideOverridesSharedApple() {
        let source = OnDemandRewrite.source(shared: .apple, hasOverride: true)
        #expect(decide(source: source) == .success(.cloud))
    }

    /// An override changes *which* provider's key is asked about, not whether a missing
    /// key still falls back — that fallback is what keeps read aloud from going silent.
    @Test("An override without a key still falls back to on-device")
    func overrideWithoutKeyFallsBack() {
        let source = OnDemandRewrite.source(shared: .apple, hasOverride: true)
        #expect(decide(source: source, hasKey: false) == .success(.onDevice))
    }

    @Test("No override follows the shared source")
    func noOverrideFollowsShared() {
        #expect(OnDemandRewrite.source(shared: .apple, hasOverride: false) == .apple)
        #expect(OnDemandRewrite.source(shared: .cloud, hasOverride: false) == .cloud)
    }
}

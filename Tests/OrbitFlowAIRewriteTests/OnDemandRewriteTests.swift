import Testing

@testable import OrbitFlowAIRewrite

struct OnDemandRewriteTests {
    private func decide(
        use: AIRewriteUse = .onDemand,
        hasKey: Bool = true,
        model: String = "claude-sonnet-4-5",
        onDevice: Bool = true
    ) -> Result<OnDemandRewrite.Engine, OnDemandRewrite.Unavailable> {
        OnDemandRewrite.engine(
            use: use, hasKey: hasKey, model: model, onDeviceAvailable: onDevice
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
}

import Testing

@testable import OrbitFlowModels

struct ModelSourceTests {
    /// The order is the order the segmented control draws, and the page depends on all
    /// three rows drawing the same three segments in the same order.
    @Test("Cases are apple, local, cloud in that order")
    func order() {
        #expect(ModelSource.allCases == [.apple, .local, .cloud])
    }

    @Test("Display names are the exact segment labels")
    func names() {
        #expect(ModelSource.apple.displayName == "Apple")
        #expect(ModelSource.local.displayName == "Local")
        #expect(ModelSource.cloud.displayName == "Cloud")
    }
}

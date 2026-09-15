import Testing
@testable import OrbitFlowHotkey

struct ReadAloudOfferTests {
    @Test("New text is offered, including text that differs from the last offer")
    func offers() {
        #expect(shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: true, isBusy: false))
        #expect(shouldOfferReadAloud(text: "Hello", lastOffered: "Goodbye", enabled: true, isBusy: false))
    }

    @Test("Nothing is offered while the feature is off or the pill is busy")
    func refusesWhenOffOrBusy() {
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: false, isBusy: false))
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: true, isBusy: true))
    }

    @Test("Blank text is never offered")
    func refusesBlank() {
        #expect(!shouldOfferReadAloud(text: "", lastOffered: nil, enabled: true, isBusy: false))
        #expect(!shouldOfferReadAloud(text: "  \n\t", lastOffered: nil, enabled: true, isBusy: false))
    }

    @Test("The same selection is not offered twice — a click on the pill's own ▶ is a mouse-up too")
    func refusesRepeat() {
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: "Hello", enabled: true, isBusy: false))
    }
}

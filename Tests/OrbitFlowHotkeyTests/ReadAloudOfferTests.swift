import Testing
@testable import OrbitFlowHotkey

struct ReadAloudOfferTests {
    // AXError raw values seen in real apps.
    let success: Int32 = 0
    let noValue: Int32 = -25212       // Cursor's focused element; Chrome's page area
    let unsupported: Int32 = -25205   // Word's focused split group

    @Test("An answered, non-blank selection is text, trimmed")
    func classifiesText() {
        #expect(classifySelection(focusedError: success, selectedError: success, value: "  Hello \n")
            == .text("Hello"))
    }

    @Test("An answered, blank selection is known to be empty")
    func classifiesEmpty() {
        #expect(classifySelection(focusedError: success, selectedError: success, value: "") == .empty)
        #expect(classifySelection(focusedError: success, selectedError: success, value: " \n") == .empty)
    }

    @Test("No focused element, or a focused element that won't say, is unknown")
    func classifiesUnknown() {
        #expect(classifySelection(focusedError: noValue, selectedError: nil, value: nil) == .unknown)
        #expect(classifySelection(focusedError: success, selectedError: unsupported, value: nil) == .unknown)
        #expect(classifySelection(focusedError: success, selectedError: noValue, value: nil) == .unknown)
    }

    @Test("A drag or a double/triple-click is a selection gesture; a plain click is not")
    func gestures() {
        #expect(isSelectionGesture(dragDistance: 40, clickCount: 1))
        #expect(isSelectionGesture(dragDistance: 0, clickCount: 2))
        #expect(isSelectionGesture(dragDistance: 0, clickCount: 3))
        #expect(!isSelectionGesture(dragDistance: 1, clickCount: 1))
    }

    @Test("Text is offered unless it is the selection just offered")
    func offersText() {
        #expect(readAloudDecision(reading: .text("Hello"), isGesture: false, lastOffered: nil, enabled: true, isBusy: false)
            == .offerText("Hello"))
        #expect(readAloudDecision(reading: .text("Hello"), isGesture: true, lastOffered: "Hello", enabled: true, isBusy: false)
            == .none)
    }

    @Test("An app that won't say gets a copy offer, but only after a selection gesture")
    func offersCopy() {
        #expect(readAloudDecision(reading: .unknown, isGesture: true, lastOffered: nil, enabled: true, isBusy: false)
            == .offerCopy)
        #expect(readAloudDecision(reading: .unknown, isGesture: false, lastOffered: nil, enabled: true, isBusy: false)
            == .none)
    }

    @Test("A known-empty selection, the feature off, or a busy pill offers nothing")
    func refuses() {
        #expect(readAloudDecision(reading: .empty, isGesture: true, lastOffered: nil, enabled: true, isBusy: false) == .none)
        #expect(readAloudDecision(reading: .text("Hello"), isGesture: true, lastOffered: nil, enabled: false, isBusy: false) == .none)
        #expect(readAloudDecision(reading: .unknown, isGesture: true, lastOffered: nil, enabled: true, isBusy: true) == .none)
    }
}

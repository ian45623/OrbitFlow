import Foundation

/// What an app told Accessibility about its selection.
///
/// The three cases are the whole point: `empty` and `unknown` both mean "no text in hand",
/// but only `unknown` is worth a clipboard copy. An app that answers "nothing is selected"
/// is telling the truth, and copying there would offer to read a click. An app that doesn't
/// answer at all — Cursor has no focused element, Chrome's page area and Word's document
/// don't support selected text — may well be holding a selection it just won't share.
public enum SelectionReading: Equatable, Sendable {
    case text(String)
    case empty
    case unknown
}

/// Classifies an Accessibility read. Errors are `AXError` raw values, 0 being success;
/// `selectedError` is nil when the focused element couldn't be fetched at all.
public func classifySelection(focusedError: Int32, selectedError: Int32?, value: String?) -> SelectionReading {
    guard focusedError == 0, selectedError == 0, let value else { return .unknown }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .empty : .text(trimmed)
}

/// Whether a mouse-up finished something that could have selected text: a drag, or a
/// double- or triple-click. A plain click can't select anything, and it is also what a
/// press of the pill's own buttons looks like.
///
/// Only consulted for apps that won't say what's selected — without it, every click in
/// Cursor or Word would offer to copy.
// ponytail: a few points of travel is a guess; raise it if trackpad jitter offers on clicks.
public func isSelectionGesture(dragDistance: Double, clickCount: Int64) -> Bool {
    dragDistance >= 4 || clickCount >= 2
}

public enum ReadAloudDecision: Equatable, Sendable {
    case none
    /// Accessibility handed over the text.
    case offerText(String)
    /// The app wouldn't say; ▶ should copy the selection to find out.
    case offerCopy
}

/// What the pill should offer after a mouse-up.
///
/// Lives here rather than in the app because the app target is an executable no test can
/// import. The repeat check matters: clicking the pill's own ▶ is itself a mouse-up, made
/// while the selection is still in place, so without it every press would re-offer the
/// text it was pressed to read.
///
/// `isBusy` is anything already using the pill — a dictation, a rewrite in flight, a
/// notice. An offer is the least important thing the pill ever shows, so it never
/// displaces one of those.
public func readAloudDecision(
    reading: SelectionReading,
    isGesture: Bool,
    lastOffered: String?,
    enabled: Bool,
    isBusy: Bool
) -> ReadAloudDecision {
    guard enabled, !isBusy else { return .none }
    switch reading {
    case .text(let text): return text == lastOffered ? .none : .offerText(text)
    case .empty: return .none
    case .unknown: return isGesture ? .offerCopy : .none
    }
}

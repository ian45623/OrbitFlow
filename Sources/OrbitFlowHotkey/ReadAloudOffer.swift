import Foundation

/// Whether a selection just made with the mouse should be offered for reading aloud.
///
/// Lives here rather than in the app because the app target is an executable no test can
/// import, and the repeat check is easy to break without noticing: clicking the pill's own
/// ▶ is itself a mouse-up, made while the selection is still in place, so without it every
/// press would re-offer the text it was pressed to read.
///
/// `isBusy` is anything already using the pill — a dictation, a rewrite in flight, a
/// notice. An offer is the least important thing the pill ever shows, so it never
/// displaces one of those.
public func shouldOfferReadAloud(
    text: String,
    lastOffered: String?,
    enabled: Bool,
    isBusy: Bool
) -> Bool {
    guard enabled, !isBusy else { return false }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return text != lastOffered
}

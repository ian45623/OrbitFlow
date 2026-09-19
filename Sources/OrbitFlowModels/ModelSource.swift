/// Where the model for one job runs.
///
/// The same three choices on all three rows of the AI Models page, in this order. The
/// order is load-bearing: the three segmented controls line up down the page, and a row
/// that reordered them would break that alignment for no gain.
public enum ModelSource: String, CaseIterable, Sendable {
    /// Whatever ships with macOS. No download, no key.
    case apple
    /// A model downloaded to this Mac.
    case local
    /// A provider reached over the network, with the user's own key.
    case cloud

    public var displayName: String {
        switch self {
        case .apple: "Apple"
        case .local: "Local"
        case .cloud: "Cloud"
        }
    }
}

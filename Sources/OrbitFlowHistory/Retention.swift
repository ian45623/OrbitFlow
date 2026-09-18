import Foundation

/// What history is trimmed down to, automatically.
///
/// One rule at a time, as a sum type rather than a pair of optional numbers: a count and a
/// window that are both set have no agreed meaning, and the type that can't express the
/// disagreement is cheaper than the code that would have to resolve it.
public enum RetentionRule: Sendable, Equatable {
    /// Keep the lot. Nothing is ever deleted without being asked for.
    case keepEverything
    /// Keep this many dictations, newest first.
    case newest(Int)
    /// Keep dictations recorded within this many days.
    case within(days: Int)

    /// The stops the age slider settles on. Roughly doubling, so eight of them cover a
    /// week to two years without a list you have to aim at.
    public static let dayPresets = [7, 14, 30, 60, 90, 180, 365, 730]

    /// How a window is written on the slider's readout.
    public static func dayLabel(_ days: Int) -> String {
        switch days {
        case 365: "1 year"
        case 730: "2 years"
        default: "\(days) days"
        }
    }
}

/// A rule plus the one exemption to it.
public struct RetentionPolicy: Sendable, Equatable {
    public let rule: RetentionRule
    /// Pinned dictations are exempt: never deleted, and never counted against `rule`.
    public let keepsPinned: Bool

    public init(rule: RetentionRule, keepsPinned: Bool) {
        self.rule = rule
        self.keepsPinned = keepsPinned
    }
}

extension History {
    public static func expired(
        from items: [HistoryItem],
        policy: RetentionPolicy,
        now: Date = Date()
    ) -> Set<UUID> {
        []
    }
}

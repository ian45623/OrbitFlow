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
    /// Which dictations the rule has let go of. The newest, or the most recent, survive.
    ///
    /// A count below one and a window below a day both mean "keep everything", not "delete
    /// everything" — the panel spells off as its own case, and of the two readings of a
    /// zero that arrives anyway, only one of them is recoverable.
    ///
    /// With `keepsPinned`, pinned dictations are lifted out before anything is counted or
    /// dated, so they neither expire nor push an unpinned dictation over the edge. Fifty
    /// pinned under a count of 250 keeps 300, which is the only reading where pinning
    /// something can't silently evict something else.
    public static func expired(
        from items: [HistoryItem],
        policy: RetentionPolicy,
        now: Date = Date()
    ) -> Set<UUID> {
        let counted = policy.keepsPinned ? items.filter { !$0.isPinned } : items

        switch policy.rule {
        case .keepEverything:
            return []

        case .newest(let count):
            guard count > 0, counted.count > count else { return [] }
            // The id breaks ties: `sorted(by:)` is not a stable sort, and two dictations
            // recorded in the same instant must not expire differently between two runs
            // over the same history.
            let newestFirst = counted.sorted {
                $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date
            }
            return Set(newestFirst.dropFirst(count).map(\.id))

        case .within(let days):
            guard days > 0 else { return [] }
            // Strictly older than the window. A dictation sitting exactly on the boundary
            // is kept, the same way an exactly-ten-minute gap continues a session.
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            return Set(counted.filter { $0.date < cutoff }.map(\.id))
        }
    }
}

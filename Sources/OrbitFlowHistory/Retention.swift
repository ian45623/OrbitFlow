import Foundation

/// How much history is kept automatically.
public struct RetentionPolicy: Sendable, Equatable {
    /// How many dictations to keep. `nil` — and anything below one — keeps everything.
    public let limit: Int?
    /// Pinned dictations are exempt: never deleted, and not counted against `limit`.
    public let keepsPinned: Bool

    public init(limit: Int?, keepsPinned: Bool) {
        self.limit = limit
        self.keepsPinned = keepsPinned
    }
}

extension History {
    /// Which dictations have fallen past the limit. The newest survive.
    ///
    /// A limit below one means "keep everything", not "delete everything" — the settings
    /// panel spells `off` as zero, and the reading that loses the user's history on an
    /// off-by-one is the wrong one to take.
    ///
    /// With `keepsPinned`, pinned dictations are lifted out before anything is counted, so
    /// they neither expire nor push an unpinned dictation over the edge. Fifty pinned under
    /// a limit of 250 keeps 300, which is the only reading where pinning something can't
    /// silently evict something else.
    public static func expired(from items: [HistoryItem], policy: RetentionPolicy) -> Set<UUID> {
        guard let limit = policy.limit, limit > 0 else { return [] }

        let counted = policy.keepsPinned ? items.filter { !$0.isPinned } : items
        guard counted.count > limit else { return [] }

        // The id breaks ties: `sorted(by:)` is not a stable sort, and two dictations
        // recorded in the same instant must not expire differently between two runs over
        // the same history.
        let newestFirst = counted.sorted {
            $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date
        }
        return Set(newestFirst.dropFirst(limit).map(\.id))
    }
}

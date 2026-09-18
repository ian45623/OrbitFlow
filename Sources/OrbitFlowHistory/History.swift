import Foundation

/// One dictation, reduced to what the Recent pane sorts, groups and counts by.
///
/// Deliberately not `DictationRun`: this target has no opinion about the log format, the
/// rewrite history or how a transcript is stored. It gets six facts and returns an
/// arrangement, which is what makes the arrangement testable without a run log.
public struct HistoryItem: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    /// The app the text landed in, or nil for runs recorded before that was captured.
    public let destination: String?
    public let words: Int
    public let isPinned: Bool
    public let wasRewritten: Bool
    public let corrections: Int

    public init(
        id: UUID,
        date: Date,
        destination: String?,
        words: Int,
        isPinned: Bool,
        wasRewritten: Bool,
        corrections: Int
    ) {
        self.id = id
        self.date = date
        self.destination = destination
        self.words = words
        self.isPinned = isPinned
        self.wasRewritten = wasRewritten
        self.corrections = corrections
    }
}

/// Consecutive dictations into one app: a stretch of work, rather than a row in a list.
public struct HistorySession: Sendable, Identifiable {
    public let destination: String?
    /// Newest first, like the sessions themselves.
    public let items: [HistoryItem]

    public var id: UUID { items.first?.id ?? UUID() }
    public var started: Date { items.last?.date ?? .distantPast }
    public var ended: Date { items.first?.date ?? .distantPast }
    public var words: Int { items.reduce(0) { $0 + $1.words } }
}

/// What the rail's rows select.
public enum HistoryFilter: Sendable, Hashable {
    case everything
    case pinned
    case rewritten
    case corrected
    case longForm
    case destination(String)
}

public enum History {
    /// A dictation of this many words or more is "long form". Roughly forty seconds of
    /// speech — where a dictation stops being a message and starts being a draft.
    public static let longFormWords = 100

    /// Consecutive runs into the same app, with no more than `gap` between them.
    ///
    /// Ten minutes by default: long enough to survive thinking mid-message, short enough
    /// that this morning's Slack and this afternoon's Slack stay separate. The boundary is
    /// inclusive — exactly ten minutes continues the session.
    public static func sessions(_ items: [HistoryItem], gap: TimeInterval = 600) -> [HistorySession] {
        let ordered = items.sorted { $0.date > $1.date }
        var sessions: [HistorySession] = []
        var current: [HistoryItem] = []

        for item in ordered {
            guard let previous = current.last else {
                current = [item]
                continue
            }
            // Walking newest → oldest, so the gap is measured backwards.
            let sameApp = previous.destination == item.destination
            let closeEnough = previous.date.timeIntervalSince(item.date) <= gap
            if sameApp, closeEnough {
                current.append(item)
            } else {
                sessions.append(HistorySession(destination: previous.destination, items: current))
                current = [item]
            }
        }
        if let last = current.last {
            sessions.append(HistorySession(destination: last.destination, items: current))
        }
        return sessions
    }

    public static func matching(_ filter: HistoryFilter, in items: [HistoryItem]) -> [HistoryItem] {
        switch filter {
        case .everything: items
        case .pinned: items.filter(\.isPinned)
        case .rewritten: items.filter(\.wasRewritten)
        case .corrected: items.filter { $0.corrections > 0 }
        case .longForm: items.filter { $0.words >= longFormWords }
        case .destination(let name): items.filter { $0.destination == name }
        }
    }

    /// Every view filter with its count, zeros included — a row that disappears when it
    /// empties is a row that moves under the pointer.
    public static func counts(for items: [HistoryItem]) -> [HistoryFilter: Int] {
        let views: [HistoryFilter] = [.everything, .pinned, .rewritten, .corrected, .longForm]
        return views.reduce(into: [:]) { counts, filter in
            counts[filter] = matching(filter, in: items).count
        }
    }

    /// Apps that have received dictation, busiest first. Ties break on name so the rail
    /// keeps the same order between redraws.
    public static func destinations(in items: [HistoryItem]) -> [(name: String, count: Int)] {
        Dictionary(grouping: items.compactMap(\.destination), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

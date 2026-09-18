import Foundation
import Testing
@testable import OrbitFlowHistory

/// Sessions are built from clock times, so every sample is placed relative to one fixed
/// moment — the gap boundary has to be landed on exactly, not approximately.
private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func item(
    minutesAfterNoon: Double,
    destination: String? = "Slack",
    words: Int = 10,
    pinned: Bool = false,
    rewritten: Bool = false,
    corrections: Int = 0
) -> HistoryItem {
    HistoryItem(
        id: UUID(),
        date: noon.addingTimeInterval(minutesAfterNoon * 60),
        destination: destination,
        words: words,
        isPinned: pinned,
        wasRewritten: rewritten,
        corrections: corrections
    )
}

// MARK: - Sessions

@Test("An empty history has no sessions")
func emptyHistory() {
    #expect(History.sessions([]).isEmpty)
}

@Test("Runs close together in one app are one session")
func runsCloseTogetherGroup() {
    let sessions = History.sessions([item(minutesAfterNoon: 0), item(minutesAfterNoon: 5)])

    #expect(sessions.count == 1)
    #expect(sessions[0].items.count == 2)
}

@Test("A gap of exactly ten minutes continues the session")
func boundaryGapContinues() {
    let sessions = History.sessions([item(minutesAfterNoon: 0), item(minutesAfterNoon: 10)])

    #expect(sessions.count == 1)
}

@Test("A gap of more than ten minutes starts a new session")
func longerGapSplits() {
    let sessions = History.sessions([item(minutesAfterNoon: 0), item(minutesAfterNoon: 10.5)])

    #expect(sessions.count == 2)
}

@Test("A different app starts a new session however close in time")
func differentAppSplits() {
    let sessions = History.sessions([
        item(minutesAfterNoon: 0, destination: "Slack"),
        item(minutesAfterNoon: 0.5, destination: "Mail"),
    ])

    #expect(sessions.count == 2)
}

@Test("Runs with no destination group together, and never with a named app")
func unknownDestinationGroupsSeparately() {
    let sessions = History.sessions([
        item(minutesAfterNoon: 0, destination: nil),
        item(minutesAfterNoon: 1, destination: nil),
        item(minutesAfterNoon: 2, destination: "Slack"),
    ])

    #expect(sessions.count == 2)
    #expect(sessions.contains { $0.destination == nil && $0.items.count == 2 })
}

@Test("Sessions come back newest first, and so do the runs inside them")
func newestFirst() {
    let sessions = History.sessions([
        item(minutesAfterNoon: 0),
        item(minutesAfterNoon: 2),
        item(minutesAfterNoon: 90),
    ])

    #expect(sessions.count == 2)
    #expect(sessions[0].started == noon.addingTimeInterval(90 * 60))
    #expect(sessions[1].items.first?.date == noon.addingTimeInterval(2 * 60))
}

@Test("A session reports its span and its total words")
func sessionTotals() {
    let sessions = History.sessions([
        item(minutesAfterNoon: 0, words: 100),
        item(minutesAfterNoon: 4, words: 212),
    ])

    #expect(sessions[0].words == 312)
    #expect(sessions[0].started == noon)
    #expect(sessions[0].ended == noon.addingTimeInterval(4 * 60))
}

// MARK: - Filters

@Test("Everything matches every run")
func everythingMatches() {
    let items = [item(minutesAfterNoon: 0), item(minutesAfterNoon: 1)]

    #expect(History.matching(.everything, in: items).count == 2)
}

@Test("Long form is a hundred words or more")
func longFormThreshold() {
    let items = [
        item(minutesAfterNoon: 0, words: 99),
        item(minutesAfterNoon: 1, words: 100),
    ]

    // A threshold has to be somewhere. 100 words is roughly forty seconds of speech, which
    // is where a dictation stops being a message and starts being a draft.
    #expect(History.matching(.longForm, in: items).map(\.words) == [100])
}

@Test("Corrected matches runs where the dictionary fired")
func correctedFilter() {
    let items = [
        item(minutesAfterNoon: 0, corrections: 0),
        item(minutesAfterNoon: 1, corrections: 2),
    ]

    #expect(History.matching(.corrected, in: items).count == 1)
}

@Test("A destination filter matches only that app")
func destinationFilter() {
    let items = [
        item(minutesAfterNoon: 0, destination: "Slack"),
        item(minutesAfterNoon: 1, destination: "Mail"),
    ]

    #expect(History.matching(.destination("Mail"), in: items).count == 1)
}

// MARK: - Counts

@Test("Counts report every filter, including the ones at zero")
func countsIncludeZeroes() {
    let counts = History.counts(for: [item(minutesAfterNoon: 0)])

    // The rail must not reshape itself as history changes: a filter that vanishes at zero
    // is a row that moves under the pointer.
    #expect(counts[.everything] == 1)
    #expect(counts[.pinned] == 0)
    #expect(counts[.rewritten] == 0)
    #expect(counts[.corrected] == 0)
    #expect(counts[.longForm] == 0)
}

@Test("Destinations are listed busiest first")
func destinationsByCount() {
    let items = [
        item(minutesAfterNoon: 0, destination: "Mail"),
        item(minutesAfterNoon: 30, destination: "Slack"),
        item(minutesAfterNoon: 60, destination: "Slack"),
    ]

    #expect(History.destinations(in: items).map(\.name) == ["Slack", "Mail"])
    #expect(History.destinations(in: items).map(\.count) == [2, 1])
}

@Test("Destinations with equal counts are ordered by name, so the rail doesn't shuffle")
func destinationTiesAreStable() {
    let items = [
        item(minutesAfterNoon: 0, destination: "Notes"),
        item(minutesAfterNoon: 30, destination: "Cursor"),
    ]

    #expect(History.destinations(in: items).map(\.name) == ["Cursor", "Notes"])
}

@Test("Runs with no destination are left out of the destination list")
func destinationsSkipUnknown() {
    let items = [item(minutesAfterNoon: 0, destination: nil), item(minutesAfterNoon: 30, destination: "Mail")]

    #expect(History.destinations(in: items).map(\.name) == ["Mail"])
}

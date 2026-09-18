import Foundation
import Testing
@testable import OrbitFlowHistory

/// Retention is decided against a clock, so every sample is placed relative to one fixed
/// moment that the tests also pass in as `now`. Nothing here reads the real time.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let day: TimeInterval = 86_400

/// Minute 0 is the oldest; higher minutes are newer and survive a count rule longer.
private func run(
    _ minutesOld: Double,
    pinned: Bool = false
) -> HistoryItem {
    item(age: minutesOld * 60, pinned: pinned)
}

private func run(daysOld: Double, pinned: Bool = false) -> HistoryItem {
    item(age: daysOld * day, pinned: pinned)
}

private func item(age: TimeInterval, pinned: Bool) -> HistoryItem {
    HistoryItem(
        id: UUID(),
        date: now.addingTimeInterval(-age),
        destination: "Slack",
        words: 10,
        isPinned: pinned,
        wasRewritten: false,
        corrections: 0
    )
}

private func policy(_ rule: RetentionRule, keepsPinned: Bool = true) -> RetentionPolicy {
    RetentionPolicy(rule: rule, keepsPinned: keepsPinned)
}

private func expired(_ items: [HistoryItem], _ policy: RetentionPolicy) -> Set<UUID> {
    History.expired(from: items, policy: policy, now: now)
}

// MARK: - Keeping everything

@Test("The off rule expires nothing")
func keepEverythingExpiresNothing() {
    let items = (0..<50).map { run(Double($0)) }

    #expect(expired(items, policy(.keepEverything)).isEmpty)
}

@Test("A count of zero keeps everything rather than deleting everything")
func zeroCountKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(expired(items, policy(.newest(0))).isEmpty)
}

@Test("A negative count keeps everything")
func negativeCountKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(expired(items, policy(.newest(-5))).isEmpty)
}

@Test("A window of zero days keeps everything rather than deleting everything")
func zeroDayWindowKeepsEverything() {
    let items = (0..<10).map { run(daysOld: Double($0) * 100) }

    #expect(expired(items, policy(.within(days: 0))).isEmpty)
}

@Test("A negative window keeps everything")
func negativeWindowKeepsEverything() {
    let items = (0..<10).map { run(daysOld: Double($0) * 100) }

    #expect(expired(items, policy(.within(days: -30))).isEmpty)
}

@Test("An empty history expires nothing")
func emptyHistoryExpiresNothing() {
    #expect(expired([], policy(.newest(100))).isEmpty)
    #expect(expired([], policy(.within(days: 30))).isEmpty)
}

// MARK: - Count

@Test("A history under the count loses nothing")
func underTheCountKeepsEverything() {
    let items = (0..<3).map { run(Double($0)) }

    #expect(expired(items, policy(.newest(10))).isEmpty)
}

@Test("A history of exactly the count loses nothing")
func exactlyTheCountKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(expired(items, policy(.newest(10))).isEmpty)
}

@Test("Past the count, the oldest dictations expire")
func pastTheCountTheOldestExpire() {
    let oldest = run(3)
    let older = run(2)
    let newer = run(1)
    let newest = run(0)

    let gone = expired([oldest, older, newer, newest], policy(.newest(2)))

    #expect(gone == [oldest.id, older.id])
}

@Test("Expiry doesn't depend on the order the items arrive in")
func orderOfInputDoesNotMatter() {
    let oldest = run(2)
    let middle = run(1)
    let newest = run(0)

    let forwards = expired([oldest, middle, newest], policy(.newest(1)))
    let backwards = expired([newest, middle, oldest], policy(.newest(1)))

    #expect(forwards == [oldest.id, middle.id])
    #expect(forwards == backwards)
}

@Test("Dictations recorded in the same instant expire deterministically")
func tiesAreDeterministic() {
    let a = run(0)
    let b = run(0)
    let c = run(0)

    let first = expired([a, b, c], policy(.newest(1)))
    let second = expired([c, a, b], policy(.newest(1)))

    #expect(first.count == 2)
    #expect(first == second)
}

// MARK: - Age

@Test("Everything inside the window survives")
func insideTheWindowSurvives() {
    let items = [run(daysOld: 1), run(daysOld: 10), run(daysOld: 29)]

    #expect(expired(items, policy(.within(days: 30))).isEmpty)
}

@Test("A dictation exactly at the edge of the window is kept")
func theWindowBoundaryIsKept() {
    let edge = run(daysOld: 30)

    #expect(expired([edge], policy(.within(days: 30))).isEmpty)
}

@Test("A dictation past the window expires")
func pastTheWindowExpires() {
    let stale = run(daysOld: 31)
    let fresh = run(daysOld: 29)

    #expect(expired([stale, fresh], policy(.within(days: 30))) == [stale.id])
}

@Test("A longer window keeps what a shorter one would have deleted")
func aLongerWindowKeepsMore() {
    let items = (1...500).map { run(daysOld: Double($0)) }

    let week = expired(items, policy(.within(days: 7)))
    let year = expired(items, policy(.within(days: 365)))

    #expect(week.count == 493)
    #expect(year.count == 135)
    #expect(year.isSubset(of: week))
}

// MARK: - Pinned

@Test("Pinned dictations never expire under a count when they're kept")
func pinnedSurviveACount() {
    let pinned = run(20, pinned: true)
    let items = [pinned] + (0..<10).map { run(Double($0)) }

    #expect(!expired(items, policy(.newest(2))).contains(pinned.id))
}

@Test("Pinned dictations never expire under a window when they're kept")
func pinnedSurviveAWindow() {
    let pinned = run(daysOld: 400, pinned: true)
    let stale = run(daysOld: 400)

    let gone = expired([pinned, stale], policy(.within(days: 30)))

    #expect(gone == [stale.id])
}

@Test("Pinned dictations don't count toward the limit")
func pinnedDoNotCountTowardTheLimit() {
    let pinned = (0..<3).map { run(Double($0) + 20, pinned: true) }
    let unpinned = (0..<4).map { run(Double($0)) }

    let gone = expired(pinned + unpinned, policy(.newest(2)))

    // The two newest unpinned survive alongside all three pinned: five kept, not two.
    #expect(gone == [unpinned[2].id, unpinned[3].id])
}

@Test("A history of nothing but pinned dictations loses nothing")
func allPinnedKeepsEverything() {
    let items = (0..<10).map { run(Double($0), pinned: true) }

    #expect(expired(items, policy(.newest(1))).isEmpty)
}

@Test("Pinned dictations expire like any other when they aren't kept")
func pinnedExpireWhenNotKept() {
    let oldest = run(2, pinned: true)
    let older = run(1)
    let newest = run(0)

    let gone = expired([oldest, older, newest], policy(.newest(1), keepsPinned: false))

    #expect(gone == [oldest.id, older.id])
}

@Test("With pinning off, a window deletes pinned dictations too")
func pinnedExpireInAWindowWhenNotKept() {
    let pinned = run(daysOld: 400, pinned: true)
    let fresh = run(daysOld: 1)

    let gone = expired([pinned, fresh], policy(.within(days: 30), keepsPinned: false))

    #expect(gone == [pinned.id])
}

// MARK: - The presets the slider stops on

@Test("The age presets climb from a week to two years")
func presetsAreOrdered() {
    #expect(RetentionRule.dayPresets == [7, 14, 30, 60, 90, 180, 365, 730])
}

@Test("A year reads as a year rather than as 365 days")
func yearsReadAsYears() {
    #expect(RetentionRule.dayLabel(7) == "7 days")
    #expect(RetentionRule.dayLabel(180) == "180 days")
    #expect(RetentionRule.dayLabel(365) == "1 year")
    #expect(RetentionRule.dayLabel(730) == "2 years")
}

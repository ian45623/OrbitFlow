import Foundation
import Testing
@testable import OrbitFlowHistory

/// Retention is decided by recency, so every sample is placed relative to one fixed
/// moment. Minute 0 is the oldest; higher minutes are newer and survive longer.
private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func run(
    _ minutesAfterNoon: Double,
    pinned: Bool = false,
    id: UUID = UUID()
) -> HistoryItem {
    HistoryItem(
        id: id,
        date: noon.addingTimeInterval(minutesAfterNoon * 60),
        destination: "Slack",
        words: 10,
        isPinned: pinned,
        wasRewritten: false,
        corrections: 0
    )
}

private func policy(_ limit: Int?, keepsPinned: Bool = true) -> RetentionPolicy {
    RetentionPolicy(limit: limit, keepsPinned: keepsPinned)
}

// MARK: - No limit

@Test("With no limit, nothing expires")
func noLimitKeepsEverything() {
    let items = (0..<50).map { run(Double($0)) }

    #expect(History.expired(from: items, policy: policy(nil)).isEmpty)
}

@Test("A limit of zero keeps everything rather than deleting everything")
func zeroLimitKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(History.expired(from: items, policy: policy(0)).isEmpty)
}

@Test("A negative limit keeps everything")
func negativeLimitKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(History.expired(from: items, policy: policy(-5)).isEmpty)
}

@Test("An empty history expires nothing")
func emptyHistoryExpiresNothing() {
    #expect(History.expired(from: [], policy: policy(100)).isEmpty)
}

// MARK: - The count

@Test("A history under the limit loses nothing")
func underTheLimitKeepsEverything() {
    let items = (0..<3).map { run(Double($0)) }

    #expect(History.expired(from: items, policy: policy(10)).isEmpty)
}

@Test("A history of exactly the limit loses nothing")
func exactlyTheLimitKeepsEverything() {
    let items = (0..<10).map { run(Double($0)) }

    #expect(History.expired(from: items, policy: policy(10)).isEmpty)
}

@Test("Past the limit, the oldest dictations expire")
func pastTheLimitTheOldestExpire() {
    let oldest = run(0)
    let older = run(1)
    let newer = run(2)
    let newest = run(3)

    let expired = History.expired(from: [oldest, older, newer, newest], policy: policy(2))

    #expect(expired == [oldest.id, older.id])
}

@Test("Expiry doesn't depend on the order the items arrive in")
func orderOfInputDoesNotMatter() {
    let oldest = run(0)
    let middle = run(1)
    let newest = run(2)

    let forwards = History.expired(from: [oldest, middle, newest], policy: policy(1))
    let backwards = History.expired(from: [newest, middle, oldest], policy: policy(1))

    #expect(forwards == [oldest.id, middle.id])
    #expect(forwards == backwards)
}

@Test("Dictations recorded in the same instant expire deterministically")
func tiesAreDeterministic() {
    let a = run(0)
    let b = run(0)
    let c = run(0)

    let first = History.expired(from: [a, b, c], policy: policy(1))
    let second = History.expired(from: [c, a, b], policy: policy(1))

    #expect(first.count == 2)
    #expect(first == second)
}

// MARK: - Pinned

@Test("Pinned dictations never expire when they're kept")
func pinnedSurviveWhenKept() {
    let pinned = run(0, pinned: true)
    let items = [pinned] + (1..<10).map { run(Double($0)) }

    let expired = History.expired(from: items, policy: policy(2, keepsPinned: true))

    #expect(!expired.contains(pinned.id))
}

@Test("Pinned dictations don't count toward the limit")
func pinnedDoNotCountTowardTheLimit() {
    let pinned = (0..<3).map { run(Double($0), pinned: true) }
    let unpinned = (10..<14).map { run(Double($0)) }

    let expired = History.expired(from: pinned + unpinned, policy: policy(2, keepsPinned: true))

    // The two newest unpinned survive alongside all three pinned: five kept, not two.
    #expect(expired == [unpinned[0].id, unpinned[1].id])
}

@Test("A history of nothing but pinned dictations loses nothing")
func allPinnedKeepsEverything() {
    let items = (0..<10).map { run(Double($0), pinned: true) }

    #expect(History.expired(from: items, policy: policy(1, keepsPinned: true)).isEmpty)
}

@Test("Pinned dictations expire like any other when they aren't kept")
func pinnedExpireWhenNotKept() {
    let oldest = run(0, pinned: true)
    let older = run(1)
    let newest = run(2)

    let expired = History.expired(from: [oldest, older, newest], policy: policy(1, keepsPinned: false))

    #expect(expired == [oldest.id, older.id])
}

@Test("With pinning off, pinned dictations count toward the limit")
func pinnedCountTowardTheLimitWhenNotKept() {
    let pinned = (0..<3).map { run(Double($0), pinned: true) }
    let unpinned = (10..<12).map { run(Double($0)) }

    let expired = History.expired(from: pinned + unpinned, policy: policy(2, keepsPinned: false))

    // Only the two newest survive, pinned or not.
    #expect(expired == Set(pinned.map(\.id)))
}

import Foundation
import Testing
@testable import OrbitFlowStats

/// A week's worth of dictation, reduced to the four figures Settings shows.
///
/// The samples are built relative to a fixed `now` so a test never depends on the day it
/// runs, and the window boundary can be landed on exactly.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)

private func sample(
    daysAgo: Double = 1,
    words: Int = 10,
    latency: Double = 0.3,
    corrections: Int = 0,
    onDevice: Bool = true
) -> DictationSample {
    DictationSample(
        date: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
        words: words,
        processSeconds: latency,
        corrections: corrections,
        isOnDevice: onDevice
    )
}

@Test("No runs in the window reports nothing rather than zero")
func emptyWindow() {
    let stats = DictationStats.over([], since: weekAgo)

    #expect(stats.words == 0)
    #expect(stats.corrections == 0)
    // A latency of zero and no dictations at all are different facts, and the strip has to
    // be able to tell them apart to show "—".
    #expect(stats.medianLatency == nil)
    #expect(stats.onDeviceShare == nil)
}

@Test("Words and corrections add up across runs")
func totals() {
    let stats = DictationStats.over(
        [sample(words: 12, corrections: 1), sample(words: 30, corrections: 2)],
        since: weekAgo
    )

    #expect(stats.words == 42)
    #expect(stats.corrections == 3)
}

@Test("An odd number of runs takes the middle latency")
func oddMedian() {
    let stats = DictationStats.over(
        [sample(latency: 0.2), sample(latency: 9.0), sample(latency: 0.4)],
        since: weekAgo
    )

    // Median, not mean: one slow cloud round trip must not become the number people read
    // as "how fast is this". The mean here would be 3.2s.
    #expect(stats.medianLatency == 0.4)
}

@Test("An even number of runs averages the two middle latencies")
func evenMedian() {
    let stats = DictationStats.over(
        [sample(latency: 0.2), sample(latency: 0.4), sample(latency: 0.6), sample(latency: 1.0)],
        since: weekAgo
    )

    #expect(stats.medianLatency == 0.5)
}

@Test("Runs older than the window are left out")
func windowExcludesOlderRuns() {
    let stats = DictationStats.over(
        [sample(daysAgo: 2, words: 10), sample(daysAgo: 9, words: 100)],
        since: weekAgo
    )

    #expect(stats.words == 10)
}

@Test("A run exactly on the boundary counts")
func boundaryIsInclusive() {
    let stats = DictationStats.over([sample(daysAgo: 7, words: 5)], since: weekAgo)

    #expect(stats.words == 5)
}

@Test("On-device share is the fraction of runs that stayed on the Mac")
func onDeviceShare() {
    let stats = DictationStats.over(
        [sample(onDevice: true), sample(onDevice: true), sample(onDevice: false), sample(onDevice: true)],
        since: weekAgo
    )

    #expect(stats.onDeviceShare == 0.75)
}

@Test("Runs outside the window don't drag the on-device share")
func shareIgnoresOlderRuns() {
    let stats = DictationStats.over(
        [sample(daysAgo: 1, onDevice: true), sample(daysAgo: 30, onDevice: false)],
        since: weekAgo
    )

    #expect(stats.onDeviceShare == 1.0)
}

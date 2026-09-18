import Foundation

/// One completed dictation, reduced to what the week's figures need.
///
/// Deliberately not `DictationRun`: this target knows nothing about the log format, the
/// rewrite history or which engine names are local. The app decides all of that and hands
/// over four facts, which is what keeps the arithmetic testable without a run log.
public struct DictationSample: Sendable {
    public let date: Date
    public let words: Int
    /// Release → final text ready. The latency the user actually feels.
    public let processSeconds: Double
    public let corrections: Int
    /// Whether this run stayed on the Mac. The caller decides; "on device" is a fact about
    /// engines, not about statistics.
    public let isOnDevice: Bool

    public init(date: Date, words: Int, processSeconds: Double, corrections: Int, isOnDevice: Bool) {
        self.date = date
        self.words = words
        self.processSeconds = processSeconds
        self.corrections = corrections
        self.isOnDevice = isOnDevice
    }
}

/// What Settings shows above the row list: this week, in four numbers.
public struct DictationStats: Sendable, Equatable {
    public let words: Int
    /// Median, not mean. One twelve-second cloud round trip shouldn't become the number
    /// people read as "how fast is this".
    public let medianLatency: Double?
    public let corrections: Int
    /// 0...1, or nil when nothing ran. No data and a zero share are different facts, and
    /// the strip renders them differently.
    public let onDeviceShare: Double?

    public init(words: Int, medianLatency: Double?, corrections: Int, onDeviceShare: Double?) {
        self.words = words
        self.medianLatency = medianLatency
        self.corrections = corrections
        self.onDeviceShare = onDeviceShare
    }

    /// Reduces the samples on or after `since`. The boundary is inclusive, so "this week"
    /// means seven days including the moment seven days ago, not six and a bit.
    public static func over(_ samples: [DictationSample], since: Date) -> DictationStats {
        let window = samples.filter { $0.date >= since }
        guard !window.isEmpty else {
            return DictationStats(words: 0, medianLatency: nil, corrections: 0, onDeviceShare: nil)
        }

        let latencies = window.map(\.processSeconds).sorted()
        let middle = latencies.count / 2
        let median = latencies.count.isMultiple(of: 2)
            ? (latencies[middle - 1] + latencies[middle]) / 2
            : latencies[middle]

        return DictationStats(
            words: window.reduce(0) { $0 + $1.words },
            medianLatency: median,
            corrections: window.reduce(0) { $0 + $1.corrections },
            onDeviceShare: Double(window.count { $0.isOnDevice }) / Double(window.count)
        )
    }
}

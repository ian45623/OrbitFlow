import Foundation

/// The three jobs the AI Models page covers.
public enum ModelJob: CaseIterable, Sendable {
    case speech
    case rewrite
    case readAloud
}

/// How good the result is. Three steps, because a finer scale would be a precision this
/// app cannot honestly claim — nothing here is benchmarked at runtime.
public enum Quality: Int, Sendable, Comparable {
    case good = 1
    case excellent = 2
    case exceptional = 3

    public var displayName: String {
        switch self {
        case .good: "Good"
        case .excellent: "Excellent"
        case .exceptional: "Exceptional"
        }
    }

    public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
}

/// How quickly it answers. Ordered so that a higher raw value is faster, which lets the
/// readout average quality and speed with the same arithmetic.
public enum Speed: Int, Sendable, Comparable {
    case network = 1
    case fast = 2
    case instant = 3

    public var displayName: String {
        switch self {
        case .network: "Network"
        case .fast: "Fast"
        case .instant: "Instant"
        }
    }

    public static func < (a: Speed, b: Speed) -> Bool { a.rawValue < b.rawValue }
}

/// How good the *selected* system voice is.
///
/// A parameter rather than a lookup, so this target never imports AVFoundation and the
/// grades stay testable without a speech synthesiser. The view maps
/// `AVSpeechSynthesisVoice.quality` onto it.
public enum VoiceGrade: Sendable {
    case standard
    case enhanced
    case premium
}

/// One option's two grades.
///
/// These are **authored constants, not measurements**. Nothing in the app benchmarks
/// anything, so every number here is an editorial claim, kept in one file so that
/// revising it is one diff rather than a hunt through views.
public struct ModelGrade: Sendable {
    public let quality: Quality
    public let speed: Speed

    public init(quality: Quality, speed: Speed) {
        self.quality = quality
        self.speed = speed
    }

    /// The grade for one job on one source, or `nil` when that combination does not
    /// exist — speech has no cloud engine, and rewriting has no local model separate
    /// from Apple Intelligence. `nil` is what makes those two segments disabled.
    public static func grade(job: ModelJob, source: ModelSource, voice: VoiceGrade) -> ModelGrade? {
        switch (job, source) {
        case (.speech, .apple):
            // Streams while you speak, so nothing is ever waited for.
            ModelGrade(quality: .good, speed: .instant)
        case (.speech, .local):
            // Parakeet is more accurate on English but resolves only on release.
            ModelGrade(quality: .excellent, speed: .fast)
        case (.speech, .cloud):
            nil

        case (.rewrite, .apple):
            // ~3B, built by Apple for summarization and refinement — this exact job.
            // Excellent rather than good: it is the recommended local rewrite, and
            // grading it bottom would push people to the cloud for no reason.
            ModelGrade(quality: .excellent, speed: .instant)
        case (.rewrite, .local):
            nil
        case (.rewrite, .cloud):
            // A claim about the tier, not the user's configured model — a cheap model
            // lights the same bar. The alternative is a model-ID table that goes stale
            // every time a provider ships.
            ModelGrade(quality: .exceptional, speed: .network)

        case (.readAloud, .apple):
            // The one computed grade. "Apple TTS" is not one product: a default voice is
            // mediocre and a Premium one is genuinely very good.
            switch voice {
            case .standard: ModelGrade(quality: .good, speed: .instant)
            case .enhanced: ModelGrade(quality: .excellent, speed: .instant)
            case .premium: ModelGrade(quality: .exceptional, speed: .instant)
            }
        case (.readAloud, .local):
            ModelGrade(quality: .excellent, speed: .fast)
        case (.readAloud, .cloud):
            ModelGrade(quality: .exceptional, speed: .network)
        }
    }

    /// The header's two bars and the "Runs on" line.
    public struct Readout: Sendable {
        public let quality: Quality
        public let speed: Speed
        public let qualityFraction: Double
        public let speedFraction: Double
        /// True when any job is set to cloud. Drives "Mac + cloud" and the caution dot.
        public let leavesMac: Bool
    }

    public static func readout(
        speech: ModelSource,
        rewrite: ModelSource,
        readAloud: ModelSource,
        voice: VoiceGrade
    ) -> Readout {
        let pairs: [(ModelJob, ModelSource)] = [
            (.speech, speech), (.rewrite, rewrite), (.readAloud, readAloud),
        ]
        // A source with no grade is impossible through the UI — its segment is disabled —
        // but a value persisted by another build must not trap. Falling back to Apple's
        // grade is the conservative reading: it is what the row shows when nothing else
        // is reachable.
        let grades = pairs.map { job, source in
            grade(job: job, source: source, voice: voice)
                ?? grade(job: job, source: .apple, voice: voice)
                ?? ModelGrade(quality: .good, speed: .instant)
        }

        let qualityTotal = grades.reduce(0) { $0 + $1.quality.rawValue }
        let speedTotal = grades.reduce(0) { $0 + $1.speed.rawValue }
        let count = Double(grades.count)

        return Readout(
            quality: Quality(rawValue: Int((Double(qualityTotal) / count).rounded())) ?? .good,
            speed: Speed(rawValue: Int((Double(speedTotal) / count).rounded())) ?? .instant,
            qualityFraction: Double(qualityTotal) / (count * 3),
            speedFraction: Double(speedTotal) / (count * 3),
            leavesMac: pairs.contains { $0.1 == .cloud }
        )
    }
}

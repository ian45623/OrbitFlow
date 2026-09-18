import Foundation

/// One dictation, reduced to the corrections that fired in it.
///
/// The run log knows far more than this; the dictionary only needs to know when something
/// fired and what it wrote, which is what keeps this file free of the log's format.
public struct CorrectionRecord: Sendable {
    public let date: Date
    public let corrections: [AppliedCorrection]

    public init(date: Date, corrections: [AppliedCorrection]) {
        self.date = date
        self.corrections = corrections
    }
}

/// What an entry has actually done.
public struct EntryEvidence: Sendable, Equatable {
    public let hits: Int
    public let lastFired: Date?

    public init(hits: Int, lastFired: Date?) {
        self.hits = hits
        self.lastFired = lastFired
    }
}

/// A reason an entry is likely to fire on text the user didn't mean.
public struct DictionaryRisk: Sendable, Equatable {
    /// The word this also matches, when the risk is a glued phrase. Nil when the trigger is
    /// simply an ordinary word.
    public let alsoMatches: String?
    public let message: String
}

/// A fix the user has made by hand often enough that it should be an entry.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public var id: String { "\(hear)→\(write)" }
    public let hear: String
    public let write: String
    public let times: Int
}

/// Evidence, risk and suggestions: everything the Dictionary panel shows about an entry
/// beyond the entry itself.
///
/// All of it is derived. Nothing here is stored, because everything it needs is already
/// recorded — corrections travel with the runs that fired them, and the transcripts keep
/// both what the engine heard and what the user changed it to.
public enum DictionaryEvidence {

    // MARK: - Evidence

    /// How often each entry fired, and when it last did.
    ///
    /// Matched on the *written* text rather than the heard text: that is what the
    /// correction produced and what the entry owns. Two entries writing the same text share
    /// their evidence, which is honest — nothing in the record can tell them apart either.
    public static func evidence(
        for entries: [DictionaryEntry],
        in runs: [CorrectionRecord]
    ) -> [UUID: EntryEvidence] {
        var hits: [String: Int] = [:]
        var last: [String: Date] = [:]

        for run in runs {
            for correction in run.corrections {
                let key = normalized(correction.to)
                hits[key, default: 0] += correction.count
                if let previous = last[key] {
                    last[key] = max(previous, run.date)
                } else {
                    last[key] = run.date
                }
            }
        }

        return entries.reduce(into: [:]) { evidence, entry in
            // A term feeds engine biasing and never rewrites anything, so it has no hits to
            // report — and "never fired" would read as a fault rather than as normal.
            guard entry.kind == .correction else {
                evidence[entry.id] = EntryEvidence(hits: 0, lastFired: nil)
                return
            }
            let key = normalized(entry.write)
            evidence[entry.id] = EntryEvidence(hits: hits[key] ?? 0, lastFired: last[key])
        }
    }

    // MARK: - Risk

    /// Whether this entry is likely to fire on something the user didn't mean.
    ///
    /// Two ways that happens: the trigger is an ordinary English word, or the trigger is a
    /// phrase whose glued form is itself a word — the corrector matches the gap inside a
    /// phrase as optional, so "super base" also matches "superbase".
    ///
    /// `isRealWord` is injected because the only dictionary of real words on hand belongs to
    /// macOS, and this target has no business importing AppKit.
    public static func risk(
        of entry: DictionaryEntry,
        isRealWord: (String) -> Bool
    ) -> DictionaryRisk? {
        guard entry.kind == .correction, !entry.requiresPhrase else { return nil }

        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return nil }

        let parts = trigger.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })

        if parts.count == 1, DictionaryWarning.isCommonWord(String(parts[0])) {
            return DictionaryRisk(
                alsoMatches: nil,
                message: "“\(trigger)” is an ordinary word, so this fires whenever you say it."
            )
        }

        if parts.count > 1 {
            let glued = parts.joined()
            if isRealWord(glued) {
                return DictionaryRisk(
                    alsoMatches: glued,
                    message: "This also matches the word “\(glued)”, because the gap in a "
                        + "phrase is optional. Require the full phrase?"
                )
            }
        }

        return nil
    }

    // MARK: - Suggestions

    /// Fixes the user has made by hand, repeated often enough to be worth an entry.
    ///
    /// Only single-token substitutions at the same position count. Insertions, deletions and
    /// multi-word changes are editing rather than a misheard word, and a wrong suggestion
    /// costs more than a missing one.
    public static func suggestions(
        from pairs: [(original: String, corrected: String)],
        existing: [DictionaryEntry] = [],
        minimum: Int = 2
    ) -> [Suggestion] {
        var counts: [String: (hear: String, write: String, times: Int)] = [:]

        for pair in pairs {
            guard let fix = substitution(from: pair.original, to: pair.corrected) else { continue }
            let key = "\(normalized(fix.hear))→\(normalized(fix.write))"
            counts[key, default: (fix.hear, fix.write, 0)].times += 1
        }

        let covered = Set(existing.filter { $0.kind == .correction }.map { normalized($0.hear) })

        return counts.values
            .filter { $0.times >= minimum && !covered.contains(normalized($0.hear)) }
            .map { Suggestion(hear: $0.hear, write: $0.write, times: $0.times) }
            .sorted { $0.times != $1.times ? $0.times > $1.times : $0.hear < $1.hear }
    }

    /// The one contiguous run of words that differs between two transcripts, when the
    /// difference is a single replacement. Nil for anything more complicated.
    private static func substitution(from original: String, to corrected: String) -> (hear: String, write: String)? {
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard before != after else { return nil }

        var head = 0
        while head < before.count, head < after.count,
              normalized(before[head]) == normalized(after[head]) {
            head += 1
        }

        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              normalized(before[before.count - 1 - tail]) == normalized(after[after.count - 1 - tail]) {
            tail += 1
        }

        let heard = before[head..<(before.count - tail)]
        let written = after[head..<(after.count - tail)]

        // Both sides must be non-empty — an empty side is an insertion or a deletion — and
        // the written side must be a single word, which is what a misheard word looks like
        // once it has been fixed.
        guard !heard.isEmpty, written.count == 1 else { return nil }
        return (heard.joined(separator: " "), written.joined())
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

import Foundation

/// Why an output was refused. Carried rather than reduced to a Bool because the caller
/// logs it, and "rejected" with no reason is an unfixable bug report.
public enum Rejection: Equatable, Sendable {
    case empty
    case inventedWords([String])
    case lengthRatio(Double)
    case preambleTell(String)

    public var summary: String {
        switch self {
        case .empty:
            "empty input or output"
        case .inventedWords(let words):
            "invented words: \(words.joined(separator: ", "))"
        case .lengthRatio(let ratio):
            "length ratio \(String(format: "%.2f", ratio))"
        case .preambleTell(let tell):
            "model preamble: \"\(tell)\""
        }
    }
}

/// Rejects output that isn't recognizably a processed version of the input.
///
/// The failure this defends against is real and was reproduced during development:
/// dictate "what is the capital of france" and the model helpfully returns "The capital
/// of France is Paris." — which would then be typed into the user's document.
///
/// The checks are mode-dependent, and that is the subtlest decision in this tier:
///
/// - **Faithful** is a cleanup. Cleanup is subtractive — it deletes fillers, fixes
///   punctuation, applies spoken corrections — so it has essentially no reason to
///   introduce a content word that wasn't spoken. "Paris" never appears in the input,
///   so it's the tell, and it's the strongest signal available.
/// - **Rewrite modes** introduce words by construction. Applying the invented-words
///   check to them would reject nearly every good result and silently fall back to the
///   rule formatter — the feature would appear to do nothing at all. They get the length
///   band and the preamble check only.
///
// ponytail: rewrite modes therefore cannot detect "the model answered the dictated
// question instead of rewriting it" — the invented-word signal is unavailable by
// construction. Prompt-level defense only (see RewriteMode.preamble). If this bites in
// practice, add a second cheap classification call, or restrict rewrite modes to text
// that ends in a declarative sentence.
public enum RewriteGuard {
    /// - Returns: `nil` when the output is acceptable, otherwise why it was refused.
    public static func rejection(
        original: String,
        output: String,
        mode: RewriteMode
    ) -> Rejection? {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .empty }

        let originalTokens = contentWords(original)
        guard !originalTokens.isEmpty else { return .empty }
        let outputTokens = contentWords(output)

        // Tells are checked first, before the invented-words and ratio checks, because
        // all three would reject "Here's the rewritten text: …" and `.preambleTell` is
        // the only one of the three that says something actionable in the log. Order
        // affects the *reported reason*, never whether the output is accepted.
        //
        // A model that starts explaining itself has stopped being a text processor.
        let lowered = output.lowercased()
        if let tell = tells.first(where: { lowered.hasPrefix($0) }) {
            return .preambleTell(tell)
        }

        if !mode.isRewrite {
            let vocabulary = Set(originalTokens)
            let invented = outputTokens.filter { !vocabulary.contains($0) }
            if !invented.isEmpty { return .inventedWords(Array(invented.prefix(5))) }
        }

        // Measured against the *filler-discounted* input, not the raw one. A raw
        // denominator conflates "the model truncated my sentence" with "the input was
        // 80% filler and was legitimately cut in half" — with a raw denominator those
        // two land at 0.14 and 0.21, too close to separate. Discounting fillers on both
        // sides pushes real cleanups to 0.6–1.0 and leaves the failures below 0.2.
        let bounds: ClosedRange<Double> = mode.isRewrite ? 0.3...3.0 : 0.35...1.5
        let ratio = Double(outputTokens.count) / Double(max(1, spokenWordCount(original)))
        if !bounds.contains(ratio) { return .lengthRatio(ratio) }

        return nil
    }

    private static let tells = [
        "here's the cleaned", "here is the cleaned",
        "here's the rewritten", "here is the rewritten",
        "cleaned transcript", "rewritten transcript",
        "sure,", "certainly,", "i cannot", "i can't", "as an ai",
    ]

    /// Lowercased alphanumeric words, minus the function words that punctuation-fixing
    /// legitimately shuffles. Contractions split so "isn't" matches "isn t".
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopWords.contains($0) }
    }

    /// Deliberately small. Every word here is one the guard stops policing, so it only
    /// covers words a cleanup pass may genuinely insert or drop while re-punctuating.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then",
        "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// Content words minus conversational filler — an estimate of how much the speaker
    /// actually *said*, used as the denominator for the length check.
    static func spokenWordCount(_ text: String) -> Int {
        contentWords(text).count { !fillerWords.contains($0) }
    }

    /// Broader than `RuleBasedFormatter`'s strip list on purpose. This set only affects
    /// the guard's denominator — it never removes anything from the user's text — so it
    /// can afford to be aggressive about discourse markers an LLM legitimately deletes.
    private static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm", "like", "basically", "actually",
        "literally", "just", "really", "okay", "ok", "well", "right", "anyway",
        "i", "mean", "you", "know", "kind", "sort", "of", "stuff", "thing", "things",
    ]
}

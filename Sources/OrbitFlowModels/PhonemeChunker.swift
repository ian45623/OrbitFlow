/// Splits a phoneme string into pieces a local voice can actually speak.
///
/// Kokoro's ALBERT context window caps one synthesis call at 510 phonemes — roughly
/// ninety words. Feed it more and it throws rather than truncating, so read aloud went
/// silent on any real selection: "phoneme sequence has 807 characters (max 510)".
///
/// FluidAudio carries an equivalent chunker, but it is `internal`, and
/// `KokoroAneManager.synthesize(text:)` does not apply it on the caller's behalf. Rather
/// than cap what the user may select, we chunk here and speak the pieces in order.
///
/// Operating on phonemes rather than raw text is deliberate: the cap is counted in
/// phonemes, and splitting the text first would mean guessing how many phonemes a
/// sentence becomes. Chunking after G2P also means decimals, abbreviations and quotes
/// have already been resolved, so a break can never land inside "3.14" or "Dr.".
public enum PhonemeChunker {

    /// Where a break sounds natural. These are the pause cues the vocabulary encodes, so
    /// breaking *after* one keeps the pause with the clause it closes — break before it
    /// and the next chunk opens on a comma.
    public static let boundaryPunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", "—",
    ]

    /// Chunks of at most `maxLength` characters, split at the latest natural boundary.
    ///
    /// - Returns: one chunk when the input already fits, `[]` when there is nothing to
    ///   say, and otherwise the pieces in order. Joining them with a space reproduces the
    ///   input: a passage the user selected is a passage they hear in full.
    public static func chunk(
        _ phonemes: String,
        maxLength: Int,
        boundaryPunctuation: Set<Character> = boundaryPunctuation
    ) -> [String] {
        precondition(maxLength > 0, "maxLength must be positive")

        let characters = Array(phonemes)
        let count = characters.count

        // The common case: one call, no seams.
        if count <= maxLength {
            let trimmed = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        func isBoundary(_ character: Character) -> Bool {
            character.isWhitespace || boundaryPunctuation.contains(character)
        }

        var chunks: [String] = []
        var start = 0
        while start < count, characters[start].isWhitespace { start += 1 }

        while count - start > maxLength {
            let windowEnd = start + maxLength

            // The latest boundary in the window, so chunks stay as full as possible.
            var breakAt = -1
            var index = windowEnd - 1
            while index > start {
                if isBoundary(characters[index]) {
                    breakAt = index + 1
                    break
                }
                index -= 1
            }
            // One unbroken run longer than the cap — rare in real phonemes, but it must
            // still produce something speakable rather than loop forever.
            if breakAt <= start { breakAt = windowEnd }

            append(characters[start..<breakAt], to: &chunks)
            start = breakAt
            while start < count, characters[start].isWhitespace { start += 1 }
        }

        if start < count { append(characters[start..<count], to: &chunks) }
        return chunks
    }

    private static func append(_ slice: ArraySlice<Character>, to chunks: inout [String]) {
        let text = String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { chunks.append(text) }
    }
}

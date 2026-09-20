import Testing

@testable import OrbitFlowModels

/// Kokoro's ALBERT context window caps a synthesis call at 510 phonemes — about ninety
/// words. Nothing chunked the input, so any real passage threw
/// "phoneme sequence has 807 characters (max 510)" and read aloud went silent.
struct PhonemeChunkerTests {

    @Test("A passage already inside the cap is left whole")
    func shortPassageIsOneChunk() {
        #expect(PhonemeChunker.chunk("hɛloʊ wɜːld", maxLength: 510) == ["hɛloʊ wɜːld"])
    }

    @Test("Blank input produces nothing to speak")
    func blankIsEmpty() {
        #expect(PhonemeChunker.chunk("", maxLength: 510).isEmpty)
        #expect(PhonemeChunker.chunk("   \n ", maxLength: 510).isEmpty)
    }

    @Test("Every chunk stays within the cap")
    func chunksRespectTheCap() {
        let long = String(repeating: "abcd ", count: 400)   // 2000 characters
        for chunk in PhonemeChunker.chunk(long, maxLength: 100) {
            #expect(chunk.count <= 100)
        }
    }

    /// A word split down the middle is audible — the vocoder says the halves as two
    /// separate utterances. Breaking at whitespace is the whole point.
    @Test("Words are never split across a chunk boundary")
    func wordsAreNotSplit() {
        let words = (1...60).map { "word\($0)" }
        let chunks = PhonemeChunker.chunk(words.joined(separator: " "), maxLength: 50)
        #expect(chunks.joined(separator: " ").split(separator: " ").map(String.init) == words)
    }

    /// Prosody cues belong to the clause they close, so a break goes *after* the comma,
    /// not before it — otherwise the next chunk opens on a pause.
    @Test("Punctuation stays with the clause it closes")
    func punctuationLeadsTheBreak() {
        let chunks = PhonemeChunker.chunk("aaaaaaaa, bbbbbbbb, cccccccc", maxLength: 12)
        #expect(chunks.first == "aaaaaaaa,")
    }

    /// Degenerate input — one unbroken run longer than the cap — must still produce
    /// something speakable rather than looping or returning nothing.
    @Test("An unbroken run longer than the cap is hard-split")
    func unbrokenRunIsSplit() {
        let chunks = PhonemeChunker.chunk(String(repeating: "a", count: 25), maxLength: 10)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 10 })
        #expect(chunks.joined() == String(repeating: "a", count: 25))
    }

    @Test("Chunks carry no leading or trailing whitespace")
    func chunksAreTrimmed() {
        for chunk in PhonemeChunker.chunk(String(repeating: "ab cd ", count: 50), maxLength: 20) {
            #expect(chunk == chunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Nothing may be dropped: the passage the user selected is the passage they hear.
    @Test("Chunking loses no phonemes")
    func nothingIsLost() {
        let source = (1...80).map { "syl\($0)" }.joined(separator: " ")
        let rejoined = PhonemeChunker.chunk(source, maxLength: 60).joined(separator: " ")
        #expect(rejoined == source)
    }
}

import Foundation
import Testing
@testable import OrbitFlowDictionary

private let noon = Date(timeIntervalSince1970: 1_800_000_000)

private func record(_ minutesAfterNoon: Double, _ corrections: (from: String, to: String, count: Int)...) -> CorrectionRecord {
    CorrectionRecord(
        date: noon.addingTimeInterval(minutesAfterNoon * 60),
        corrections: corrections.map { AppliedCorrection(from: $0.from, to: $0.to, count: $0.count) }
    )
}

// MARK: - Evidence

@Test("An entry that has never fired reports no hits and no last-fired date")
func neverFired() {
    let entry = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")

    let evidence = DictionaryEvidence.evidence(for: [entry], in: [])[entry.id]

    #expect(evidence?.hits == 0)
    #expect(evidence?.lastFired == nil)
}

@Test("Hits add up across runs, counting every time a rule fired within one transcript")
func hitsAccumulate() {
    let entry = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")
    let runs = [
        record(0, (from: "cloud code", to: "Claude Code", count: 2)),
        record(30, (from: "cloud code", to: "Claude Code", count: 1)),
    ]

    #expect(DictionaryEvidence.evidence(for: [entry], in: runs)[entry.id]?.hits == 3)
}

@Test("Last fired is the most recent run, whatever order the runs arrive in")
func lastFiredIsLatest() {
    let entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    let runs = [
        record(90, (from: "super base", to: "Supabase", count: 1)),
        record(10, (from: "super base", to: "Supabase", count: 1)),
    ]

    #expect(DictionaryEvidence.evidence(for: [entry], in: runs)[entry.id]?.lastFired
        == noon.addingTimeInterval(90 * 60))
}

@Test("A correction for another entry doesn't count toward this one")
func hitsDontLeakBetweenEntries() {
    let claude = DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")
    let supabase = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    let runs = [record(0, (from: "super base", to: "Supabase", count: 4))]

    let evidence = DictionaryEvidence.evidence(for: [claude, supabase], in: runs)

    #expect(evidence[claude.id]?.hits == 0)
    #expect(evidence[supabase.id]?.hits == 4)
}

@Test("A term never fires a correction, so it always reports zero")
func termsHaveNoHits() {
    let term = DictionaryEntry.term("Anthropic")
    let runs = [record(0, (from: "Anthropic", to: "Anthropic", count: 3))]

    #expect(DictionaryEvidence.evidence(for: [term], in: runs)[term.id]?.hits == 0)
}

// MARK: - Risk

@Test("A trigger that is an ordinary English word is risky")
func commonWordTriggerIsRisky() {
    let entry = DictionaryEntry.correction(hear: "code", write: "Claude Code")

    #expect(DictionaryEvidence.risk(of: entry, isRealWord: { _ in false }) != nil)
}

@Test("A phrase whose glued form is a real word is risky, and the note names that word")
func gluedPhraseIsRisky() {
    let entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")

    // The corrector matches the gap inside a phrase as optional, so "super base" also
    // matches the single word "superbase". That's usually wanted — engines glue words
    // together — and occasionally a trap.
    let risk = DictionaryEvidence.risk(of: entry, isRealWord: { $0 == "superbase" })

    #expect(risk?.alsoMatches == "superbase")
}

@Test("A phrase whose glued form isn't a word is not risky")
func unusualPhraseIsNotRisky() {
    let entry = DictionaryEntry.correction(hear: "tee see util", write: "tccutil")

    #expect(DictionaryEvidence.risk(of: entry, isRealWord: { _ in false }) == nil)
}

@Test("An entry that already requires its phrase is no longer risky")
func requiringThePhraseClearsTheRisk() {
    var entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    entry.requiresPhrase = true

    #expect(DictionaryEvidence.risk(of: entry, isRealWord: { $0 == "superbase" }) == nil)
}

// MARK: - Require phrase

@Test("A phrase matches its glued form by default")
func gluedFormMatchesByDefault() {
    let corrector = DictionaryCorrector(entries: [.correction(hear: "super base", write: "Supabase")])

    #expect(corrector.apply(to: "the superbase docs").text == "the Supabase docs")
}

@Test("Requiring the phrase stops the glued form matching")
func requirePhraseStopsGluedForm() {
    var entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    entry.requiresPhrase = true
    let corrector = DictionaryCorrector(entries: [entry])

    #expect(corrector.apply(to: "the superbase docs").text == "the superbase docs")
}

@Test("Requiring the phrase still matches the spaced and hyphenated forms")
func requirePhraseKeepsRealSeparators() {
    var entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    entry.requiresPhrase = true
    let corrector = DictionaryCorrector(entries: [entry])

    #expect(corrector.apply(to: "super base and super-base").text == "Supabase and Supabase")
}

@Test("An entry requiring its phrase writes a distinct line, and reads back the same way")
func requirePhraseSurvivesTheFile() {
    var entry = DictionaryEntry.correction(hear: "super base", write: "Supabase")
    entry.requiresPhrase = true

    #expect(entry.fileLine == "super base => Supabase")
}

// MARK: - Suggestions

@Test("A fix repeated twice is suggested")
func repeatedFixIsSuggested() {
    let pairs = [
        (original: "run tee see util now", corrected: "run tccutil now"),
        (original: "the tee see util reset", corrected: "the tccutil reset"),
    ]

    let suggestions = DictionaryEvidence.suggestions(from: pairs)

    #expect(suggestions.count == 1)
    #expect(suggestions[0].hear == "tee see util")
    #expect(suggestions[0].write == "tccutil")
    #expect(suggestions[0].times == 2)
}

@Test("A fix seen only once is not suggested")
func singleFixIsNotSuggested() {
    let pairs = [(original: "call Ian back", corrected: "call Ian back")]

    #expect(DictionaryEvidence.suggestions(from: pairs).isEmpty)
}

@Test("A rewritten sentence is not mistaken for a correction")
func rewritesAreIgnored() {
    // Two words changed in different places: that's editing, not a misheard word, and a
    // wrong suggestion costs more than a missing one.
    let pairs = [
        (original: "please send the file today", corrected: "kindly send the document today"),
        (original: "please send the file today", corrected: "kindly send the document today"),
    ]

    #expect(DictionaryEvidence.suggestions(from: pairs).isEmpty)
}

@Test("A fix already covered by an entry is not suggested again")
func existingEntriesAreNotSuggested() {
    let pairs = [
        (original: "run tee see util now", corrected: "run tccutil now"),
        (original: "the tee see util reset", corrected: "the tccutil reset"),
    ]

    let suggestions = DictionaryEvidence.suggestions(
        from: pairs,
        existing: [.correction(hear: "tee see util", write: "tccutil")]
    )

    #expect(suggestions.isEmpty)
}

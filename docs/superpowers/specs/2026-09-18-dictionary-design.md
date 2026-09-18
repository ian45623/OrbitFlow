# Dictionary: entries that show their own evidence

The dictionary panel lists entries and lets you add or remove them, but says nothing about
whether any of them are doing anything. An entry that has never fired looks exactly like one
that fires twenty times a day, and a rule that quietly matches more than you meant looks
like a rule that works.

The redesign makes each entry carry its own evidence: how often it fired, when it last did,
and whether it's likely to fire on something you didn't mean.

Source: Claude Design project `9a584a41-ebbb-4ff3-bc34-a35043929068`, option 2c. Builds on
Foundation 1.0. Last of the five sub-projects.

## The screen

A header line — `12 ENTRIES · 38 HITS THIS WEEK` — then search, a three-way filter
(All / Words / Corrections) and **Add entry**. Then a table:

| Column | Contents |
|---|---|
| Type | `FIX` for a correction, `WORD` for a term |
| Entry | `cloud code → Claude Code` with the heard form struck through, or the term alone. Badges: `RISKY`, `NEVER FIRED` |
| Hits | Count, with a sparkline-free bar for the busiest entries |
| Last fired | Time today, weekday this week, "—" for never |

A risky row expands into an amber note explaining what else it matches, with **Require
phrase** and **Keep as is**. Below the table, **Suggested from your history**, then a footer:
`12 ENTRIES · PLAIN TEXT FILE` and **Show file**.

## Where the evidence comes from

Nothing new is stored. Every correction that fires is already recorded on the run that fired
it (`AppliedCorrection`, with `from`, `to` and `count`), so hits and last-fired are a fold
over the run log:

```swift
public struct EntryEvidence: Sendable, Equatable {
    public let hits: Int
    public let lastFired: Date?
}
public static func evidence(for entries: [DictionaryEntry], in runs: [CorrectionRecord]) -> [UUID: EntryEvidence]
```

`CorrectionRecord` is `(date, corrections: [AppliedCorrection])` — the run log reduced to
what this needs, so the dictionary target stays free of the log format. Matching is on the
`to` text, because that is what the correction wrote and what the entry owns; two entries
writing the same text share their evidence, which is honest — the user can't tell them apart
either.

Terms never fire a correction, so a term's evidence is always zero. `NEVER FIRED` is shown
for corrections only; a term with no hits isn't a problem, it's just a biasing hint.

## Risky entries

The corrector fences every pattern with word boundaries, but the gap inside a phrase is
matched as *optional*, so "super base" also matches the single word "superbase". That is
usually what you want — engines glue words together — and occasionally a trap.

An entry is risky when either is true:

1. Its trigger is an ordinary English word. `DictionaryWarning` already knows this set.
2. Its trigger is a phrase whose glued form is itself a real word.

The second needs a dictionary of real words, which is macOS's, not this target's, so it
arrives as an injected closure:

```swift
public static func risk(of entry: DictionaryEntry, isRealWord: (String) -> Bool) -> DictionaryRisk?
```

The app passes `NSSpellChecker`; tests pass a set. The panel's amber note names the word it
found: *"super base" also matches the word "superbase"*.

**Require phrase** sets a new entry field:

```swift
public var requiresPhrase: Bool   // default false
```

which makes the corrector match the gap as *mandatory* whitespace or a hyphen rather than an
optional one, so the glued single word stops matching. It writes to the plain-text file as
`super base => Supabase` — a second arrow form, chosen so old files still parse and new ones
stay readable.

## Suggestions from history

When someone fixes the same word the same way more than once, that is a dictionary entry
they haven't made yet. The detail pane already saves an edited transcript while keeping the
engine's own words in `original`, so the evidence is there:

```swift
public static func suggestions(from pairs: [(original: String, corrected: String)], minimum: Int = 2) -> [Suggestion]
```

A suggestion is a single-token substitution that appears at the same position in both
strings, repeated `minimum` times or more across different runs, and not already covered by
an entry. Multi-word edits, insertions and deletions are ignored: they're usually rewrites,
not corrections, and a wrong suggestion costs more than a missing one.

Each suggestion shows as `you fixed "tee see util" → tccutil 3×` with **Add**, which creates
the correction entry directly.

## Structure

```
Sources/OrbitFlowDictionary/DictionaryEvidence.swift   evidence, risk, suggestions (new, tested)
Sources/OrbitFlowDictionary/DictionaryEntry.swift      + requiresPhrase
Sources/OrbitFlowDictionary/DictionaryCorrector.swift  honours requiresPhrase
Sources/OrbitFlow/UI/DictionaryPanel.swift             rebuilt as the table
```

## Testing

1. **Unit** (`OrbitFlowDictionaryTests`, existing target):
   - evidence: no runs; one run with two corrections; the same correction across days picks
     the latest date; a term always reports zero.
   - risk: a common-word trigger; a phrase whose glued form is real; a phrase whose glued
     form isn't; an entry already requiring a phrase is never risky.
   - `requiresPhrase`: "super base" matches "superbase" by default and stops once the flag
     is set, while "super base" and "super-base" keep matching.
   - suggestions: a substitution repeated twice is suggested, once isn't; a multi-word edit
     isn't; one already covered by an entry isn't.
   - the existing contract vectors still pass unchanged.
2. **Manual**: add an entry and watch its hit count move after a dictation that fires it;
   flip Require phrase and confirm the file line changes and the glued form stops matching;
   accept a suggestion and confirm it becomes an entry.

## Out of scope

- Per-entry enable/disable, which already exists and keeps its current control.
- Importing or sharing dictionaries.

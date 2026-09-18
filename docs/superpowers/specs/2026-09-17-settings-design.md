# Settings: sidebar and one-line rows

Settings is one 1,089-line scrolling column of cards, each with a paragraph of explanation.
Finding a setting means reading the prose around it. The redesign splits it into eight
named sections with a sidebar, and reduces every setting to one line: label, one helper
line, control on the right.

Source: Claude Design project `9a584a41-ebbb-4ff3-bc34-a35043929068`, option 1d. Builds on
the Foundation 1.0 design system and reuses `StepRow`'s row shape.

## Layout

A two-pane window, 860×600.

**Sidebar** (200pt, `surface`): the eight sections, one selected, with a `MetaLabel` on the
right of a row when it has a state worth seeing at a glance — `OFF` for Cleanup & AI and
Read aloud, the entry count for Dictionary. A footer carries two status dots
(`MICROPHONE`, `ACCESSIBILITY`) and a version line — `v1.4.2 · UP TO DATE`.

**Content pane**: a section title in `DS.Font.display`, one line of subtitle, and a status
chip on the right when the section has one ("HOTKEY ARMED"). Then the rows, separated by
hairlines, no cards.

**Stats strip** at the bottom of the Dictation section only: `THIS WEEK` and four figures —
words dictated, median latency, corrections fired, on-device share.

## Row anatomy

One line each (rule 04):

- **Label** in `bodyEmphasis`, **helper** in `caption`, both left.
- **Control** right: a toggle, a `Segmented`, a menu, or a key list.
- **"?"** at the far right when there's more to say. It reveals the current long-form prose
  below the row. Nothing is deleted, it is folded away.

## The eight sections

Content comes from today's Settings; nothing is invented. Where 1d shows a control the app
has no setting for — its "Default mode" hold/hands-free switch and its "Paste ▸ At the
cursor" menu — the row is omitted rather than implemented: both gestures already work on
every key, and there is only one insertion target. Adding those settings is a product
decision, not a redesign.

| Section | Rows | Source today |
|---|---|---|
| Dictation | Push-to-talk keys (+ Add, Remove), sound on/off, recording pill size, cleanup on/off | "Shortcut keys", "Dictation pill", part of "Cleanup" |
| Speech model | Engine, compare mode, Parakeet download and progress | "Model" |
| Cleanup & AI | Cleanup tier, when to rewrite, provider, model, API key, rewrite mode | "Cleanup" |
| Read aloud | On/off, voice, speed, reading mode, voice downloads | "Read aloud" |
| Dictionary | Entry count and a button opening the Dictionary tab | new; the editor stays in the main window |
| History & privacy | What's kept and where, reveal the file, clear history, the "closing the window" note | "When you close the window", `RunLog.clear` |
| Updates | Auto-update, check now, current build, last check | "Updates" |
| General | Launch at login, install-location warning, Accessibility and Microphone status with buttons, re-run onboarding | "Launch at login", `accessibilityNotice` |

The Accessibility warning keeps its current behaviour, including "Try again" →
`reloadHotkey()`, and appears in General as well as inline in Dictation when the tap is
dead — a dead hotkey has to be visible from where the keys are set.

## Statistics

`THIS WEEK` needs four numbers from the run log: words dictated, median latency, corrections
fired, and the share of runs that never left the Mac.

This is the one piece of real logic in the sub-project, so it goes where it can be tested:
a new SwiftPM target **`OrbitFlowStats`**, following the pattern of `OrbitFlowDictionary`
and `OrbitFlowHotkey` — an executable target can't be imported by a test target, which is
why those exist.

```swift
public struct DictationSample: Sendable {   // one run, reduced to what stats need
    public let date: Date
    public let words: Int
    public let processSeconds: Double
    public let corrections: Int
    public let isOnDevice: Bool
}

public struct DictationStats: Sendable, Equatable {
    public let words: Int
    public let medianLatency: Double?
    public let corrections: Int
    public let onDeviceShare: Double?        // nil when there are no runs
    public static func over(_ samples: [DictationSample], since: Date) -> DictationStats
}
```

Decisions the tests pin down:

- **Median, not mean** — one 12-second cloud round trip shouldn't move the number people
  read as "how fast is this".
- Even counts average the two middle values.
- **No runs in the window** → zero words, nil latency, nil share; the strip renders "—"
  rather than "0.00s" or "0%", because no data and a zero are different facts.
- **Words** are whitespace-separated runs on the final text, so a corrected transcript
  counts what actually landed.
- **On-device** is decided by the caller and passed in, because which engine names count as
  local is app knowledge, not statistics.

The app maps `DictationRun` → `DictationSample`; `Settings` shows the result.

## Testing

1. **`OrbitFlowStats` unit tests** (new, swift-testing, run by `make test`): empty window,
   single run, odd and even medians, a week boundary exactly on the edge, mixed on-device
   and cloud, runs with no corrections field (older log lines).
2. **Manual**: every row still changes the same setting — shortcut add and remove, engine
   switch, Parakeet download, cleanup tier, rewrite provider and key, read-aloud voice and
   speed, auto-update, launch at login. The ⌘, window and the Settings tab both show the new
   layout.
3. **Regression**: `make test` (92 tests plus the new ones), and Settings' shortcut recorder
   still records, cancels and refuses.

## Migration

`SettingsWindow.swift` is 1,089 lines and becomes the sub-project's main risk. It splits:

```
UI/Settings/SettingsPanel.swift      sidebar + content frame, section enum
UI/Settings/SettingsRow.swift        the one-line row, and the "?" disclosure
UI/Settings/DictationSection.swift   one file per section
UI/Settings/SpeechModelSection.swift
…
```

Each section keeps its current bindings and behaviour; only its presentation changes. The
existing `group`/`note` helpers go away with the cards. `SettingsWindow` (the ⌘, wrapper)
and the main window's Settings tab both host `SettingsPanel`, unchanged in that respect.

## Out of scope

- New settings: hold-vs-hands-free mode, paste destination.
- The Dictionary editor, which has its own redesign (2c).
- History's own screen (2a).

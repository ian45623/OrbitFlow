# History → "Recent": filter rail, sessions, destinations

History is a flat list of transcripts, newest first, with a detail pane. It answers "what
did I say" but not "where did that go", and a day's dictations arrive as one undifferentiated
column. The redesign groups runs into sessions, filters them by what happened to them, and
records where each one landed.

Source: Claude Design project `9a584a41-ebbb-4ff3-bc34-a35043929068`, option 2a, which
supersedes 1c. Builds on Foundation 1.0.

## Three panes

| Pane | Width | Contents |
|---|---|---|
| Filter rail | 200 | **View**: Everything, Pinned, Rewritten, Corrected, Long form. **Landed in**: one row per app, busiest first. Each row carries its count in the mono slot. A shortcut legend sits at the bottom. |
| List | 320 | Search field, then session groups. A session header reads `SLACK · 11:18–11:23` with `4 · 312W` on the right. Rows show time, latency, a `REWRITTEN`/`CORRECTED ×2` tag, and the transcript's first lines. |
| Detail | rest | Today's `TranscriptionDetail`, with its header extended to `PARAKEET · 11:23 · 0.20s · LANDED IN SLACK` and Pin added to its actions. |

The tab keeps its place in the main window and is renamed **Recent**, because that is what
the pane is now: the recent past, not an archive.

## What has to be recorded that isn't

**Destination.** Nothing in `DictationRun` says where text went. The frontmost application
at the moment the key goes down *is* the destination — the HUD is a non-activating panel, so
focus never leaves it — and that is where it's captured, not at insertion, because a rewrite
can take seconds and the user may have moved on by then.

`DictationRun` gains two optional fields, decoded leniently like `corrections` and
`rewrites` before them, so existing log lines keep loading:

```swift
var destinationApp: String?      // "Slack", for display
var destinationBundleID: String? // "com.tinyspeck.slackmacgap", for grouping and icons
```

Runs recorded before this exists have neither, and group under "Unknown" rather than being
hidden — a filter that silently drops a user's history is worse than an honest gap.

**Pinned.** `var isPinned: Bool = false`, written through `RunLog.modify`, which already
exists for rewrites.

## Sessions

A session is consecutive runs into the same app with no more than **ten minutes** between
them. Ten is long enough to survive thinking mid-message and short enough that this
morning's Slack and this afternoon's Slack don't become one block.

This is the sub-project's real logic, so it goes in a new testable target
**`OrbitFlowHistory`**, following `OrbitFlowStats`:

```swift
public struct HistoryItem: Sendable, Identifiable {   // what grouping needs
    public let id: UUID
    public let date: Date
    public let destination: String?
    public let words: Int
    public let isPinned: Bool
    public let wasRewritten: Bool
    public let corrections: Int
}

public struct HistorySession: Sendable, Identifiable {
    public let destination: String?
    public let items: [HistoryItem]      // newest first
    public var started: Date
    public var ended: Date
    public var words: Int
}

public enum HistoryFilter: Sendable, Hashable {
    case everything, pinned, rewritten, corrected, longForm
    case destination(String)
}

public enum History {
    public static func sessions(_ items: [HistoryItem], gap: TimeInterval = 600) -> [HistorySession]
    public static func matching(_ filter: HistoryFilter, in items: [HistoryItem]) -> [HistoryItem]
    public static func counts(for items: [HistoryItem]) -> [HistoryFilter: Int]
    public static func destinations(in items: [HistoryItem]) -> [(name: String, count: Int)]
}
```

Decisions the tests pin down:

- **Long form is 100 words or more.** A threshold has to be somewhere; 100 words is about
  forty seconds of speech, which is where a dictation stops being a message and starts
  being a draft.
- A gap of exactly ten minutes **continues** the session; the eleventh minute starts a new
  one.
- A different app always starts a new session, however close in time.
- Runs with no destination group together under `nil`, and never merge with a named app.
- Sessions come back newest first, and so do the runs inside them.
- `counts` reports every filter, including zeros, so the rail doesn't reshape itself as
  history changes.
- `destinations` is ordered by count, then by name for stability when counts tie.

## Search

The existing search stays: case- and diacritic-insensitive substring over the transcript.
It now runs *after* the filter, so "everything matching 'migration' that landed in Cursor"
is expressible, and the session headers recompute from what's left.

## Structure

```
Sources/OrbitFlowHistory/History.swift      grouping, filters, counts  (new target, tested)
Tests/OrbitFlowHistoryTests/HistoryTests.swift
Sources/OrbitFlow/UI/History/RecentPane.swift    three-pane frame, selection, search
Sources/OrbitFlow/UI/History/FilterRail.swift    view + destination rows, shortcut legend
Sources/OrbitFlow/UI/History/SessionList.swift   session headers and rows
```

`TranscriptionDetail.swift` keeps its job and gains the destination in its header and a Pin
action. `MainWindow.swift` loses the list it currently holds, which moves to `SessionList`.

## Keyboard

The rail's legend advertises three, and all three are wired here: ⌘F focuses search, ⌘⏎
copies the selected transcript, ⌘⌥R runs the current rewrite mode on it. They work when the
Recent tab is showing, and nowhere else.

## Testing

1. **`OrbitFlowHistory` unit tests**: every decision listed above, plus an empty history and
   a single run.
2. **Manual**: dictate into two different apps and confirm each lands in its own session
   with the right destination; pin one and confirm it survives a relaunch; check that old
   runs recorded before this change still appear.
3. **Regression**: `make test`, and the existing detail pane — rewrite, read aloud, copy,
   delete — still works from the new list.

## Out of scope

- Icons per destination app. The design shows names only.
- Retention policy, export. History & privacy in Settings owns those.
- The Dictionary redesign (2c), which is the last sub-project.

# Read aloud

**Date:** 2026-09-15
**Scope:** macOS app only.
**Status:** designed, not implemented.

**Follows:** `2026-09-04-on-demand-rewrite-design.md`, which added the first "selection
in any app" entry point and the HUD notice this reuses.

---

## What this adds

Highlight text with the mouse in any app and the pill offers to read it aloud. Press ▶
and the text is saved to History as a `Read aloud` entry, then spoken with an on-device
system voice. Any History entry can also be replayed from its detail page.

The feature is off by default. It is switched on from a new **Read aloud** group in
Settings, which also picks the voice and speed.

"Transcriptions" is renamed **History** everywhere the user can see it, because it now
holds dictated, pasted, selected and read-aloud entries.

**Why not just macOS Speak Selection (⌥Esc)?** It already speaks a selection. What this
adds is the pill appearing on its own with no shortcut to remember, a saved copy of
everything read, and replay from History.

---

## 1. Decisions

| Question | Decision | Why |
|---|---|---|
| Trigger | Automatic on mouse-up, not a shortcut | The point is no shortcut. Apps that do not expose their selection via Accessibility silently get no pill; there is no simulated ⌘C fallback, because that cannot run on every mouse-up. |
| Detection | Mouse-up on the existing event tap, then an AX read | Smallest change. Per-app `AXObserver` fires on every caret move and Chrome never posts it; polling costs battery all day. |
| Keyboard selections (⇧-arrows, ⌘A) | Not detected | Accepted gap. An `AXObserver` can be added later on top of the same pill and `Speaker`. |
| Pill position | The existing pill, bottom-center | Reuses `HUDPanel` positioning. Forced to Full size, like notices. |
| Dismissal | Fades after 4 s if ▶ is not pressed; stays while speaking | |
| Controls | Pill: ▶/■ and ✕. Settings: voice and speed. | No pause/resume or sentence skip. |
| When text is saved | Only when ▶ is pressed | Highlighting is constant (deleting, dragging, private messages). Saving every highlight would fill History with fragments and keep text the user never chose to keep. |
| Clipboard | Untouched | The AX read already has the text; History keeps the copy. |
| Rename | Transcriptions → History, user-visible strings only | Type names, the `.transcriptions` case and the run log format stay, so existing history loads unchanged. |
| Replay | ▶ Read aloud on the History detail page | Makes the saved copy useful. Does not create a new entry. |

---

## 2. Components

| Piece | New / existing | Job |
|---|---|---|
| `HotkeyMonitor` | existing, +1 event type | Adds `leftMouseUp` to the tap mask and calls a new `onMouseUp`. The callback does nothing else: a slow tap is disabled by macOS. |
| `SelectedText.read() -> String?` | new, `Core/SelectedText.swift` | Reads `kAXSelectedTextAttribute` from the frontmost app's focused element. Returns nil when Orbit Flow itself is frontmost, for empty or whitespace-only text, and for the `AXSecureTextField` subrole (checked before the value is read). Queries through `AXUIElementCreateApplication(pid)` with a 0.25 s messaging timeout, not the system-wide element: a timeout set on the system-wide element is process-global and would change `TextInjector`'s behaviour. For the same reason nothing is extracted from `TextInjector`. |
| `Speaker` | new, `Core/Speaker.swift` | `@MainActor @Observable` wrapper around one `AVSpeechSynthesizer`: `speak(_:)`, `stop()`, `isSpeaking`, and `text` (what is being spoken, for the pill label). Reads voice and rate from `Settings` at `speak` time. One shared instance used by the pill, the History detail page and the Settings preview. |
| Offer rule | new pure function in `OrbitFlowHotkey` | `shouldOfferReadAloud(text:lastOffered:enabled:isBusy:) -> Bool`. `isBusy` is dictation running, a rewrite in flight, or a notice showing. Lives in a library target so it can be unit tested; the app target is an executable no test can import. |
| `DictationController` | existing, extended | Holds the offered text and the last-offered text; `offerReadAloud(_:)`, `readAloud()`, `stopReadingAloud()`. `needsFullHUD` is true while an offer is showing or `Speaker.isSpeaking`. |
| `HUDView` | existing, extended | In read-aloud mode shows ✕, the start of the text (one line, tail-truncated) and ▶ (■ while speaking) instead of discard, waveform and confirm. |
| `TranscriptionDetail` | existing, +1 button | ▶ Read aloud / ■ Stop, speaking the text shown on the page. |
| `Settings` + `SettingsPanel` | existing, extended | See §4. |

---

## 3. Flow

1. `leftMouseUp` in any app → `onMouseUp` → a `Task` waits ~50 ms (the app updates its
   selection after the event) → `SelectedText.read()`.
2. Offered only if `shouldOfferReadAloud` is true: setting on, text non-empty, text
   differs from the last offered text, nothing busy. The "differs" check is also
   what stops a click on the pill's own ▶ (itself a mouse-up, with the selection still in
   place) from re-offering. A mouse-up that finds no selection clears the last offered
   text, so deselecting and re-selecting the same passage offers it again.
3. The pill presents at Full size with the start of the text and ▶. A 4 s timer, using the
   same token pattern as `flash`, fades it if nothing is pressed.
4. ▶ → `RunLog.record(DictationRun(date: .now, engine: "Read aloud", audioSeconds: 0,
   processSeconds: 0, text: text))` → `Speaker.speak(text)` → button becomes ■. The timer
   is cancelled.
5. Speech finishes → pill fades.
6. ■, ✕ or Esc → `Speaker.stop()` and dismiss. Esc is swallowed only while an offer is
   showing or speech is running, matching the existing `onEscape` contract.
7. Talk key pressed while offered or speaking → stop speech, clear the offer, then start
   dictation as usual. Stopping first is required: the microphone would otherwise
   transcribe the voice.

A new highlight while speaking replaces the offer with ▶ for the new text; speech
continues until that ▶ (or ✕) is pressed. If the offer fades, the pill goes back to
showing what is being spoken, with ■.

Any speech shows the pill — including ▶ on the History detail page and the Settings
Preview — labelled with the spoken text and a ■, so there is always one place to stop it.

---

## 4. Settings and rename

**New settings** (`didSet` → `UserDefaults`, like the rest of `Settings`):

| Key | Type | Default |
|---|---|---|
| `readAloudEnabled` | `Bool` | `false` |
| `readAloudVoice` | `String?` (voice identifier) | `nil` = system default |
| `readAloudRate` | `Float` | `AVSpeechUtteranceDefaultSpeechRate` |

**"Read aloud" group** in `SettingsPanel`, using the existing `group` and `note` helpers:

- Toggle: "Offer to read highlighted text".
- Note: "Works in apps that share their selection with macOS — most native apps; some
  browsers and Electron apps don't."
- Accessibility notice (the existing one) when the permission is missing.
- Voice picker: `AVSpeechSynthesisVoice.speechVoices()` for the current language, sorted
  by quality, labelled e.g. "Zoe (Premium)", plus "System default". Note underneath:
  better voices are downloaded in System Settings → Accessibility → Spoken Content, with a
  button that opens that pane. Apps cannot download voices.
- Speed slider and a Preview button that speaks a short sample through `Speaker`.

**Rename** (visible strings only):

- `MainWindow.swift:29` — "Transcriptions" → "History"
- `MainWindow.swift:186` — "Search transcriptions" → "Search history"
- `TranscriptionDetail.swift:90` — back button "Transcriptions" → "History"
- The README does not mention the tab, so it needs no change.

---

## 5. Errors and edge cases

Rule: never interrupt the user; the failure mode is "no pill".

| Situation | Behaviour |
|---|---|
| AX returns nothing or times out | No pill. Log that the read was empty; never log the text. Any logging of selection text uses `privacy: .private`. |
| Password field | Skipped before the value is read. |
| Saved voice uninstalled | Fall back to system default; picker shows "System default". |
| Talk key while offered or speaking | Stop speech, clear offer, dictate normally. |
| Rewrite notice or dictation error while offering | Notice wins; offer is dropped. |
| Setting turned off mid-speech | Stop speech and dismiss. |
| Very long selection | Read and save all of it. No cap; ■ is one click, and a silent cutoff is a worse surprise. |
| Tap disabled by the system | Already re-armed by `HotkeyMonitor.handle`. |

---

## 6. Testing

**Unit test** in `OrbitFlowHotkeyTests` for `shouldOfferReadAloud`: offers for new
non-empty text; refuses when disabled, when dictating, for empty or whitespace text, and
for text equal to the last offered.

**Manual verification matrix:**

| # | Case | Expected |
|---|---|---|
| 1 | Drag-select in Safari, Notes, Mail, Pages | Pill offers ▶ |
| 2 | Drag-select in Chrome, Slack, VS Code, Terminal | Record actual result; keep the Settings note accurate |
| 3 | Double-click a word; triple-click a paragraph | Offered |
| 4 | Plain click in a text field (no selection) | No pill |
| 4a | Deselect, then re-select the same passage | Offered again |
| 5 | Press ▶ | Speech starts; exactly one `Read aloud` entry in History; no re-offer |
| 6 | Ignore the offer | Fades after ~4 s |
| 7 | ■, ✕, Esc while speaking | Speech stops, pill dismisses |
| 8 | Esc with no offer and no speech | Passes through to the app |
| 9 | Talk key mid-speech | Speech stops; dictation transcript does not contain the spoken voice |
| 10 | HUD size set to Compact | Offer still shows at Full size |
| 11 | Setting off | Nothing on highlight |
| 12 | Setting turned off mid-speech | Speech stops |
| 13 | Password field selection | Never offered |
| 14 | History detail ▶ | Replays; no new entry |
| 15 | Uninstall the chosen voice | Falls back to system default |
| 16 | Rename | Sidebar, search placeholder and back button read "History"; old entries still load |
| 17 | Clipboard before and after ▶ | Unchanged |

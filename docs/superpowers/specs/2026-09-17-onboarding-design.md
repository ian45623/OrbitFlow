# Onboarding: one screen, four steps

A new user's first launch today shows the main window and macOS's Accessibility prompt, with
no explanation of why either is there, and the microphone prompt arrives later, mid-dictation.
This replaces that with one window that explains the four things to set up and confirms each
one as it happens.

Source: Claude Design project `9a584a41-ebbb-4ff3-bc34-a35043929068`, option 2b, with 1e's
key-capture and first-dictation panels as the expanded content of those two steps. Builds on
`2026-09-17-design-system-foundation-design.md`.

## The screen

A single window, 720×620, no title bar, canvas ground.

- **Headline** "Talk instead of type." in `DS.Font.headline` (Newsreader 28).
- **Subhead** "Four things to set up. Everything stays on this Mac — no account, no cloud,
  no analytics."
- **Step counter** on the right: `MetaLabel` "2 OF 4" and a hairline progress bar.
- **Four `StepRow`s**, one expanded at a time.
- **Footer**: what the window is waiting for on the left (`MetaLabel`, e.g.
  "WAITING FOR ACCESSIBILITY…"), then "Skip for now" (`quiet`) and the primary button.

## The four steps

Each step owns three things: its state (`waiting`/`done`/`needsYou`), the words in its meta
slot, and what it shows when expanded.

**1. Microphone** — "Audio becomes text on this Mac."
Expanded: one line of help and an "Allow microphone" primary button that calls
`Permissions.requestMicrophone()`. macOS shows its prompt. Meta reads `NOT YET ALLOWED` →
`ALLOWED`. If the user denies it, macOS won't ask again, so the button becomes "Open System
Settings" and the help line says so.

**2. Accessibility** — "So it can see your key and paste at the cursor."
Expanded: the design's amber note — "macOS asks once. Orbit Flow appears in the list —
switch it on and come straight back." — and an "Open System Settings" primary button that
calls `Permissions.promptForAccessibility()` then `openAccessibilitySettings()`.
There is no notification when the grant lands, so the model polls `AXIsProcessTrusted()`
once a second while the window is open, exactly as `AppDelegate.retryActivation()` does
today. On success: meta flips to `ALLOWED`, `controller.reloadHotkey()` arms the key, and
the footer's waiting line clears.

**3. Your key** — "Hold it to talk. Suggested:" with `Right ⌥` in the meta slot.
Expanded (1e's panel): a field-styled box showing the current key, "Press again to replace"
beneath it, "Use this key" (primary) and "Try fn instead" (quiet). Pressing any key while
the box is live captures it.
This step is never blocking: it starts `done` if a shortcut is already set, which it always
is — `Settings.shortcutKeys` defaults to Right ⌥.

**4. First dictation** — "Say one sentence and watch it land."
Expanded (1e's panel): a real editable text box with the cursor in it, a `Waveform` and an
elapsed `Numeral` while recording, and `MetaLabel` "PARAKEET · 0.28s" — engine and latency —
once text lands. If the speech model still needs downloading, that line reads
`DOWNLOADING SPEECH MODEL…` instead. The user holds their key and speaks; the text arrives
through the normal dictation path, which is the point: it proves the key, the microphone,
the engine and the insertion all work together.
Meta: `30 SECONDS` → `DONE`.

## Insertion into our own window

`TextInjector` tries accessibility first and falls back to the pasteboard. Its AX path asks
the system-wide element for the focused element — and when the focused app is Orbit Flow
itself, that is a same-process AX call from the main thread, which can block until it times
out. The HUD never hits this because it is a non-activating panel and focus stays in the
user's app; the onboarding test box is the first place in the app where we are the focused
app.

So `TextInjector.insert` gains one guard: when
`NSWorkspace.shared.frontmostApplication?.processIdentifier` is our own pid, skip strategy 1
and paste. The pasteboard path is a real ⌘V into a real field, so the test still exercises
everything the user's own apps will use, minus the AX write we already know can't be
trusted without observing it.

## Showing and dismissing

`Settings.onboardingCompleted` (new, `UserDefaults`) records that the user finished or
skipped. `AppDelegate.applicationDidFinishLaunching` decides:

| Condition | Behaviour |
|---|---|
| `!onboardingCompleted` | Show onboarding. Main window stays closed. |
| Completed, but Accessibility or Microphone missing | Show onboarding, expanded on that step. |
| Otherwise | Today's behaviour, unchanged. |

While onboarding will show, the delegate does **not** call `promptForAccessibility()` — step
2 owns that prompt. `retryActivation()` still runs, so the key arms the moment the grant lands
whichever route the user took.

Also reachable from the menu bar ("Set up Orbit Flow…") and from Settings, which is how
someone who skipped gets back.

"Skip for now" sets `onboardingCompleted` and closes the window; the next launch reopens it
only if a permission is missing. The final button, "Start using Orbit Flow", sets the flag
and opens the main window.

## Structure

- **`OnboardingModel`** (`UI/Onboarding/OnboardingModel.swift`) — `@Observable`, `@MainActor`.
  Owns the current step, each step's state, the poll task, and the test dictation's result.
  Reads `Permissions` and `Settings`; talks to `DictationController` only through
  `reloadHotkey()`, `pauseHotkey()` and its published `state`/`transcript`. No view types.
- **`OnboardingWindow`** (`UI/Onboarding/OnboardingWindow.swift`) — the layout, built from
  `StepRow`, `ActionButton`, `MetaLabel`, `Waveform`.
- **`ShortcutRecorder`** (`UI/ShortcutRecorder.swift`) — the key-capture logic lifted out of
  `SettingsWindow` (currently ~70 lines of view-local state and a `NSEvent` monitor) so both
  screens share one implementation. `SettingsWindow` moves onto it in the same change; its
  behaviour, including the Escape-cancels and Caps-Lock-refusal cases, is unchanged.
- **Scene**: a `Window(id: "onboarding")` in `OrbitFlowApp`, `.windowResizability(.contentSize)`,
  hidden title bar, alongside the existing `main` and `comparison` windows.

## Error cases

| Case | What the user sees |
|---|---|
| Microphone denied earlier | Step 2's button becomes "Open System Settings"; help line explains macOS won't ask twice. |
| Accessibility granted, tap still fails | Footer keeps the waiting line and offers "Try again" → `reloadHotkey()`. This is the existing `accessibilityNotice` behaviour. |
| Speech model downloading | Step 4's meta reads `DOWNLOADING SPEECH MODEL…`; the hold still works, text just arrives later. |
| Dictation produces nothing | Step 4 stays open with "Nothing came through — hold the key and speak again." |
| Running from a purgeable path | Existing Settings warning is repeated in the footer, since a grant made against `~/Library/Caches` won't survive. |

## Testing

`OnboardingModel` is in the app target, which no test target can import, so the split is:

1. **Unit-testable**: nothing new. The one piece of pure logic — which step to open on —
   is a function of two booleans and the completed flag, and lives in `OnboardingModel` as
   a `static func firstIncompleteStep(...)`. If it grows past that, it moves to a new
   `OrbitFlowOnboarding` target with tests, the way the dictionary and hotkey targets did.
2. **Manual, on a clean machine state**, using a fresh user account or by resetting:
   `tccutil reset Accessibility ai.pivotstudio.orbitflow`,
   `tccutil reset Microphone ai.pivotstudio.orbitflow`,
   `defaults delete ai.pivotstudio.orbitflow onboardingCompleted`.
   Then: first launch shows onboarding; granting each permission flips its row live; the key
   step captures a new key and Settings agrees; the test dictation lands text in the box;
   "Start using Orbit Flow" opens the main window and doesn't come back next launch.
3. **Regression**: `make test` (92 tests) still passes, and Settings' own shortcut recorder
   still records, cancels on Escape and refuses Caps Lock after moving to `ShortcutRecorder`.

## Out of scope

- The "Speech model" step 1e had; 2b dropped it and step 4 reports download progress instead.
- Any change to what the permissions themselves are or how the hotkey works.
- Settings, History and Dictionary layouts, which have their own specs.

# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

**Orbit Flow** — push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up
text is typed into whatever had focus.

| | |
|---|---|
| Language | Swift 6, strict concurrency (`.swiftLanguageMode(.v6)`) |
| Platform floor | macOS 26 |
| UI | SwiftUI |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio |
| Bundle ID | `ai.pivotstudio.orbitflow` |

The app works and is in daily use.

**Targets.** `OrbitFlow` is the app. `OrbitFlowDictionary` is a library target, separate
because an executable target cannot be imported by a test target — anything worth unit
testing goes in a library target for that reason, not for reuse.

---

## The one rule that matters

**`Tests/OrbitFlowDictionaryTests/dictionary-test-vectors.json` is the specification for
correction behaviour.** Fixed cases with expected output. If you change how corrections
work, change the vectors first, watch the tests go red, then make them green. A corrector
change that quietly alters results without touching the vectors is how behaviour drifts
with nobody noticing.

```bash
make test                      # everything
swift test --filter VectorTests --scratch-path "$HOME/Library/Caches/OrbitFlowBuild/scratch"
```

---

## Build

**Always build with `make`, never a bare `swift build`.** `make` passes `--scratch-path`
outside the repo tree. If the repo ever sits in a file-provider synced folder (iCloud
Desktop/Documents, Dropbox), the sync engine touches files mid-compile and you get
`input file was modified during the build` on random object files — and a bare
`swift build` also drops a `.build/` inside the synced tree, which makes every later build
minutes slower.

```bash
make build     # compile
make test      # run the suites
make app       # bundle + sign
make install   # bundle, sign, copy to /Applications, launch
```

---

## Things that look like bugs and are not

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**The hotkey has two gestures, and the tap is not a bug.** A release within
`DictationController.tapLatchThreshold` (0.4s) *latches* recording on rather than ending it,
so tap-talk-tap works; a longer hold is push-to-talk as before and ends on release. Both live
in `hotkeyPressed()`/`hotkeyReleased()` — `HotkeyMonitor` stays a dumb transport that only
reports up and down. A key-down while anything is active always means stop, which is what
makes the second tap work. Don't "simplify" this into onPress/onRelease calling
begin/endDictation directly; that removes the tap gesture entirely.

**The tap watches `keyDown` as well as `flagsChanged`, and that is only for Escape.**
Escape discards an in-flight dictation — the same thing the pill's ✕ does. The consequence
is that the callback is handed every key-down on the system, so `handle` rejects anything
that isn't Escape before touching anything else; nothing is inspected, stored or logged, and
it must stay that way. The swallow rule is load-bearing in the other direction too: Escape is
consumed **only** when there is a recording to cancel, which is why `onEscape` returns `Bool`
and `DictationController` answers it from `state.isActive`. Swallow it unconditionally and
you break dismissing dialogs, leaving vim's insert mode, and clearing search fields in every
app on the machine, the whole time Orbit Flow is running.

**Closing the main window doesn't quit the app, and that's deliberate.** Dictation happens
in *other* apps — the hotkey is a `CGEventTap` that has nothing to do with any window — so
`applicationShouldTerminateAfterLastWindowClosed` returns `false` and the window is a reading
surface you close when you're done with it. Three ways back in, because the first one is not
guaranteed: the Dock icon (`applicationShouldHandleReopen`), **Open Orbit Flow** in the menu bar
(`openWindow(id: "main")`, the reliable one), and ⌘, for settings. Quit from the Dock, the
menu bar, or ⌘Q. If you ever make this app quit on window close, the key goes dead and the
only symptom is that dictation silently stops working.

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. If the overlay took key status, the user's text field would lose
focus and there would be nothing left to inject into. Everything else is replaceable.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

**Audio buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript — unstructured tasks have no ordering guarantee.

---

## Design system

`Sources/OrbitFlow/UI/DesignSystem.swift` defines every colour, size, radius, duration
and type token. `UI/Components.swift` holds the vocabulary built from them. **Views must not
contain literal values.** If a component needs a number that isn't a token, add the token
rather than inlining it.

The direction is **quiet instrument with a legible pulse** (Foundation 1.0, designed in
Claude Design; see `docs/superpowers/specs/2026-09-17-design-system-foundation-design.md`).
Flat surfaces, hairline separation, one live element. Warm paper in light appearance, warm
graphite in dark. Three bundled faces: **Instrument Sans** for interface, **Newsreader** for
prose and display lines, **JetBrains Mono** for instrumentation. They live in
`Resources/Fonts` and are registered by `ATSApplicationFontsPath`, so nothing is installed
into the user's Font Book, and every role falls back to the system face if the files are
missing.

Five rules, none negotiable:

- **01 Hue never carries state.** Surface and weight do. `DS.Color.signal` is red, it means
  recording, and nothing else in the app is ever red. `positive` green and `caution` amber
  appear on status indicators only, never as chrome — and never as the only signal, because
  a dot alone can't be read by everyone. The words next to it say the same thing.
- **02 Prose is serif**, capped at 66 characters (`DS.Font.proseMeasure`), with extra
  leading. It's writing, not log output.
- **03 All metadata is mono**, 10–11pt, uppercase, in a fixed slot — timings, counts,
  engine names, statuses. Use `MetaLabel`, which uppercases for you and holds the slot's
  width so a row doesn't twitch when a value changes. Everything else is sentence case:
  headings, buttons, body text, settings labels, help notes. Help notes are `DS.Font.caption`
  and stay sans — a sentence is not metadata.
- **04 One helper line per setting.** Anything longer goes behind a "?".
- **05 Only the waveform moves on its own.** Depth is one step: a hairline and a shade. No
  bevels, no glow, and **no gradients**.

`Waveform` in `Components.swift` is the only thing that animates on its own, because it is
showing live input. It samples at a fixed `DS.Motion.traceHz` rather than once per frame, so
the trace scrolls at the same speed on a 60Hz panel as on a 120Hz one.

This replaced a 1980s field-recorder direction (brushed panels, screws, vents, a VU needle,
silkscreen uppercase). If you find a token or comment still describing equipment, it's drift.

Explicitly ruled out: neon, vaporwave, synthwave, purple/pink gradients, glowing text, and the
warm-cream-plus-terracotta look every generated interface arrives in.

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.orbitflow
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**Two permissions, neither optional and neither requestable silently:** Accessibility (for
the `CGEventTap` and the AX text insert) and Microphone. The hotkey needs a `CGEventTap`
rather than `NSEvent` because `fn` and left/right modifier discrimination don't surface
through `NSEvent.addGlobalMonitorForEvents` or the Carbon hotkey API.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly, or it silently
returns nothing.

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "ai.pivotstudio.orbitflow"'
```

**Don't run the `.app` from the repo folder.** `make install` puts the running copy in
`/Applications`, and the bundle is staged and signed outside the repo — a file provider can
stamp `com.apple.FinderInfo` onto files inside an `.app` faster than `xattr -cr` can strip
them, and `codesign` hard-refuses anything carrying them.

---

## Regex, if you touch the dictionary

**NFC normalization is load-bearing.** macOS hands back decomposed strings in several places
— a filesystem read of the dictionary being the obvious one — and "café" decomposed is five
scalars where composed is four. The pattern and the text must be in the same form or an
accented trigger silently never matches. Don't remove
`precomposedStringWithCanonicalMapping`.

---

## Speed

Dictation is a latency product. The user has stopped talking and is waiting for text to
appear, so every pass between release and injection is on the critical path. Before adding
anything to that path, know what it costs; before making a model or provider choice, prefer
the faster option and let the user opt into a slower, better one rather than the reverse.

Anything that can fail slowly needs a timeout and a fallback that still produces text. A
stalled pass must never cost the user an utterance they already spoke.

---

## What isn't built

1. **Cloud AI rewrite tier** — designed and planned, not yet implemented. See
   `docs/superpowers/specs/2026-09-04-ai-rewrite-design.md` and the matching plan in
   `docs/superpowers/plans/`.
2. **Command Mode** — select text, hold a second key, "make this more formal."
3. **Onboarding** — a first-run window walking through the permissions.
4. **First notarized release.** `make release` signs with Developer ID, notarizes and
   staples, and refuses without a Developer ID. A trial run passed Gatekeeper; no notarized
   build has been published yet.

## What no amount of CI can verify

CI builds and tests the dictionary target only — the app target needs macOS 26 and the
Speech framework, which no runner image has. Synthetic key events cannot produce audio, so
speech → transcript → cleanup → injection needs a human holding the key and talking. Any
change to that path ends with a manual pass, not a green suite.

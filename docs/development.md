# Developing Orbit Flow

Building from source, how the pieces fit, and the macOS details that bite. For what the app
does, see the [README](../README.md). For packaging and signing, see
[distribution.md](distribution.md).

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant two permissions — neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |

Restart Orbit Flow after granting Accessibility. Then hold **Right ⌥** and talk.

### Installing on another Mac

```bash
make dist        # release build → ~/Desktop/Orbit Flow.zip
```

Or `make dmg` for the drag-to-Applications installer the Download button hands out.
Send the zip over (AirDrop, USB, cloud drive). The other Mac needs macOS 26 and Apple
silicon. There: unzip, drag **Orbit Flow.app** to Applications, and double-click, then grant
the same two permissions as above. With a Developer ID certificate in your keychain the build
is notarized and opens normally. Without one, macOS blocks the first launch: System Settings ▸
Privacy & Security ▸ **Open Anyway**. See [distribution.md](distribution.md).

### Shipping updates

```bash
make release     # commit + push first; publishes GitHub release build-<commit count>
```

Every installed copy picks it up from Settings ▸ Updates ▸ **Check for updates**. It
downloads the zip, quits, swaps itself, and reopens. No Gatekeeper prompt, and permissions
carry over.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore signs with a stable Developer ID (auto-detected via
`security find-identity`, falling back to ad-hoc). Verified: rebuild + reinstall keeps both
grants with no re-prompt.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.orbitflow
tccutil reset Microphone   ai.pivotstudio.orbitflow
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► AppleSpeechEngine
                                            │
                                       (transcript)
                                            ▼
                                      TextFormatter
                                            ▼
                                      TextInjector ─► focused app
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
discrimination don't surface through `NSEvent.addGlobalMonitorForEvents` or the Carbon
hotkey API. A session event tap is the only way to see them — which is why Accessibility
permission is a hard requirement rather than a nicety.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols so the
two components most likely to change can change without touching anything else.

### Layout

```
Sources/OrbitFlow/
├── OrbitFlowApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         CGEventTap on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap + format conversion + RMS
│   └── TextInjector.swift          AX insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   └── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber
├── Formatting/
│   └── TextFormatter.swift         protocol + RuleBasedFormatter
├── UI/
│   ├── HUDPanel.swift              non-activating floating panel
│   └── HUDView.swift               waveform + live transcript, Brand palette
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift
```

---

## Speech engine

Default is Apple's **`SpeechAnalyzer` / `SpeechTranscriber`**, new in macOS 26: no
dependency, no bundled model, no cloud path, real streaming with `.volatileResults` so
text appears while you're still talking. The OS downloads and manages model assets, so the
first run for a locale may pause on `AssetInstallationRequest`.

The alternative, selectable in Settings, is **Parakeet v3** via FluidAudio (CoreML on the
Neural Engine) — measurably better English WER, ~110× realtime, ~66 MB resident. It runs in
batch, so there's no live text while you talk. Both sit behind `TranscriptionEngine`;
`DictationController` doesn't know which one it has.

| | Apple SpeechTranscriber | Parakeet v3 (FluidAudio) | Whisper large-v3 (WhisperKit) |
|---|---|---|---|
| Dependency | none | SwiftPM | SwiftPM |
| Model download | OS-managed | ~600 MB | ~1.5 GB |
| English accuracy | good | best | good |
| Languages | many | 25 | 99 |
| Latency | low | ~80 ms | 200–500 ms |

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.orbitflow`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `OrbitFlow`** — distinct enough that `pkill -x OrbitFlow` cannot
  match a differently-named binary. The `Makefile` only ever targets `$(EXEC)`.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘) precisely because another tool may
  already own the key you'd reach for first. The event tap inspects only its own keycode
  and passes everything else through untouched.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.


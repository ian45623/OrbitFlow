# On-demand AI rewrite

**Date:** 2026-09-04
**Scope:** macOS app only.
**Status:** approved design, not yet implemented.
**Follows:** `2026-09-04-ai-rewrite-design.md`, which built the always-on tier this splits.

---

## What this adds

Today AI rewrite is all-or-nothing: switch it on and *every* dictation goes to the cloud
before it pastes. This separates the two things that were fused — **the rewrite** and
**the moment it runs** — so you can dictate raw and rewrite later, on text you point at.

Two new entry points, both reached by selecting text in any app and right-clicking:

1. **Rewrite in place.** The selection is rewritten and replaces itself, without the app
   taking focus.
2. **Open in Orbit Flow.** The selection is filed as a transcription and opened in the
   detail page, which already has modes, a custom-instruction field, an engine picker,
   and kept versions.

Nothing about audio capture, the hotkey, the HUD geometry, or the dictation tail changes.
`CloudRewriter`, `OnDeviceRewriter`, `RewriteMode`, and `RewriteGuard` are used exactly as
they are — this is a second caller of them, not a change to them.

---

## 1. The mechanism: macOS Services

macOS has one native way for an app to act on a selection made in a *different* app:
**Services**. A static `NSServices` array in `Info.plist` declares the menu rows; a
`servicesProvider` object on `NSApp` implements them. The system hands over the selected
text on an `NSPasteboard`.

No event tap, no polling, no second process, no accessibility hack beyond the AX grant
the app already holds for injection.

### 1.1 Menu shape

`Info.plist` `NSMenuItem` `default` strings support one `/`, which places the row in a
submenu. This is verified against system apps — Mail ships `Mail/New Email With
Selection`, Preview ships `Preview/Open images`.

```
right-click ▸ Services ▸
    Rewrite with Orbit Flow          NSMessage: rewriteDefault
    Orbit Flow ▸
        Faithful                     NSMessage: rewriteFaithful
        Casual                       NSMessage: rewriteCasual
        Professional                 NSMessage: rewriteProfessional
        Problem-solver               NSMessage: rewriteProblemSolver
        Open in Orbit Flow           NSMessage: openSelection
```

Six rows, six `@objc` methods, all but the last one line delegating to a shared
`rewrite(pboard:mode:)`.

**A submenu parent cannot be clicked.** This is AppKit, not Services — no menu on macOS
fires an action from a row that opens a submenu. So the default action is its own
top-level row above the submenu rather than the submenu's own title. Both are visible the
moment Services opens, and they sit adjacent because both come from this app.

### 1.2 Info.plist entry

One entry per row. All six share the same send type and none declares a return type —
see §3 for why.

```xml
<key>NSServices</key>
<array>
    <dict>
        <key>NSMenuItem</key>
        <dict><key>default</key><string>Rewrite with Orbit Flow</string></dict>
        <key>NSMessage</key><string>rewriteDefault</string>
        <key>NSPortName</key><string>Orbit Flow</string>
        <key>NSSendTypes</key>
        <array><string>public.utf8-plain-text</string></array>
    </dict>
    <!-- Orbit Flow/Faithful, /Casual, /Professional, /Problem-solver,
         /Open in Orbit Flow — identical but for default and NSMessage -->
</array>
```

### 1.3 Registration

`pbs` caches the Services database. A changed `Info.plist` is not picked up until it is
flushed, and during development that is every build. The `install` target gains one line
after the copy:

```make
@/System/Library/CoreServices/pbs -flush 2>/dev/null || true
```

`~/Applications` is a LaunchServices-scanned location, so no other registration step is
needed. The app is not sandboxed, which Services do not require.

---

## 2. The setting

`CleanupTier` and `cleanupEnabled` are unchanged. The **`AI rewrite` toggle** at
`SettingsWindow.swift:109` becomes a three-way, backed by a new stored setting:

```swift
/// When the cloud rewrite runs — during dictation, only when asked, or not at all.
enum AIRewriteUse: String, CaseIterable, Sendable {
    case off
    case onDemand
    case always

    var displayName: String {
        switch self {
        case .off: "Off"
        case .onDemand: "On demand"
        case .always: "Always"
        }
    }
}
```

| | dictation pastes | right-click rows |
|---|---|---|
| **Off** | rules or on-device, per `cleanupTier` | present but report "AI rewrite is off in Settings" |
| **On demand** | rules or on-device, per `cleanupTier` | active |
| **Always** | AI-rewritten — today's behaviour | active |

`.always` performs exactly the tier dance the current toggle performs: set
`cleanupTier = .cloud`, remembering the previous tier in `tierBeforeCloud`. `.off` and
`.onDemand` both restore `tierBeforeCloud`. Migration: an existing user whose
`cleanupTier` is `.cloud` on first launch of this build lands on `.always`, everyone else
on `.off`.

**Known cost, accepted.** `NSServices` is static — a row cannot be hidden at runtime, so
`Off` and `On demand` produce an identical menu. `Off` differs only in that the rows
refuse with a reason. It is a locked door rather than no door. Kept because naming the
two workflows plainly in Settings is worth more than collapsing to a boolean whose
meaning has to be inferred.

### 2.1 A coupling this breaks

`TranscriptionDetail.isCloudReady` (line 340) currently tests `cleanupTier == .cloud`.
Under **On demand** the tier is not `.cloud`, so the detail page would declare cloud
unavailable on the very page this feature routes text into. The test becomes what it
always meant:

```swift
private var isCloudReady: Bool {
    settings.aiRewriteUse != .off && !settings.aiModel.isEmpty && hasKey
}
```

The menu-bar mode picker at `OrbitFlowApp.swift:215` hides itself on the same stale
condition and gets the same fix — under On demand the mode picker is *more* useful than
before, because it is what the default right-click row reads.

---

## 3. How rewritten text lands

The obvious route is to declare `NSReturnTypes` and hand the rewritten string back for
the system to substitute. **It does not survive a cloud call.** A service provider method
is synchronous on the main thread and the system reads the reply pasteboard the moment it
returns. A 1–5 second round trip means either blocking the main thread or returning
nothing.

So: **send types only, no return type.** The provider method returns immediately, the
rewrite runs as a normal `Task`, and the result is written back through the existing
`TextInjector.insert`.

This works because invoking a service does not activate the providing app. Focus stays
with the source app, the user's selection is still selected, and `TextInjector`'s AX
write to `kAXSelectedTextAttribute` replaces it — falling back to ⌘V for the Electron and
Chrome apps that accept the AX write and silently drop it. That fallback already exists
and is already the hard-won part.

```swift
@MainActor
final class RewriteService: NSObject {
    @objc func rewriteDefault(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        run(pboard, mode: Settings.shared.rewriteMode)
    }
    // rewriteFaithful, rewriteCasual, rewriteProfessional, rewriteProblemSolver
    // each call run(pboard, mode: .x)

    private func run(_ pboard: NSPasteboard, mode: RewriteMode) { … }
}
```

Registered in `applicationDidFinishLaunching`:

```swift
NSApp.servicesProvider = RewriteService()
NSUpdateDynamicServices()
```

### 3.1 Which engine

Cloud when a key and model are saved for the current provider, on-device otherwise, and
if neither is available the row refuses with a reason. One rule, no new setting.

Per-call engine choice lives in **Open in Orbit Flow**, whose page already carries a
cloud/on-device picker. The quick path stays quick; the deliberate path already has every
knob.

### 3.2 Progress

The HUD's `isRewriting` flag already renders "Rewriting…". The service sets it for the
duration, so a 3-second wait is visibly a wait rather than a dead menu click. Because the
HUD is a non-activating panel, showing it does not disturb the source app's focus.

---

## 4. Failure: leave the selection alone

**Dictation and on-demand rewrite fail in opposite directions, on purpose.**

`CloudFormatter` falls back to `RuleBasedFormatter` when the network fails, because an
utterance that was already spoken must never be lost — degraded text beats no text.

The on-demand path must do the reverse. The user's own words are already on screen and
already good enough to have been written. Overwriting a paragraph with a rules-pass of
itself, because a request timed out, is a destructive surprise on text the user did not
ask to have touched.

So the service path calls `CloudRewriter` / `OnDeviceRewriter` **directly, not through
`CloudFormatter`**, and on any failure:

- the selection is left exactly as it was — no write, no paste;
- a user notification states the reason (`RewriteFailure.summary`, which never contains
  the key, or `OnDeviceRewriter.describe`);
- `isRewriting` clears.

`RewriteGuard` rejections count as failures and are treated identically. A guard that
fires means the model returned something unlike the input, and silently pasting it over a
selection is precisely what the guard exists to prevent.

### 4.1 Read-only selections

A selection in a web page or PDF cannot be replaced. `TextInjector`'s AX write fails, the
⌘V fallback does nothing visible, and neither reports this back. Rather than pretend, the
service treats a successful rewrite as: put the result on the pasteboard, attempt the
injection, and notify "Rewritten — copied to clipboard." The user gets the text either
way, and the notification is true in both cases.

This is a departure from dictation's silent injection, and it is only tolerable because
the notification is short and the action was explicitly requested.

---

## 5. Open in Orbit Flow

Files the selection as a run and opens it:

```swift
let run = DictationRun(date: Date(), engine: "Selection",
                       audioSeconds: 0, processSeconds: 0, text: text)
RunLog.record(run)
AppDelegate.showMainWindow()
MainRoute.shared.open(run.id)
```

`RunLog.record` is the same call the "Add text" composer already makes at
`MainWindow.swift:234`; `engine: "Selection"` rather than `"Pasted"` so history says
where it came from.

One piece of plumbing is missing. `TranscriptionList.opened` is private `@State`, so
nothing outside the view can route to a run. It lifts into a tiny observable:

```swift
@MainActor @Observable
final class MainRoute {
    static let shared = MainRoute()
    var openRun: UUID?
    var section: MainWindow.Section = .transcriptions
    func open(_ id: UUID) { section = .transcriptions; openRun = id }
}
```

`TranscriptionList` reads `MainRoute.shared.openRun` instead of its own `@State`, and the
Back button clears it. This is the smallest change that lets both the row tap and the
service reach the same destination; it is not a router and should not grow into one.

Unlike the in-place path, this one *does* activate the app — that is the whole point of
the row.

---

## 6. Files touched

| File | Change |
|---|---|
| `Resources/Info.plist` | `NSServices` array, six entries |
| `Sources/OrbitFlow/Core/RewriteService.swift` | **new** — the provider, ~120 lines |
| `Sources/OrbitFlow/Support/Settings.swift` | `AIRewriteUse`, `aiRewriteUse`, migration |
| `Sources/OrbitFlow/UI/SettingsWindow.swift` | toggle → `Segmented`, notes |
| `Sources/OrbitFlow/UI/TranscriptionDetail.swift` | `isCloudReady` fix |
| `Sources/OrbitFlow/UI/MainWindow.swift` | `MainRoute` replaces private `opened` |
| `Sources/OrbitFlow/OrbitFlowApp.swift` | register provider; mode-picker condition |
| `Sources/OrbitFlow/Core/DictationController.swift` | `activeFormatter` reads the new setting |
| `Makefile` | `pbs -flush` in `install` |

No new dependency. No change to `Sources/OrbitFlowAIRewrite/`.

---

## 7. Testing

**Unit** (`OrbitFlowAIRewriteTests` is pure logic and stays untouched; these are new
tests against the app target's decision functions, extracted as free functions so they
are testable without a running app):

- each `AIRewriteUse` maps to the expected `cleanupTier`, and `tierBeforeCloud` is
  restored rather than collapsing an on-device user to rules;
- `.onDemand` never produces a `CloudFormatter` for dictation;
- migration: `cleanupTier == .cloud` with no stored `aiRewriteUse` yields `.always`;
- the on-demand engine rule: key+model → cloud, no key → on-device, neither → refusal;
- a failed on-demand rewrite yields no replacement text, and a guard rejection is
  classified as a failure rather than a result.

**By hand**, because Services registration and AX injection cannot be unit-tested:

| Case | Expect |
|---|---|
| TextEdit, editable selection | replaced in place via AX |
| Cursor or Slack | replaced via ⌘V fallback |
| Safari, read-only selection | untouched; notification says copied to clipboard |
| Airplane mode, cloud configured | selection untouched; notification names the failure |
| `Off`, any row | selection untouched; notification points at Settings |
| Open in Orbit Flow | app activates on the detail page for the new run |
| Shortcut bound in System Settings ▸ Keyboard ▸ Shortcuts ▸ Services | fires the same path |

---

## 8. Ceilings

Deliberate limits, with the upgrade path if one starts to hurt.

- **One level deep.** Services rows never appear at the top of a context menu; they are
  always under `Services ▸`. Not fixable by any third-party app. The escape hatch is a
  keyboard shortcut bound in System Settings, which is how these get used in practice.
- **Static rows.** `Off` cannot hide the rows (§2).
- **The 1–5s window.** If focus moves during the round trip, the text lands wherever
  focus went. Bounded by the rewriter's timeout; not solvable without capturing input.
  Upgrade path if it bites: capture the focused `AXUIElement` at invocation and refuse to
  write if it is no longer focused.
- **No undo.** The replacement is a paste, so the target app's own ⌘Z covers it. Nothing
  here needs to implement undo, and nothing here should.

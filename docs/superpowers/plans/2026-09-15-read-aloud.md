# Read Aloud Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Highlight text with the mouse in any app and the dictation pill offers ▶; pressing it saves the text to History and reads it aloud with a system voice.

**Architecture:** The existing `CGEventTap` in `HotkeyMonitor` also passes `leftMouseUp` through to a callback. `DictationController` then reads the frontmost app's selection through Accessibility (`SelectedText`), decides whether to offer it with a pure rule that lives in the testable `OrbitFlowHotkey` target, and puts the offer in the existing non-activating pill. A shared `Speaker` wraps `AVSpeechSynthesizer`; the pill, the History detail page and the Settings preview all speak through it, and any speech shows the pill with a ■.

**Tech Stack:** Swift 6.2 (language mode v6, strict concurrency), SwiftUI + AppKit, ApplicationServices (AX), AVFoundation (`AVSpeechSynthesizer`), swift-testing, SwiftPM. macOS 26+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-15-read-aloud-design.md`

## Global Constraints

- **Swift language mode v6** on every target. Anything touching `Settings`, `NSApp`, AX or the UI is `@MainActor`.
- **The app target `OrbitFlow` is an executable and cannot be imported by a test target.** Pure decision logic goes in a library target — for this feature, `OrbitFlowHotkey` — or it cannot be tested.
- **No new package dependencies.** `Package.swift` does not change.
- **Never log selected or spoken text.** Log only that a read was empty or a length, and anything interpolated from a selection uses `privacy: .private`.
- **The clipboard is never touched** by this feature.
- **The feature is off by default:** `readAloudEnabled` defaults to `false`.
- **History entry label is exactly `Read aloud`** (the `engine` field of `DictationRun`).
- **Rename is user-visible strings only.** Type names (`TranscriptionList`, `TranscriptionDetail`, `TranscriptionRow`), the `MainWindow.Section.transcriptions` case and the run log format stay unchanged.
- **Build:** `make build`. **Test:** `make test`. **Install and relaunch:** `make install`. Never run `swift build` / `swift test` directly — the Makefile sets an out-of-tree scratch path and the test framework flags.
- **Bundle identifier / defaults domain:** `ai.pivotstudio.orbitflow`.
- **The working tree may carry the user's uncommitted work** (at planning time: `Makefile`, `README.md`, `Sources/OrbitFlow/UI/SettingsWindow.swift`, untracked `Sources/OrbitFlow/Support/Updater.swift`). Never commit those changes. Stage files by explicit path only; never `git add -A`, `git add .` or `git commit -a`. `git add -p` is interactive and unavailable, so **before Task 4, `git diff --quiet Sources/OrbitFlow/UI/SettingsWindow.swift` must succeed** — if it fails, stop and ask the user to commit or stash their edits to that file.
- **Comment style:** comments explain *why*, often in several sentences, and never restate the code. Match the surrounding files.
- **Commit messages:** a plain imperative sentence, like the existing history ("Add the Services rows, wired to a stub"), ending with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

---

### Task 1: The offer rule, as testable logic

**Files:**
- Create: `Sources/OrbitFlowHotkey/ReadAloudOffer.swift`
- Test: `Tests/OrbitFlowHotkeyTests/ReadAloudOfferTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public func shouldOfferReadAloud(text: String, lastOffered: String?, enabled: Bool, isBusy: Bool) -> Bool` in module `OrbitFlowHotkey`.

- [ ] **Step 1: Write the failing test**

Create `Tests/OrbitFlowHotkeyTests/ReadAloudOfferTests.swift`:

```swift
import Testing
@testable import OrbitFlowHotkey

struct ReadAloudOfferTests {
    @Test("New text is offered, including text that differs from the last offer")
    func offers() {
        #expect(shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: true, isBusy: false))
        #expect(shouldOfferReadAloud(text: "Hello", lastOffered: "Goodbye", enabled: true, isBusy: false))
    }

    @Test("Nothing is offered while the feature is off or the pill is busy")
    func refusesWhenOffOrBusy() {
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: false, isBusy: false))
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: nil, enabled: true, isBusy: true))
    }

    @Test("Blank text is never offered")
    func refusesBlank() {
        #expect(!shouldOfferReadAloud(text: "", lastOffered: nil, enabled: true, isBusy: false))
        #expect(!shouldOfferReadAloud(text: "  \n\t", lastOffered: nil, enabled: true, isBusy: false))
    }

    @Test("The same selection is not offered twice — a click on the pill's own ▶ is a mouse-up too")
    func refusesRepeat() {
        #expect(!shouldOfferReadAloud(text: "Hello", lastOffered: "Hello", enabled: true, isBusy: false))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: build FAILS with `cannot find 'shouldOfferReadAloud' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/OrbitFlowHotkey/ReadAloudOffer.swift`:

```swift
import Foundation

/// Whether a selection just made with the mouse should be offered for reading aloud.
///
/// Lives here rather than in the app because the app target is an executable no test can
/// import, and the repeat check is easy to break without noticing: clicking the pill's own
/// ▶ is itself a mouse-up, made while the selection is still in place, so without it every
/// press would re-offer the text it was pressed to read.
///
/// `isBusy` is anything already using the pill — a dictation, a rewrite in flight, a
/// notice. An offer is the least important thing the pill ever shows, so it never
/// displaces one of those.
public func shouldOfferReadAloud(
    text: String,
    lastOffered: String?,
    enabled: Bool,
    isBusy: Bool
) -> Bool {
    guard enabled, !isBusy else { return false }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return text != lastOffered
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — the four new tests pass, and the total goes from 60 tests in 7 suites to 64 tests in 8 suites.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlowHotkey/ReadAloudOffer.swift Tests/OrbitFlowHotkeyTests/ReadAloudOfferTests.swift
git commit -m "Add the read-aloud offer rule

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Read-aloud settings and the shared `Speaker`

**Files:**
- Modify: `Sources/OrbitFlow/Support/Settings.swift` (imports at top; new properties after `soundEnabled`; new `Keys`; `init` after the `hudSize` line)
- Create: `Sources/OrbitFlow/Core/Speaker.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `Settings.shared.readAloudEnabled: Bool` (default `false`)
  - `Settings.shared.readAloudVoice: String?` (an `AVSpeechSynthesisVoice.identifier`; `nil` = system default)
  - `Settings.shared.readAloudRate: Float` (default `AVSpeechUtteranceDefaultSpeechRate`)
  - `@MainActor @Observable final class Speaker` with `static let shared`, `private(set) var isSpeaking: Bool`, `private(set) var text: String?`, `func speak(_ text: String)`, `func stop()`

There is no unit test for this task: `Settings` and `Speaker` live in the executable target, and `Speaker` is a thin wrapper over a system synthesizer. It is verified by building here and by ear in Tasks 3 to 5.

- [ ] **Step 1: Add the settings**

In `Sources/OrbitFlow/Support/Settings.swift`, add to the imports at the top of the file:

```swift
import AVFoundation
```

Directly after the `soundEnabled` property, add:

```swift
    /// Offer to read highlighted text aloud from the pill.
    ///
    /// Off by default: with it on, the pill appears every time a selection is made with the
    /// mouse in any app, which is only welcome if you asked for it.
    var readAloudEnabled: Bool {
        didSet { defaults.set(readAloudEnabled, forKey: Keys.readAloudEnabled) }
    }

    /// An `AVSpeechSynthesisVoice` identifier. Nil means the system default voice — and so
    /// does an identifier whose voice has since been uninstalled, because
    /// `AVSpeechSynthesisVoice(identifier:)` returns nil for it and the utterance falls back.
    var readAloudVoice: String? {
        didSet { defaults.set(readAloudVoice, forKey: Keys.readAloudVoice) }
    }

    /// `AVSpeechUtterance.rate`, where `AVSpeechUtteranceDefaultSpeechRate` is normal speed.
    var readAloudRate: Float {
        didSet { defaults.set(readAloudRate, forKey: Keys.readAloudRate) }
    }
```

In `private enum Keys`, after `static let hudSize = "hudSize"`, add:

```swift
        static let readAloudEnabled = "readAloudEnabled"
        static let readAloudVoice = "readAloudVoice"
        static let readAloudRate = "readAloudRate"
```

In `private init()`, directly after the line `hudSize = HUDSize(rawValue: defaults.string(forKey: Keys.hudSize) ?? "") ?? .full`, add:

```swift
        readAloudEnabled = defaults.object(forKey: Keys.readAloudEnabled) as? Bool ?? false
        readAloudVoice = defaults.string(forKey: Keys.readAloudVoice)
        // Through NSNumber, not `as? Float`: UserDefaults hands a stored number back as
        // NSNumber, and bridging that straight to Float fails for any value it can't
        // represent exactly — which would silently reset the speed on every launch.
        readAloudRate = (defaults.object(forKey: Keys.readAloudRate) as? NSNumber)?.floatValue
            ?? AVSpeechUtteranceDefaultSpeechRate
```

- [ ] **Step 2: Create `Speaker`**

Create `Sources/OrbitFlow/Core/Speaker.swift`:

```swift
import AVFoundation
import Observation

/// Reads text aloud with a system voice.
///
/// One shared instance, because there is one speaker on the Mac: the pill, the History
/// detail page and the Settings preview all speak through this, so starting any of them
/// stops whatever else was talking, and a single ■ anywhere stops it all.
///
/// Voice and speed are read from `Settings` at the moment `speak` is called, so a change in
/// Settings applies to the next thing read without anything having to observe it.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private(set) var isSpeaking = false
    /// What is being spoken, so the pill can show it next to the ■.
    private(set) var text: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        let settings = Settings.shared
        utterance.voice = settings.readAloudVoice.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        utterance.rate = settings.readAloudRate

        self.text = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        text = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // Both callbacks ask the synthesizer rather than trusting which utterance ended.
    // `speak` cancels the previous utterance before queueing the next, and that cancel is
    // delivered *after* the new one is already queued — so reacting to it would mark the
    // new speech as finished the moment it started. `isSpeaking` on the synthesizer counts
    // queued utterances, so it is only false when nothing at all is left to say.

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.settle() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.settle() }
    }

    private func settle() {
        guard !synthesizer.isSpeaking else { return }
        text = nil
        isSpeaking = false
    }
}
```

- [ ] **Step 3: Build**

Run: `make build`
Expected: `Build complete!` with no new warnings from `Speaker.swift` or `Settings.swift`.

If Swift 6 rejects capturing `self` in the `nonisolated` callbacks' `Task`, it is because `Speaker` did not get inferred as `Sendable`; it should be, since it is `@MainActor`. Do not silence it with `nonisolated(unsafe)` — report the exact diagnostic.

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS, 64 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlow/Support/Settings.swift Sources/OrbitFlow/Core/Speaker.swift
git commit -m "Add read-aloud settings and the shared Speaker

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The pill offers highlighted text and reads it

**Files:**
- Create: `Sources/OrbitFlow/Core/SelectedText.swift`
- Modify: `Sources/OrbitFlow/Core/HotkeyMonitor.swift` (new `onMouseUp` property; tap mask in `start()`; new `case` in `handle`)
- Modify: `Sources/OrbitFlow/Core/DictationController.swift` (new state after `notice`; `needsFullHUD`; `activate()`; `flash`; `setRewriting`; `beginDictation`; new "Read aloud" section)
- Modify: `Sources/OrbitFlow/UI/Components.swift:385-414` (`HUDButton`)
- Modify: `Sources/OrbitFlow/UI/HUDView.swift` (body split into dictation and read-aloud controls)
- Modify: `Sources/OrbitFlow/OrbitFlowApp.swift` (`observeState()`)

**Interfaces:**
- Consumes: `shouldOfferReadAloud(text:lastOffered:enabled:isBusy:)` (Task 1); `Settings.shared.readAloudEnabled`, `Speaker.shared.speak(_:)`, `.stop()`, `.isSpeaking`, `.text` (Task 2).
- Produces:
  - `@MainActor enum SelectedText { static func read() -> String? }`
  - `HotkeyMonitor.onMouseUp: (() -> Void)?`
  - `DictationController.readAloudOffer: String?` (read-only), `DictationController.isReadAloudShowing: Bool`, `func readAloud()`, `func stopReadingAloud()`
  - `HUDButton.Kind` gains `.play` and `.stop`; `HUDButton` gains `var help: String? = nil`

- [ ] **Step 1: Create `SelectedText`**

Create `Sources/OrbitFlow/Core/SelectedText.swift`:

```swift
import AppKit
import ApplicationServices

/// Reads what is highlighted in the frontmost app, through Accessibility.
///
/// This runs on every mouse-up while read aloud is on, on the main thread, so it is built
/// to be cheap and to fail quietly. It asks the frontmost *application* element rather
/// than the system-wide one because the messaging timeout has to be short — a hung app
/// must not stall Orbit Flow for AX's default six seconds on each click — and a timeout set
/// on the system-wide element is global to the whole process, which would also shorten
/// the calls `TextInjector` depends on.
///
/// Apps that don't expose their selection (some browsers, Electron apps, terminals) just
/// return nil, and the pill doesn't appear. There is no ⌘C fallback: it cannot run on
/// every mouse-up without clobbering the clipboard.
@MainActor
enum SelectedText {
    static func read() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              // Orbit Flow's own windows already show their text, and offering it would file
              // a History entry to read a History entry.
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Checked before the value is ever asked for, so a password is never read into
        // this process at all — not merely not offered.
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == kAXSecureTextFieldSubrole {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let text = value as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 2: Pass mouse-ups through the tap**

In `Sources/OrbitFlow/Core/HotkeyMonitor.swift`, directly after the `onChord` property, add:

```swift
    /// The left mouse button came up anywhere on the system — which is when a selection
    /// made by dragging or double-clicking is finished. Always passed through untouched,
    /// and nothing about the click is read here: the tap is disabled by macOS if it runs
    /// slowly, so the selection is looked up afterwards, by the caller.
    var onMouseUp: (() -> Void)?
```

In `start()`, replace the comment and mask:

```swift
        // `keyDown`/`keyUp` are here for key-combination shortcuts, chord detection and
        // Escape. The tap is handed every key on the system, so `handle` compares the key
        // code against the shortcuts and Escape and nothing else — no key is stored or logged.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
```

with:

```swift
        // `keyDown`/`keyUp` are here for key-combination shortcuts, chord detection and
        // Escape. The tap is handed every key on the system, so `handle` compares the key
        // code against the shortcuts and Escape and nothing else — no key is stored or logged.
        // `leftMouseUp` is here for read aloud, and is only ever forwarded.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
```

In `handle(type:keyCode:flags:isRepeat:)`, add a case directly before `default:`:

```swift
        case .leftMouseUp:
            onMouseUp?()
            return false

```

- [ ] **Step 3: Add read-aloud state to `DictationController`**

In `Sources/OrbitFlow/Core/DictationController.swift`, directly after the `notice` property, add:

```swift
    /// Highlighted text the pill is offering to read aloud, or nil.
    ///
    /// Cleared the moment ▶ is pressed: from then on the pill shows `Speaker.shared.text`,
    /// which is what is actually being spoken. Keeping the two apart is what lets a new
    /// highlight be offered while the previous one is still being read.
    private(set) var readAloudOffer: String?

    /// Whether the pill is in read-aloud mode: something offered, or something being read —
    /// from the pill, the History page, or the Settings preview.
    var isReadAloudShowing: Bool {
        readAloudOffer != nil || Speaker.shared.isSpeaking
    }
```

Replace `needsFullHUD`'s body:

```swift
    var needsFullHUD: Bool {
        if notice != nil { return true }
        if case .idle = state, isRewriting { return true }
        return false
    }
```

with:

```swift
    var needsFullHUD: Bool {
        if notice != nil { return true }
        if case .idle = state, isRewriting { return true }
        // An offer is only useful if you can see what it's offering, and Compact has no
        // room for a word of it.
        if isReadAloudShowing { return true }
        return false
    }
```

Directly after `private var noticeToken = UUID()`, add:

```swift
    /// The last selection offered, so the pill's own ▶ — a mouse-up made while the
    /// selection is still there — doesn't re-offer it. Cleared by a mouse-up that finds no
    /// selection, so deselecting and re-selecting the same passage offers it again.
    private var lastOfferedSelection: String?

    /// Identifies the offer on screen, for the same reason `noticeToken` exists: an old
    /// offer's fade timer must not clear a newer one.
    private var offerToken = UUID()
```

In `activate()`, replace:

```swift
        hotkey.onEscape = { [weak self] in
            guard let self, self.state.isActive else { return false }
            self.discard()
            return true
        }
```

with:

```swift
        hotkey.onMouseUp = { [weak self] in self?.mouseReleased() }
        // Escape is also the keyboard ✕ for read aloud. Still swallowed only when there is
        // something of ours to cancel.
        hotkey.onEscape = { [weak self] in
            guard let self else { return false }
            if self.state.isActive {
                self.discard()
                return true
            }
            if self.isReadAloudShowing {
                self.stopReadingAloud()
                return true
            }
            return false
        }
```

Replace `flash(_:)`'s first line:

```swift
    func flash(_ message: String) {
        notice = message
```

with:

```swift
    func flash(_ message: String) {
        // A notice is feedback for something the user just did; an offer is a guess about
        // what they might want. The notice wins.
        readAloudOffer = nil
        notice = message
```

Replace `setRewriting(_:)`'s body:

```swift
    func setRewriting(_ running: Bool) {
        if running { notice = nil }
        isRewriting = running
    }
```

with:

```swift
    func setRewriting(_ running: Bool) {
        if running {
            notice = nil
            readAloudOffer = nil
        }
        isRewriting = running
    }
```

In `beginDictation()`, directly after `guard case .idle = state else { return }`, add:

```swift
        // Before the microphone opens, or it transcribes the voice reading aloud.
        stopReadingAloud()
```

Directly before `// MARK: - Dictation`, add a new section:

```swift
    // MARK: - Read aloud

    /// ▶ on the pill: file the offered text in History, then read it.
    ///
    /// Filed only here, never on highlight. Selecting text is constant — to delete it, drag
    /// it, copy an address — and History should hold what the user chose to hear.
    func readAloud() {
        guard let text = readAloudOffer else { return }
        offerToken = UUID()
        readAloudOffer = nil
        RunLog.record(
            DictationRun(
                date: Date(),
                engine: "Read aloud",
                audioSeconds: 0,
                processSeconds: 0,
                text: text
            )
        )
        Speaker.shared.speak(text)
    }

    /// ✕, ■ and Escape: stop speaking and drop any offer.
    func stopReadingAloud() {
        offerToken = UUID()
        readAloudOffer = nil
        Speaker.shared.stop()
    }

    private func mouseReleased() {
        guard Settings.shared.readAloudEnabled else { return }
        Task { @MainActor in
            // The tap sees the mouse-up before the app under the cursor has handled it, so
            // the selection isn't final yet at this instant.
            try? await Task.sleep(for: .milliseconds(50))

            guard let text = SelectedText.read() else {
                lastOfferedSelection = nil
                return
            }
            guard shouldOfferReadAloud(
                text: text,
                lastOffered: lastOfferedSelection,
                enabled: Settings.shared.readAloudEnabled,
                isBusy: state.isActive || isRewriting || notice != nil
            ) else { return }

            offerReadAloud(text)
        }
    }

    /// Shows ▶ for `text`, fading after four seconds if it isn't pressed.
    private func offerReadAloud(_ text: String) {
        lastOfferedSelection = text
        readAloudOffer = text
        offerToken = UUID()
        let token = offerToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if offerToken == token { readAloudOffer = nil }
        }
    }

```

- [ ] **Step 4: Add ▶ and ■ to `HUDButton`**

In `Sources/OrbitFlow/UI/Components.swift`, replace the whole `HUDButton` struct (currently lines 385–414) with:

```swift
struct HUDButton: View {
    enum Kind { case discard, confirm, play, stop }

    let kind: Kind
    let size: CGFloat
    /// Overrides the tooltip, for a kind reused with a different meaning — the read-aloud
    /// pill's ✕ doesn't discard a recording.
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    /// The one button on the pill that moves things forward gets the accent disc.
    private var isPrimary: Bool { kind == .confirm || kind == .play }

    private var glyph: String {
        switch kind {
        case .discard: "xmark"
        case .confirm: "checkmark"
        case .play: "play.fill"
        case .stop: "stop.fill"
        }
    }

    private var defaultHelp: String {
        switch kind {
        case .discard: "Discard this recording"
        case .confirm: "Stop and paste"
        case .play: "Read aloud"
        case .stop: "Stop reading"
        }
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isPrimary ? DS.Color.hudConfirm : DS.Color.hudControl)
                .overlay {
                    Image(systemName: glyph)
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(
                            isPrimary ? DS.Color.hudGlyphOnConfirm : DS.Color.inkOnHUD
                        )
                }
                .frame(width: size, height: size)
                .brightness(isHovering ? 0.08 : 0)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(DS.Motion.press, value: isHovering)
        .help(help ?? defaultHelp)
    }
}
```

- [ ] **Step 5: Give `HUDView` a read-aloud mode**

In `Sources/OrbitFlow/UI/HUDView.swift`, add a property directly after `@State private var settings = Settings.shared`:

```swift
    @State private var speaker = Speaker.shared
```

Replace the `HStack` at the top of `body` — from `HStack(spacing: DS.Space.snug) {` down to and including its closing `}` just before `.padding(.horizontal, DS.Space.tight)` — with:

```swift
        HStack(spacing: DS.Space.snug) {
            if isReadingAloud { readAloudControls } else { dictationControls }
        }
```

Leave every modifier after it (`.padding`, `.frame`, `.background`, the outer `.padding`) unchanged.

Directly after the end of `body`, add:

```swift
    @ViewBuilder
    private var dictationControls: some View {
        HUDButton(kind: .discard, size: hud.controlSize) { controller.discard() }

        Waveform(
            level: controller.level,
            isActive: isListening,
            color: isError ? DS.Color.caution : DS.Color.inkOnHUD
        )
        .frame(width: hud.waveWidth)

        if hud == .full {
            Text(label)
                .font(hasTranscript ? DS.Font.prose : DS.Font.body)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(DS.Motion.press, value: controller.transcript)
        }

        HUDButton(kind: .confirm, size: hud.controlSize) { controller.stopAndInsert() }
    }

    /// ✕, the text, and ▶ for an offer or ■ while reading. No waveform: there's no
    /// microphone level to draw, and a flat trace next to a voice reads as broken.
    @ViewBuilder
    private var readAloudControls: some View {
        HUDButton(kind: .discard, size: hud.controlSize, help: "Stop and dismiss") {
            controller.stopReadingAloud()
        }

        // Tail-truncated, unlike the transcript: what matters here is where the passage
        // starts, so you can tell which one you highlighted.
        Text(controller.readAloudOffer ?? speaker.text ?? "")
            .font(DS.Font.prose)
            .foregroundStyle(DS.Color.inkOnHUD)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

        if controller.readAloudOffer != nil {
            HUDButton(kind: .play, size: hud.controlSize) { controller.readAloud() }
        } else {
            HUDButton(kind: .stop, size: hud.controlSize) { controller.stopReadingAloud() }
        }
    }

    /// Anything the pill already had a job for takes precedence over reading aloud.
    private var isReadingAloud: Bool {
        !isListening && controller.notice == nil && !controller.isRewriting
            && controller.isReadAloudShowing
    }
```

- [ ] **Step 6: Show the pill for read aloud**

In `Sources/OrbitFlow/OrbitFlowApp.swift`, replace `observeState()`:

```swift
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.notice
            _ = controller.isRewriting
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The pill is up for a live dictation, for an on-demand rewrite in flight,
                // and for the three seconds a notice is on screen.
                let wanted = self.controller.state.isActive
                    || self.controller.notice != nil
                    || self.controller.isRewriting
                if wanted { self.hud?.present() } else { self.hud?.dismiss() }
                self.observeState()
            }
        }
    }
```

with:

```swift
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.notice
            _ = controller.isRewriting
            _ = controller.readAloudOffer
            _ = Speaker.shared.isSpeaking
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The pill is up for a live dictation, for an on-demand rewrite in flight,
                // for the three seconds a notice is on screen, and for as long as there is
                // something to offer or something being read — from anywhere, so there is
                // always one place to stop the voice.
                let wanted = self.controller.state.isActive
                    || self.controller.notice != nil
                    || self.controller.isRewriting
                    || self.controller.isReadAloudShowing
                if wanted { self.hud?.present() } else { self.hud?.dismiss() }
                self.observeState()
            }
        }
    }
```

- [ ] **Step 7: Build and test**

Run: `make build`
Expected: `Build complete!`

Run: `make test`
Expected: PASS, 64 tests.

- [ ] **Step 8: Try it live**

The Settings toggle arrives in Task 4, so switch the feature on from the command line. `make install` quits and relaunches the app, and `Settings` reads defaults at launch:

```bash
defaults write ai.pivotstudio.orbitflow readAloudEnabled -bool true
make install
```

Check, and write down anything that fails:
1. In Notes, drag-select a sentence → the pill appears bottom-center with the start of the sentence and ▶.
2. Do nothing → it fades after about 4 seconds.
3. Select again, press ▶ → it reads aloud, the button becomes ■, and the pill does not flicker back to ▶.
4. Press ■ mid-sentence → speech stops and the pill fades.
5. Select, ▶, then press Esc → speech stops. With nothing showing, Esc in a Notes dialog still reaches Notes.
6. Select, ▶, then press the talk key → speech stops before dictation starts.
7. Click in a text field with no selection → no pill.
8. Open Orbit Flow's main window → the newest History row is `Read aloud` with the sentence.

- [ ] **Step 9: Commit**

```bash
git add Sources/OrbitFlow/Core/SelectedText.swift Sources/OrbitFlow/Core/HotkeyMonitor.swift \
  Sources/OrbitFlow/Core/DictationController.swift Sources/OrbitFlow/UI/Components.swift \
  Sources/OrbitFlow/UI/HUDView.swift Sources/OrbitFlow/OrbitFlowApp.swift
git commit -m "Offer highlighted text in the pill and read it aloud

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The Read aloud group in Settings

**Files:**
- Modify: `Sources/OrbitFlow/Support/Permissions.swift` (new function after `openMicrophoneSettings`)
- Modify: `Sources/OrbitFlow/UI/SettingsWindow.swift` (import; one new `@State`; the group placed after `group("Dictation pill")`; two new private members next to `accessibilityNotice`)

**Interfaces:**
- Consumes: `Settings.shared.readAloudEnabled`, `.readAloudVoice`, `.readAloudRate`, `Speaker.shared` (Task 2); `DictationController.stopReadingAloud()`, `controller.isHotkeyArmed` (Task 3 / existing).
- Produces: `Permissions.openSpokenContentSettings()`.

- [ ] **Step 0: Confirm `SettingsWindow.swift` has no uncommitted edits**

Run: `git diff --quiet Sources/OrbitFlow/UI/SettingsWindow.swift && echo clean`
Expected: `clean`. If nothing prints, stop and ask the user to commit or stash their changes to that file — this task's commit must not carry them.

- [ ] **Step 1: Add the Spoken Content deep link**

In `Sources/OrbitFlow/Support/Permissions.swift`, after `openMicrophoneSettings()`, add:

```swift
    /// Where system voices are downloaded. Apps cannot download voices themselves, so this
    /// pane is the only way to get the Premium and Enhanced ones.
    static func openSpokenContentSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems")!
        NSWorkspace.shared.open(url)
    }
```

- [ ] **Step 2: Add the group**

In `Sources/OrbitFlow/UI/SettingsWindow.swift`, add to the imports at the top:

```swift
import AVFoundation
```

In `SettingsPanel`, directly after `@State private var settings = Settings.shared`, add:

```swift
    @State private var speaker = Speaker.shared
```

In `body`, directly after the closing `}` of `group("Dictation pill") { ... }`, add:

```swift
                readAloudGroup
```

Directly before `/// Shown when the event tap isn't live.` (the doc comment on `accessibilityNotice`), add:

```swift
    private var readAloudGroup: some View {
        group("Read aloud") {
            // Highlight detection rides on the same event tap as the hotkey, so it is dead
            // for exactly the same reason.
            if !controller.isHotkeyArmed { accessibilityNotice }

            Toggle(isOn: $settings.readAloudEnabled) {
                Text("Offer to read highlighted text")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
            }
            .toggleStyle(.switch)
            note("Highlight text with the mouse in any app and the pill offers ▶. Whatever you "
                + "play is saved to History. Works in apps that share their selection with "
                + "macOS — most native apps; some browsers and Electron apps don't.")

            Hairline()

            FieldLabel(text: "Voice", color: DS.Color.ink, emphasis: true)
            let voices = readAloudVoices
            Picker("", selection: Binding(
                // A saved voice that has since been uninstalled has no row to select, and
                // a picker with no selection shows blank. It already speaks as the system
                // default, so say so.
                get: { settings.readAloudVoice.flatMap { id in voices.contains { $0.identifier == id } ? id : nil } },
                set: { settings.readAloudVoice = $0 }
            )) {
                Text("System default").tag(String?.none)
                ForEach(voices, id: \.identifier) { voice in
                    Text(voiceLabel(voice)).tag(String?.some(voice.identifier))
                }
            }
            .labelsHidden()
            note("Premium and Enhanced voices sound far more natural. Download them in System "
                + "Settings ▸ Accessibility ▸ Spoken Content ▸ System voice ▸ Manage Voices.")
            ActionButton(title: "Open Spoken Content settings", kind: .quiet) {
                Permissions.openSpokenContentSettings()
            }

            Hairline()

            FieldLabel(text: "Speed", color: DS.Color.ink, emphasis: true)
            HStack(spacing: DS.Space.base) {
                // Narrower than AVSpeech's full 0…1: the ends of that range are too slow
                // and too fast to follow, and a slider mostly made of unusable positions is
                // hard to set.
                // ponytail: fixed range, widen it if someone asks for faster listening.
                Slider(value: $settings.readAloudRate, in: 0.3...0.75)
                ActionButton(title: speaker.isSpeaking ? "Stop" : "Preview", kind: .secondary) {
                    if speaker.isSpeaking {
                        speaker.stop()
                    } else {
                        speaker.speak("This is how highlighted text will sound.")
                    }
                }
            }
        }
        .onChange(of: settings.readAloudEnabled) { _, isOn in
            if !isOn { controller.stopReadingAloud() }
        }
    }

    /// Voices for the user's language, best first. Novelty voices (Bells, Bubbles…) are
    /// left out, and so are Personal Voices, which need a separate authorization prompt.
    /// Computed on each redraw rather than cached, so a voice downloaded in System Settings
    /// shows up when you come back.
    private var readAloudVoices: [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.hasPrefix(language)
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted {
                $0.quality.rawValue != $1.quality.rawValue
                    ? $0.quality.rawValue > $1.quality.rawValue
                    : $0.name < $1.name
            }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "\(voice.name) (Premium)"
        case .enhanced: "\(voice.name) (Enhanced)"
        default: voice.name
        }
    }

```

- [ ] **Step 3: Build and test**

Run: `make build`
Expected: `Build complete!`

Run: `make test`
Expected: PASS, 64 tests.

- [ ] **Step 4: Try it live**

```bash
defaults delete ai.pivotstudio.orbitflow readAloudEnabled
make install
```

Open Settings and check:
1. "Read aloud" comes after "Dictation pill", with the toggle **off**.
2. Highlighting in Notes offers nothing. Turn the toggle on → highlighting offers ▶ with no relaunch.
3. The voice picker lists "System default" first, then voices for your language, Premium/Enhanced first, with no Bells or Bubbles.
4. Pick a voice and press Preview → the sample plays in that voice, the pill shows it with ■, and the button reads "Stop" while it plays.
5. Move the speed slider, Preview again → the speed audibly changes.
6. "Open Spoken Content settings" opens System Settings on Accessibility ▸ Spoken Content. **If it opens a different pane**, change the URL to `x-apple.systempreferences:com.apple.preference.universalaccess` (the Accessibility root), since a wrong deep link is worse than a general one, and re-check.
7. Start a Preview, then turn the toggle off → speech stops.
8. Quit and relaunch (`make install`) → the toggle, voice and speed are remembered.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlow/Support/Permissions.swift Sources/OrbitFlow/UI/SettingsWindow.swift
git diff --cached --stat   # confirm: exactly these two files
git commit -m "Add the Read aloud group to Settings

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Rename Transcriptions to History, and replay from the detail page

**Files:**
- Modify: `Sources/OrbitFlow/UI/MainWindow.swift:29` and `:186`
- Modify: `Sources/OrbitFlow/UI/TranscriptionDetail.swift` (new `@State`; `header`)

**Interfaces:**
- Consumes: `Speaker.shared.speak(_:)`, `.stop()`, `.isSpeaking` (Task 2); the existing `current: Version?`, `source: String`, and `String.trimmed` in `TranscriptionDetail.swift`.
- Produces: nothing new.

- [ ] **Step 1: Rename the visible strings**

In `Sources/OrbitFlow/UI/MainWindow.swift`, replace:

```swift
            case .transcriptions: "Transcriptions"
```

with:

```swift
            case .transcriptions: "History"
```

and replace:

```swift
                    SearchField(text: $query, placeholder: "Search transcriptions")
```

with:

```swift
                    SearchField(text: $query, placeholder: "Search history")
```

- [ ] **Step 2: Rename the back button and add replay**

In `Sources/OrbitFlow/UI/TranscriptionDetail.swift`, directly after `@State private var settings = Settings.shared`, add:

```swift
    @State private var speaker = Speaker.shared
```

Replace `header`:

```swift
    private var header: some View {
        HStack(spacing: DS.Space.snug) {
            ActionButton(title: "Transcriptions", systemImage: "chevron.left", kind: .quiet, action: onBack)
            Spacer()
            if let run {
                Text("\(run.engine) · \(run.date.formatted(.dateTime.month().day().hour().minute()))")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            }
        }
```

with:

```swift
    private var header: some View {
        HStack(spacing: DS.Space.snug) {
            ActionButton(title: "History", systemImage: "chevron.left", kind: .quiet, action: onBack)
            Spacer()
            if let run {
                // Reads whatever the page is showing: the selected rewrite if there is one,
                // otherwise the text on the left. Replaying doesn't file a new entry — this
                // one is already in History.
                let spoken = current?.text ?? source
                ActionButton(
                    title: speaker.isSpeaking ? "Stop" : "Read aloud",
                    systemImage: speaker.isSpeaking ? "stop.fill" : "play.fill",
                    kind: .quiet,
                    isEnabled: speaker.isSpeaking || !spoken.trimmed.isEmpty
                ) {
                    if speaker.isSpeaking {
                        speaker.stop()
                    } else {
                        speaker.speak(spoken)
                    }
                }
                Text("\(run.engine) · \(run.date.formatted(.dateTime.month().day().hour().minute()))")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            }
        }
```

Leave the modifiers after the `HStack` unchanged.

- [ ] **Step 3: Build and test**

Run: `make build`
Expected: `Build complete!`

Run: `make test`
Expected: PASS, 64 tests.

- [ ] **Step 4: Try it live**

```bash
make install
```

Check:
1. The sidebar tab reads "History", the search field says "Search history", and existing entries are all still listed.
2. Open any entry → the back button reads "History". Press "Read aloud" → it speaks the text, the button becomes "Stop", and the pill shows the text with ■.
3. Press "Stop" → speech stops. The History row count has not changed.
4. On an entry with rewrites, select a rewrite → "Read aloud" speaks that rewrite, not the original.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlow/UI/MainWindow.swift Sources/OrbitFlow/UI/TranscriptionDetail.swift
git commit -m "Rename Transcriptions to History and add replay to the detail page

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Run the verification matrix and close out the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-09-15-read-aloud-design.md` (status line; §6 results; Settings note if app results require it)
- Possibly modify: `Sources/OrbitFlow/UI/SettingsWindow.swift` (only the read-aloud note text, only if step 2 shows it is inaccurate)

**Interfaces:**
- Consumes: everything above.
- Produces: a spec marked implemented, with recorded results.

- [ ] **Step 1: Install a clean build**

```bash
make test
make install
```

Expected: 64 tests pass, the app relaunches, and read aloud is on in Settings.

- [ ] **Step 2: Run every row of the spec's §6 matrix**

Work through each row of the table in `docs/superpowers/specs/2026-09-15-read-aloud-design.md` §6 (rows 1–17, including 4a). For row 2 (Chrome, Slack, VS Code, Terminal) record what actually happens in each app: offered, or nothing. For row 9, dictate a short phrase after pressing the talk key mid-speech and confirm the pasted text contains none of the spoken passage. For row 15, choose a voice, remove it in System Settings ▸ Accessibility ▸ Spoken Content ▸ Manage Voices, then confirm the picker shows "System default" and ▶ still speaks. For row 17, copy a known word, highlight and ▶ something else, then paste: the known word must come out.

- [ ] **Step 3: Fix what fails**

Any row that fails is a bug in Tasks 1–5: fix it in the file that task owns, re-run `make test` and the failing row, and commit the fix separately with a message naming the row (e.g. "Fix read aloud re-offering after ▶ (matrix row 5)").

If row 2 shows the Settings note is wrong — for example Chrome does offer — correct only the note's wording in `readAloudGroup` and commit that file by path.

- [ ] **Step 4: Record results in the spec**

In the spec, change `**Status:** designed, not implemented.` to `**Status:** implemented.` Under §6, add a `**Results (2026-09-15):**` paragraph listing the row 2 outcome for each of Chrome, Slack, VS Code and Terminal, plus any other row that needed a fix and what the fix was.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-09-15-read-aloud-design.md
git commit -m "Record read aloud's verification results

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

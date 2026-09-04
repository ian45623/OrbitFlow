# On-demand AI Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user rewrite text on demand — by selecting it in any app and right-clicking — instead of every dictation being rewritten automatically.

**Architecture:** A static `NSServices` array in `Info.plist` plus a `servicesProvider` object registered on `NSApp` gives macOS six menu rows that hand us the user's selection on a pasteboard. The rewrite runs asynchronously and the result is written back through the existing `TextInjector`, because a service provider method is synchronous and cannot wait on a cloud round trip. A new three-way `AIRewriteUse` setting (`off` / `onDemand` / `always`) becomes the single owner of "does the cloud see my text", replacing the `AI rewrite` toggle and the `CleanupTier.cloud` case it drove.

**Tech Stack:** Swift 6.2 (language mode v6, strict concurrency), SwiftUI + AppKit, swift-testing, SwiftPM. macOS 26+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-on-demand-rewrite-design.md`

## Global Constraints

- **Swift language mode v6** on every target. New types crossing a concurrency boundary must be `Sendable`; anything touching `Settings`, `NSApp`, or the UI is `@MainActor`.
- **The app target `OrbitFlow` is an executable and cannot be imported by a test target.** This is stated in `Package.swift` and is why `RewriteMode` and `AIProvider` live in `OrbitFlowAIRewrite`. **All new pure decision logic goes in `OrbitFlowAIRewrite`, never in the app target**, or it cannot be tested.
- **No new package dependencies.** Nothing in `Package.swift` changes.
- **The API key never appears in a log line, an error string, or a `RewriteFailure`.** `RewriteFailure.summary` is safe to log; raw errors are not.
- **Bundle identifier is `ai.pivotstudio.orbitflow`** and `NSPortName` in every service entry is `Orbit Flow` (with the space — it must match `CFBundleName`).
- **Build:** `make app`. **Test:** `make test`. **Install and run:** `make install`. Never run `swift build` directly — the Makefile sets a scratch path outside the repo for a documented reason.
- **Comment style:** this codebase writes comments that explain *why*, often several sentences, and never restates what the code says. Match it. Do not add comments that narrate the obvious.

---

### Task 1: `AIRewriteUse` — the three-way setting, as testable logic

**Files:**
- Create: `Sources/OrbitFlowAIRewrite/AIRewriteUse.swift`
- Test: `Tests/OrbitFlowAIRewriteTests/AIRewriteUseTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum AIRewriteUse: String, CaseIterable, Sendable` with cases `off`, `onDemand`, `always`
  - `public var displayName: String`
  - `public var summary: String`
  - `public var rewritesDictation: Bool`
  - `public var servesOnDemand: Bool`
  - `public static func resolve(stored: String?, legacyTierWasCloud: Bool) -> AIRewriteUse`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrbitFlowAIRewriteTests/AIRewriteUseTests.swift`:

```swift
import Testing

@testable import OrbitFlowAIRewrite

struct AIRewriteUseTests {
    /// The whole point of the type: exactly one state sends dictation to the cloud.
    /// Getting this backwards would either leak every utterance or silently disable
    /// the feature for users who paid for a key.
    @Test("Only .always rewrites dictation")
    func rewritesDictation() {
        #expect(AIRewriteUse.always.rewritesDictation)
        #expect(!AIRewriteUse.onDemand.rewritesDictation)
        #expect(!AIRewriteUse.off.rewritesDictation)
    }

    @Test("Only .off refuses the on-demand rows")
    func servesOnDemand() {
        #expect(AIRewriteUse.always.servesOnDemand)
        #expect(AIRewriteUse.onDemand.servesOnDemand)
        #expect(!AIRewriteUse.off.servesOnDemand)
    }

    /// A user of the previous build expressed "rewrite everything" as cleanupTier ==
    /// .cloud. Landing them anywhere but .always would silently turn off a feature
    /// they had switched on.
    @Test("A legacy cloud tier migrates to .always")
    func migratesFromCloudTier() {
        #expect(AIRewriteUse.resolve(stored: nil, legacyTierWasCloud: true) == .always)
    }

    @Test("Everyone else starts off")
    func migratesToOff() {
        #expect(AIRewriteUse.resolve(stored: nil, legacyTierWasCloud: false) == .off)
    }

    /// The migration must run once. Once a real choice is stored it wins outright,
    /// or a user who picked On demand would be dragged back to Always every launch
    /// for as long as the legacy tier value sat in defaults.
    @Test("A stored choice beats the legacy tier")
    func storedWins() {
        #expect(AIRewriteUse.resolve(stored: "onDemand", legacyTierWasCloud: true) == .onDemand)
        #expect(AIRewriteUse.resolve(stored: "off", legacyTierWasCloud: true) == .off)
        #expect(AIRewriteUse.resolve(stored: "always", legacyTierWasCloud: false) == .always)
    }

    /// Defaults can hold anything — a value written by a future build, or garbage.
    /// Falling through to the migration beats crashing or forcing .off.
    @Test("An unreadable stored value falls back to the migration")
    func garbageStoredValue() {
        #expect(AIRewriteUse.resolve(stored: "banana", legacyTierWasCloud: true) == .always)
        #expect(AIRewriteUse.resolve(stored: "", legacyTierWasCloud: false) == .off)
    }

    @Test("Labels are present and distinct")
    func labels() {
        let names = AIRewriteUse.allCases.map(\.displayName)
        #expect(Set(names).count == AIRewriteUse.allCases.count)
        #expect(AIRewriteUse.allCases.allSatisfy { !$0.summary.isEmpty })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'AIRewriteUse' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/OrbitFlowAIRewrite/AIRewriteUse.swift`:

```swift
import Foundation

/// When the AI rewrite runs.
///
/// Splits two things the old `AI rewrite` toggle fused: whether a rewrite is *configured*
/// and *when* it fires. `onDemand` is the case that earns this type — a fully configured
/// rewrite that dictation deliberately does not use, reached from the Services menu
/// instead.
///
/// This is the single owner of "does my text leave this Mac during dictation".
/// `CleanupTier` no longer expresses that; it chooses between the two local passes and
/// nothing else. Two properties expressing one decision is how they drift.
public enum AIRewriteUse: String, CaseIterable, Sendable {
    case off
    case onDemand
    case always

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .onDemand: "On demand"
        case .always: "Always"
        }
    }

    /// One line, shown under the picker in Settings.
    public var summary: String {
        switch self {
        case .off:
            "No AI rewrite anywhere. The right-click rows stay in the Services menu — "
                + "macOS builds that list from the app bundle, not from this setting — "
                + "but they'll tell you it's off."
        case .onDemand:
            "Dictation pastes cleaned text, untouched by AI. Select text anywhere and "
                + "right-click ▸ Services ▸ Orbit Flow to rewrite it when you want to."
        case .always:
            "Every dictation is rewritten before it's pasted, and the right-click rows "
                + "work too. Your text leaves this Mac."
        }
    }

    /// Whether dictation itself sends the transcript to the cloud.
    public var rewritesDictation: Bool { self == .always }

    /// Whether the Services rows should do anything when clicked.
    public var servesOnDemand: Bool { self != .off }

    /// What a user of the previous build lands on, first time this build runs.
    ///
    /// - Parameters:
    ///   - stored: The persisted raw value. Absent on the first launch of this build,
    ///     and unreadable if a future build wrote something this one doesn't know.
    ///   - legacyTierWasCloud: Whether the stored `cleanupTier` was `cloud`, which is the
    ///     only way the previous build could express "rewrite every dictation".
    public static func resolve(stored: String?, legacyTierWasCloud: Bool) -> AIRewriteUse {
        if let stored, let use = AIRewriteUse(rawValue: stored) { return use }
        return legacyTierWasCloud ? .always : .off
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, all `AIRewriteUseTests` green, no other test regressed.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlowAIRewrite/AIRewriteUse.swift Tests/OrbitFlowAIRewriteTests/AIRewriteUseTests.swift
git commit -m "Add AIRewriteUse: off, on demand, always

The setting that splits the rewrite from the moment it runs. Lives in the
rewrite target rather than beside Settings because the app target is an
executable and cannot be imported by a test target."
```

---

### Task 2: The on-demand engine rule

**Files:**
- Create: `Sources/OrbitFlowAIRewrite/OnDemandRewrite.swift`
- Test: `Tests/OrbitFlowAIRewriteTests/OnDemandRewriteTests.swift`

**Interfaces:**
- Consumes: `AIRewriteUse` (Task 1).
- Produces:
  - `public enum OnDemandRewrite`
  - `public enum OnDemandRewrite.Engine: Equatable, Sendable` — `cloud`, `onDevice`
  - `public enum OnDemandRewrite.Unavailable: Equatable, Sendable` — `turnedOff`, `nothingAvailable`, with `public var summary: String`
  - `public static func engine(use:hasKey:model:onDeviceAvailable:) -> Result<Engine, Unavailable>`

- [ ] **Step 1: Write the failing test**

Create `Tests/OrbitFlowAIRewriteTests/OnDemandRewriteTests.swift`:

```swift
import Testing

@testable import OrbitFlowAIRewrite

struct OnDemandRewriteTests {
    private func decide(
        use: AIRewriteUse = .onDemand,
        hasKey: Bool = true,
        model: String = "claude-sonnet-4-5",
        onDevice: Bool = true
    ) -> Result<OnDemandRewrite.Engine, OnDemandRewrite.Unavailable> {
        OnDemandRewrite.engine(
            use: use, hasKey: hasKey, model: model, onDeviceAvailable: onDevice
        )
    }

    /// Cloud wins when it's configured, because configuring it was deliberate work.
    /// On-device is the fallback, not a preference.
    @Test("A configured key and model select cloud")
    func prefersCloud() {
        #expect(decide() == .success(.cloud))
    }

    @Test("No key falls back to on-device")
    func noKey() {
        #expect(decide(hasKey: false) == .success(.onDevice))
    }

    /// A key with no model is not a working cloud setup — the request would 400.
    /// It has to fall back exactly as a missing key does.
    @Test("A key with no model falls back to on-device")
    func noModel() {
        #expect(decide(model: "") == .success(.onDevice))
        #expect(decide(model: "   ") == .success(.onDevice))
    }

    @Test("Nothing configured and no on-device model is a refusal")
    func nothingAvailable() {
        #expect(decide(hasKey: false, onDevice: false) == .failure(.nothingAvailable))
    }

    /// Off must refuse before anything else is considered. The Services rows cannot be
    /// hidden — Info.plist is static — so this refusal is the only thing that makes
    /// "off" mean off.
    @Test("Off refuses even when everything is configured")
    func offRefusesFirst() {
        #expect(decide(use: .off) == .failure(.turnedOff))
        #expect(decide(use: .off, hasKey: false, onDevice: false) == .failure(.turnedOff))
    }

    /// Always is a superset of on demand: dictation rewrites *and* the rows work.
    @Test("Always serves the on-demand rows too")
    func alwaysAlsoServes() {
        #expect(decide(use: .always) == .success(.cloud))
        #expect(decide(use: .always, hasKey: false) == .success(.onDevice))
    }

    @Test("Refusal reasons are non-empty and distinct")
    func reasons() {
        let summaries = [
            OnDemandRewrite.Unavailable.turnedOff.summary,
            OnDemandRewrite.Unavailable.nothingAvailable.summary,
        ]
        #expect(Set(summaries).count == 2)
        #expect(summaries.allSatisfy { !$0.isEmpty })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'OnDemandRewrite' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/OrbitFlowAIRewrite/OnDemandRewrite.swift`:

```swift
import Foundation

/// Which engine an on-demand rewrite uses, and why it can't run when it can't.
///
/// Pure and here rather than beside `Settings` for the same reason `RewriteMode` is: the
/// app target is an executable and cannot be imported by a test target, so logic that
/// lives there cannot be tested at all.
public enum OnDemandRewrite {
    public enum Engine: Equatable, Sendable {
        case cloud
        case onDevice
    }

    /// Why an on-demand rewrite can't run. Both cases are shown to the user, so both
    /// have to say what to do about it rather than just what went wrong.
    public enum Unavailable: Equatable, Sendable {
        /// The setting is `off`. Reachable because `NSServices` rows are declared in
        /// `Info.plist` and cannot be hidden at runtime — this refusal is what makes the
        /// setting mean anything.
        case turnedOff
        /// No API key and no on-device model.
        case nothingAvailable

        /// Shown in the HUD pill, which is one line wide. Keep it short.
        public var summary: String {
            switch self {
            case .turnedOff: "AI rewrite is off — turn it on in Settings."
            case .nothingAvailable: "No rewrite available — add an API key in Settings."
            }
        }
    }

    /// - Parameters:
    ///   - hasKey: Whether the Keychain holds a key for the *current* provider. Switching
    ///     providers switches which key this asks about.
    ///   - model: The configured model id. Blank is not a working cloud setup — the
    ///     request would fail — so it falls back exactly as a missing key does.
    ///   - onDeviceAvailable: `OnDeviceRewriter.isAvailable`, which is false on a Mac
    ///     without Apple Intelligence or with it switched off.
    public static func engine(
        use: AIRewriteUse,
        hasKey: Bool,
        model: String,
        onDeviceAvailable: Bool
    ) -> Result<Engine, Unavailable> {
        guard use.servesOnDemand else { return .failure(.turnedOff) }
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasKey, hasModel { return .success(.cloud) }
        if onDeviceAvailable { return .success(.onDevice) }
        return .failure(.nothingAvailable)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlowAIRewrite/OnDemandRewrite.swift Tests/OrbitFlowAIRewriteTests/OnDemandRewriteTests.swift
git commit -m "Add the on-demand engine rule

Cloud when it's configured, on-device otherwise, a refusal with a reason when
neither. Off refuses first, because Info.plist service rows can't be hidden."
```

---

### Task 3: Adopt `AIRewriteUse` across the app

This task is one compile unit and cannot be split: removing `CleanupTier.cloud` breaks
every site that switches on it, and Swift will not build until all of them are fixed. The
compiler enumerates them for you — work through its error list.

**Files:**
- Modify: `Sources/OrbitFlow/Support/Settings.swift`
- Modify: `Sources/OrbitFlow/Core/DictationController.swift`
- Modify: `Sources/OrbitFlow/UI/SettingsWindow.swift`
- Modify: `Sources/OrbitFlow/UI/TranscriptionDetail.swift:340`
- Modify: `Sources/OrbitFlow/OrbitFlowApp.swift:215`

**Interfaces:**
- Consumes: `AIRewriteUse` (Task 1).
- Produces:
  - `Settings.aiRewriteUse: AIRewriteUse` — persisted under key `aiRewriteUse`
  - `CleanupTier` reduced to `rules` and `onDevice`
  - `Settings.tierBeforeCloud` deleted

- [ ] **Step 1: Reduce `CleanupTier` and add the new setting**

In `Sources/OrbitFlow/Support/Settings.swift`, replace the `CleanupTier` enum with:

```swift
/// Which *local* pass cleans a transcript before it's injected.
///
/// No longer expresses the cloud: `AIRewriteUse` owns that decision now, and having two
/// properties able to disagree about whether text leaves the Mac is not a risk worth
/// carrying. The `cloud` case that used to live here is migrated away in `init`.
enum CleanupTier: String, CaseIterable, Sendable {
    /// Deterministic, zero-latency, always available.
    case rules
    /// Apple's on-device Foundation Model. Nothing leaves the Mac.
    case onDevice

    var displayName: String {
        switch self {
        case .rules: "Rules"
        case .onDevice: "On-device"
        }
    }
}
```

Delete the whole `tierBeforeCloud` property (declaration and `didSet`). Add, next to `cleanupTier`:

```swift
/// When the AI rewrite runs: never, only when asked from the Services menu, or on
/// every dictation.
var aiRewriteUse: AIRewriteUse {
    didSet { defaults.set(aiRewriteUse.rawValue, forKey: Keys.aiRewriteUse) }
}
```

In `Keys`, delete `tierBeforeCloud` and add:

```swift
static let aiRewriteUse = "aiRewriteUse"
/// Read once, never written: the restore slot the old AI-rewrite toggle used, consumed
/// by the migration in `init`.
static let legacyTierBeforeCloud = "tierBeforeCloud"
```

- [ ] **Step 2: Migrate in `init`**

In `Settings.init`, replace the `cleanupTier` resolution block and the `tierBeforeCloud`
line with:

```swift
// `cloud` is no longer a tier. A user who had it selected was saying "rewrite every
// dictation", which is now `aiRewriteUse == .always`, and the tier underneath goes back
// to whatever the old toggle would have restored.
let storedTier = defaults.string(forKey: Keys.cleanupTier)
let tierWasCloud = storedTier == "cloud"

aiRewriteUse = AIRewriteUse.resolve(
    stored: defaults.string(forKey: Keys.aiRewriteUse),
    legacyTierWasCloud: tierWasCloud
)

if tierWasCloud {
    cleanupTier = CleanupTier(
        rawValue: defaults.string(forKey: Keys.legacyTierBeforeCloud) ?? ""
    ) ?? .rules
} else if let storedTier, let tier = CleanupTier(rawValue: storedTier) {
    cleanupTier = tier
} else {
    let wasSmart = defaults.object(forKey: Keys.legacySmartCleanup) as? Bool ?? false
    cleanupTier = wasSmart ? .onDevice : .rules
}
```

At the very end of `init`, add — `didSet` does not fire during initialization, so without
these two writes the migration would re-run on every launch and a legacy `cloud` string
would sit in defaults forever:

```swift
defaults.set(aiRewriteUse.rawValue, forKey: Keys.aiRewriteUse)
defaults.set(cleanupTier.rawValue, forKey: Keys.cleanupTier)
```

- [ ] **Step 3: Point dictation at the new setting**

In `Sources/OrbitFlow/Core/DictationController.swift`, replace `activeFormatter`:

```swift
/// Chosen per-utterance so a tier or mode change applies to the very next hold.
private var activeFormatter: any TextFormatter {
    if let formatter { return formatter }
    let settings = Settings.shared
    // Cloud during dictation is exactly `.always`, and nothing else. Reading the
    // setting that owns that decision — rather than inferring it from the tier —
    // is what makes it impossible for `onDemand` to leak an utterance.
    guard settings.aiRewriteUse.rewritesDictation else {
        switch settings.cleanupTier {
        case .rules: return RuleBasedFormatter()
        case .onDevice: return FoundationModelFormatter()
        }
    }
    // Read on the main actor, here, because CloudFormatter's format() is not
    // main-actor isolated and Settings is.
    return CloudFormatter(
        provider: settings.aiProvider,
        model: settings.aiModel,
        key: Keychain.read(account: settings.aiProvider.rawValue) ?? "",
        mode: settings.rewriteMode
    )
}
```

In `endDictation`, replace the `isRewriting` assignment:

```swift
if token == runToken {
    isRewriting = Settings.shared.cleanupEnabled
        && Settings.shared.aiRewriteUse.rewritesDictation
}
```

In `draftRecord`, replace the `switch settings.cleanupTier` block:

```swift
let instruction: String
let engine: String
if settings.aiRewriteUse.rewritesDictation {
    instruction = settings.rewriteMode.displayName
    engine = "\(settings.aiProvider.displayName) · \(settings.aiModel)"
} else {
    instruction = "Cleanup"
    engine = settings.cleanupTier == .onDevice ? "Apple on-device" : "Rules"
}
```

- [ ] **Step 4: Swap the Settings toggle for the three-way**

In `Sources/OrbitFlow/UI/SettingsWindow.swift`, delete the `aiRewriteBinding` computed
property entirely (around line 357). Replace the `Toggle(isOn: aiRewriteBinding)` block
and its four `note(...)` branches (lines 109–134) with:

```swift
FieldLabel(text: "AI rewrite", color: DS.Color.ink, emphasis: true)
Segmented(
    options: AIRewriteUse.allCases.map { ($0, $0.displayName) },
    selection: Binding(
        get: { settings.aiRewriteUse },
        // Always without a key rewrites nothing and falls back on every single
        // utterance, which looks like the feature is broken rather than unconfigured.
        set: { settings.aiRewriteUse = ($0 == .always && !canUseCloud) ? .onDemand : $0 }
    )
)
note(settings.aiRewriteUse.summary)

if settings.aiRewriteUse != .off, !canUseCloud {
    note(hasStoredKey
        ? "Press Test below to pick a model. Until then, rewrites use Apple's "
            + "on-device model."
        : "Save an API key below to use \(settings.aiProvider.displayName). Until "
            + "then, rewrites use Apple's on-device model.")
}
```

Add next to `hasStoredKey`'s other uses:

```swift
/// A cloud rewrite needs both halves. Either one missing means every call would
/// fall back, so the UI must not present it as configured.
private var canUseCloud: Bool { hasStoredKey && !settings.aiModel.isEmpty }
```

Replace the stale-tier note at line 161:

```swift
if settings.aiRewriteUse == .always, !settings.cleanupEnabled {
    note("\"Clean up transcripts\" is off, so dictation isn't being rewritten right "
        + "now. The right-click rows still work.")
}
```

Replace the mode-picker condition at line 138 (`if settings.cleanupTier == .cloud`) with
`if settings.aiRewriteUse != .off`, and update its `note` to say the mode is what the
default right-click row uses:

```swift
note(settings.rewriteMode.summary
    + " Also the mode used by right-click ▸ Services ▸ Rewrite with Orbit Flow.")
```

In `removeKey()` (line 400) and the `onChange(of: settings.aiProvider)` block (line 158),
replace both `settings.cleanupTier = settings.tierBeforeCloud` lines with:

```swift
// A cloud rewrite with no key for this provider falls back on every call. Don't
// leave dictation armed for it; the on-demand rows degrade to on-device on their own.
if settings.aiRewriteUse == .always { settings.aiRewriteUse = .onDemand }
```

- [ ] **Step 5: Fix the two stale `cleanupTier == .cloud` couplings**

In `Sources/OrbitFlow/UI/TranscriptionDetail.swift` around line 340, replace
`isCloudReady`:

```swift
/// Whether a cloud rewrite can run from this page.
///
/// Deliberately not a question about dictation. Under `onDemand` the cloud is fully
/// configured and dictation simply doesn't use it — testing the dictation tier here
/// would black out cloud rewrites on the page this feature routes text into.
private var isCloudReady: Bool {
    settings.aiRewriteUse.servesOnDemand && !settings.aiModel.isEmpty && hasKey
}
```

Update `blockedReason`'s last line in the same file so it no longer names a setting that
is gone:

```swift
return "Set AI rewrite to On demand or Always in Settings, with a key and a model."
```

In `Sources/OrbitFlow/OrbitFlowApp.swift` around line 215, replace
`if settings.cleanupTier == .cloud {` with `if settings.aiRewriteUse != .off {` and
update the comment above it:

```swift
// Meaningful whenever a rewrite can run at all — under On demand this picker is what
// the default right-click row reads. Hidden when nothing can use it, because a mode
// that changes nothing is worse than no mode at all.
```

- [ ] **Step 6: Build and test**

Run: `make test && make app`
Expected: tests PASS, build succeeds with no warnings about unhandled enum cases. If the
compiler still names `CleanupTier.cloud` anywhere, fix that site — the list is exhaustive.

- [ ] **Step 7: Verify the migration by hand**

```bash
defaults write ai.pivotstudio.orbitflow cleanupTier cloud
defaults write ai.pivotstudio.orbitflow tierBeforeCloud onDevice
defaults delete ai.pivotstudio.orbitflow aiRewriteUse 2>/dev/null || true
make install
sleep 5
defaults read ai.pivotstudio.orbitflow aiRewriteUse   # expect: always
defaults read ai.pivotstudio.orbitflow cleanupTier    # expect: onDevice
```

Then open Settings and confirm the AI rewrite row is a three-segment control reading
Off / On demand / Always with **Always** selected.

- [ ] **Step 8: Commit**

```bash
git add -A Sources/
git commit -m "Make AIRewriteUse the single owner of the cloud decision

CleanupTier loses its cloud case and goes back to meaning only which local pass
runs; tierBeforeCloud goes with it. Dictation now reads aiRewriteUse directly,
so On demand cannot leak an utterance through a stale tier.

Fixes two sites that tested cleanupTier == .cloud to mean 'cloud is configured'
— the detail page's isCloudReady and the menu bar's mode picker — both of which
would have gone dark under On demand."
```

---

### Task 4: A transient message surface in the HUD

The on-demand path has to say things — "Rewriting…", "that failed, here's why", "copied
to clipboard". It cannot use an alert or a notification: an alert steals focus from the
app the user is editing, and `UNUserNotificationCenter` adds a permission prompt to an app
that currently asks for exactly two. The HUD panel is already non-activating, already
positioned where the user is looking, and already renders a one-line label.

**Files:**
- Modify: `Sources/OrbitFlow/Core/DictationController.swift`
- Modify: `Sources/OrbitFlow/OrbitFlowApp.swift` (the `observeState` tracking block)
- Modify: `Sources/OrbitFlow/UI/HUDView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DictationController.notice: String?` (read-only) and
  `DictationController.flash(_ message: String)`, plus `DictationController.setRewriting(_:)`.

- [ ] **Step 1: Add the notice to the controller**

In `DictationController`, below `isRewriting`:

```swift
/// A transient message for the pill, shown when no dictation is running.
///
/// The on-demand rewrite's only way to speak. It must not steal focus — the user is
/// mid-edit in another app and a panel that activates would move their cursor — and the
/// HUD is already a non-activating panel, so it is the one surface that qualifies.
private(set) var notice: String?

/// Shows `message` in the pill for three seconds.
///
/// The token check matters: two rewrites in quick succession would otherwise have the
/// first one's timer clear the second one's message three seconds early.
func flash(_ message: String) {
    notice = message
    let shown = message
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        if notice == shown { notice = nil }
    }
}

/// Clears any notice and shows or hides "Rewriting…" for an on-demand run.
///
/// Separate from the private `isRewriting` writes in `endDictation`, which are gated on
/// the dictation run token and must stay that way.
func setRewriting(_ running: Bool) {
    if running { notice = nil }
    isRewriting = running
}
```

- [ ] **Step 2: Present the HUD for a notice**

In `Sources/OrbitFlow/OrbitFlowApp.swift`, `observeState` currently tracks only
`controller.state`. Track the two new signals too, and present on any of them:

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

- [ ] **Step 3: Render it**

In `Sources/OrbitFlow/UI/HUDView.swift`, `label` currently switches on state alone. A
notice and an idle-state rewrite both have to win over `case .idle: ""`:

```swift
private var label: String {
    // Both of these can be true while the state is `.idle` — an on-demand rewrite runs
    // with no dictation behind it — so they are checked before the state at all.
    if let notice = controller.notice { return notice }
    if case .idle = controller.state, controller.isRewriting { return "Rewriting…" }

    switch controller.state {
    case .starting: return "Listening…"
    case .listening: return controller.transcript.isEmpty ? "Listening…" : controller.transcript
    case .finishing:
        if controller.isRewriting { return "Rewriting…" }
        return controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
    case .error(let message): return message
    case .idle: return ""
    }
}
```

`hasTranscript` gates the text colour and must not treat a notice as a transcript:

```swift
private var hasTranscript: Bool {
    !isError && controller.notice == nil && !controller.transcript.isEmpty
}
```

- [ ] **Step 4: Build and verify by hand**

Run: `make install`

There is no automated check for this — it is a floating panel. Verify by adding a
temporary menu item, or simply confirm in Task 6 that failures and confirmations appear.
Confirm now that a normal dictation still shows "Listening…" then "Transcribing…" and
that the pill still disappears when it ends.

- [ ] **Step 5: Commit**

```bash
git add Sources/OrbitFlow/Core/DictationController.swift Sources/OrbitFlow/OrbitFlowApp.swift Sources/OrbitFlow/UI/HUDView.swift
git commit -m "Let the HUD carry a transient notice

The on-demand rewrite has to report failures and confirmations without stealing
focus from the app being edited. An alert would move the user's cursor and a
user notification would add a permission prompt; the HUD is already a
non-activating panel sitting where the user is looking."
```

---

### Task 5: Register the Services rows

This task exists on its own because Services registration is the one part of the feature
that can fail for reasons outside the code — `pbs` caching, LaunchServices not having
seen the bundle, a malformed plist that fails silently. Prove the rows appear before
building anything behind them.

**Files:**
- Modify: `Resources/Info.plist`
- Create: `Sources/OrbitFlow/Core/RewriteService.swift`
- Modify: `Sources/OrbitFlow/OrbitFlowApp.swift` (`applicationDidFinishLaunching`)
- Modify: `Makefile` (`install` target)

**Interfaces:**
- Consumes: `DictationController.flash` (Task 4).
- Produces: `@MainActor final class RewriteService: NSObject` with six `@objc` methods —
  `rewriteDefault`, `rewriteFaithful`, `rewriteCasual`, `rewriteProfessional`,
  `rewriteProblemSolver`, `openSelection` — each with the signature
  `(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>)`.

- [ ] **Step 1: Declare the rows**

In `Resources/Info.plist`, add before the closing `</dict>`:

```xml
	<!-- Right-click ▸ Services. The `/` in a menu item's `default` places it in a
	     submenu — Mail ships `Mail/New Email With Selection` the same way. A submenu
	     parent is not clickable in AppKit, which is why the default action is its own
	     top-level row above the submenu rather than the submenu's title.

	     No NSReturnTypes anywhere on purpose: a provider method is synchronous and the
	     system reads the reply pasteboard the moment it returns, so a cloud round trip
	     could only be answered by blocking the main thread. The result goes back through
	     TextInjector instead. See Sources/OrbitFlow/Core/RewriteService.swift. -->
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
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Orbit Flow/Faithful</string></dict>
			<key>NSMessage</key><string>rewriteFaithful</string>
			<key>NSPortName</key><string>Orbit Flow</string>
			<key>NSSendTypes</key>
			<array><string>public.utf8-plain-text</string></array>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Orbit Flow/Casual</string></dict>
			<key>NSMessage</key><string>rewriteCasual</string>
			<key>NSPortName</key><string>Orbit Flow</string>
			<key>NSSendTypes</key>
			<array><string>public.utf8-plain-text</string></array>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Orbit Flow/Professional</string></dict>
			<key>NSMessage</key><string>rewriteProfessional</string>
			<key>NSPortName</key><string>Orbit Flow</string>
			<key>NSSendTypes</key>
			<array><string>public.utf8-plain-text</string></array>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Orbit Flow/Problem-solver</string></dict>
			<key>NSMessage</key><string>rewriteProblemSolver</string>
			<key>NSPortName</key><string>Orbit Flow</string>
			<key>NSSendTypes</key>
			<array><string>public.utf8-plain-text</string></array>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Orbit Flow/Open in Orbit Flow</string></dict>
			<key>NSMessage</key><string>openSelection</string>
			<key>NSPortName</key><string>Orbit Flow</string>
			<key>NSSendTypes</key>
			<array><string>public.utf8-plain-text</string></array>
		</dict>
	</array>
```

- [ ] **Step 2: Write a stub provider that only proves the wiring**

Create `Sources/OrbitFlow/Core/RewriteService.swift`:

```swift
import AppKit
import Foundation
import OrbitFlowAIRewrite

/// The right-click entry point: rewrite a selection made in any other app.
///
/// Registered as `NSApp.servicesProvider`. macOS calls one of the `@objc` methods below
/// with the selected text on a pasteboard; the rows themselves are declared in
/// `Info.plist`, which is why they cannot be hidden when the feature is off.
@MainActor
final class RewriteService: NSObject {
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
    }

    @objc func rewriteDefault(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: Settings.shared.rewriteMode) }

    @objc func rewriteFaithful(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .faithful) }

    @objc func rewriteCasual(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .casual) }

    @objc func rewriteProfessional(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .professional) }

    @objc func rewriteProblemSolver(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .problemSolver) }

    @objc func openSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = selection(from: pboard) else { return }
        controller.flash("Open: \(text.prefix(20))…")
    }

    // MARK: - Shared path

    private func run(_ pboard: NSPasteboard, mode: RewriteMode) {
        guard let text = selection(from: pboard) else { return }
        controller.flash("\(mode.displayName): \(text.prefix(20))…")
    }

    /// Nil when the pasteboard carries nothing usable — an empty selection, or a
    /// whitespace-only one, both of which would waste a round trip.
    private func selection(from pboard: NSPasteboard) -> String? {
        guard let raw = pboard.string(forType: .string) else {
            controller.flash("Nothing selected.")
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            controller.flash("Nothing selected.")
            return nil
        }
        return trimmed
    }
}
```

- [ ] **Step 3: Register it**

In `Sources/OrbitFlow/OrbitFlowApp.swift`, add a stored property beside `hud`:

```swift
private var rewriteService: RewriteService?
```

and in `applicationDidFinishLaunching`, after `hud = HUDPanel(controller: controller)`:

```swift
// Held in a property because `servicesProvider` is an unowned reference — an
// inline instance would deallocate and every right-click row would silently
// do nothing. NSUpdateDynamicServices tells the system to re-read Info.plist,
// which matters on the launch right after a build changed it.
let service = RewriteService(controller: controller)
rewriteService = service
NSApp.servicesProvider = service
NSUpdateDynamicServices()
```

- [ ] **Step 4: Flush the Services cache on install**

In the `Makefile`'s `install` target, add after the `@open` line:

```make
	@# pbs caches the Services database and does not notice a changed Info.plist on its
	@# own, so every build that touches NSServices would otherwise show stale rows.
	@/System/Library/CoreServices/pbs -flush 2>/dev/null || true
```

- [ ] **Step 5: Verify the rows appear**

```bash
make install
sleep 5
/System/Library/CoreServices/pbs -dump_pboard 2>/dev/null | grep -i "Orbit Flow" | head
```

Then, by hand: open TextEdit, type a sentence, select it, right-click, hover **Services**.
Expected:

```
Rewrite with Orbit Flow
Orbit Flow ▸  Faithful / Casual / Professional / Problem-solver / Open in Orbit Flow
```

Click **Rewrite with Orbit Flow**. Expected: the HUD pill appears near the bottom of the
screen showing the mode name and the first 20 characters of the selection, then fades
after three seconds. Focus stays in TextEdit — the caret does not move and Orbit Flow does
not come to the front.

**If the rows do not appear**, in order: confirm the app is running; run
`/System/Library/CoreServices/pbs -flush` again and wait 10 seconds; log out and back in
(the reliable fix); check `plutil -lint "$HOME/Applications/Orbit Flow.app/Contents/Info.plist"`.
Do not proceed to Task 6 until they appear — everything after this is behind them.

- [ ] **Step 6: Commit**

```bash
git add Resources/Info.plist Sources/OrbitFlow/Core/RewriteService.swift Sources/OrbitFlow/OrbitFlowApp.swift Makefile
git commit -m "Add the Services rows, wired to a stub

Six NSServices entries and a provider that only echoes the selection into the
HUD. Registration is the part of this feature that can fail for reasons outside
the code — pbs caching, LaunchServices — so it lands and gets verified before
anything is built behind it."
```

---

### Task 6: Rewrite the selection in place

**Files:**
- Modify: `Sources/OrbitFlow/Core/RewriteService.swift`

**Interfaces:**
- Consumes: `OnDemandRewrite.engine` (Task 2), `DictationController.flash` /
  `setRewriting` (Task 4), and the existing `CloudRewriter`, `OnDeviceRewriter`,
  `TextInjector.insert`.
- Produces: nothing new — replaces the stub `run(_:mode:)`.

- [ ] **Step 1: Replace the stub `run(_:mode:)`**

In `Sources/OrbitFlow/Core/RewriteService.swift`, replace the `run` method with:

```swift
    private func run(_ pboard: NSPasteboard, mode: RewriteMode) {
        guard let text = selection(from: pboard) else { return }

        let settings = Settings.shared
        let provider = settings.aiProvider
        let model = settings.aiModel
        let hasKey = Keychain.hasKey(account: provider.rawValue)

        let engine: OnDemandRewrite.Engine
        switch OnDemandRewrite.engine(
            use: settings.aiRewriteUse,
            hasKey: hasKey,
            model: model,
            onDeviceAvailable: OnDeviceRewriter.isAvailable
        ) {
        case .success(let chosen):
            engine = chosen
        case .failure(let reason):
            controller.flash(reason.summary)
            return
        }

        let key = engine == .cloud ? (Keychain.read(account: provider.rawValue) ?? "") : ""
        controller.setRewriting(true)

        Task { @MainActor in
            defer { controller.setRewriting(false) }
            do {
                // Longer than dictation's 8s. Nothing is queued behind this and the user
                // asked for it explicitly, so waiting beats a failure they have to
                // right-click again to retry.
                let output: String
                if engine == .cloud {
                    output = try await CloudRewriter(
                        provider: provider, key: key, timeout: .seconds(30)
                    ).rewrite(text, model: model, mode: mode)
                } else {
                    output = try await OnDeviceRewriter.rewrite(
                        text, system: mode.systemPrompt, timeout: .seconds(30)
                    )
                }
                deliver(output, mode: mode)
            } catch {
                // The opposite of CloudFormatter's contract, on purpose. Dictation falls
                // back to the rule pass because an utterance already spoken must not be
                // lost. Here the user's own words are already on screen and already good
                // enough to have been written — overwriting a paragraph with a degraded
                // version of itself because a request timed out is a destructive
                // surprise on text nobody asked us to touch. So: change nothing.
                let reason = (error as? RewriteFailure)?.summary
                    ?? OnDeviceRewriter.describe(error)
                Log.inject.info("on-demand rewrite failed (\(reason, privacy: .private))")
                controller.flash("Rewrite failed — \(reason)")
            }
        }
    }

    /// Puts the result where the user can use it.
    ///
    /// A selection in a web page or a PDF cannot be replaced, and macOS gives no way to
    /// know that before trying — `TextInjector` falls back to ⌘V, which a read-only view
    /// simply ignores, and neither step reports back. So the result also goes on the
    /// pasteboard and the notice says so, which is true whether or not the injection
    /// landed. Dictation can inject silently; this cannot.
    private func deliver(_ output: String, mode: RewriteMode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        TextInjector.insert(output)
        controller.flash("\(mode.displayName) — also copied to clipboard")
    }
```

- [ ] **Step 2: Build**

Run: `make test && make app`
Expected: tests PASS, build succeeds.

Note the deliberate interaction with `TextInjector.insert`: its pasteboard fallback saves
and restores the previous contents 500ms after pasting. Because `deliver` writes the
result to the pasteboard *before* calling it, the restore puts the rewritten text back —
which is the intent. Do not "fix" this by reordering.

- [ ] **Step 3: Verify by hand**

Run: `make install`

Set **Settings ▸ AI rewrite** to **On demand** with a key and model saved. Then:

| Where | Do | Expect |
|---|---|---|
| TextEdit | select a sloppy sentence, Services ▸ Rewrite with Orbit Flow | pill says "Rewriting…", then the sentence is replaced in place; ⌘Z undoes it |
| TextEdit | Services ▸ Orbit Flow ▸ Professional | replaced, and visibly more formal than Faithful |
| Cursor or Slack | same | replaced via the ⌘V fallback |
| Safari, selected article text | same | text unchanged, pill says "…also copied to clipboard", ⌘V elsewhere pastes the rewrite |
| Wi-Fi off | same | **selection unchanged**, pill names the failure |
| Settings ▸ AI rewrite ▸ Off, then any row | | selection unchanged, pill says "AI rewrite is off — turn it on in Settings." |

The Wi-Fi-off row is the one that matters most. If the selection changes at all in that
case, the failure contract is broken — stop and fix it before committing.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrbitFlow/Core/RewriteService.swift
git commit -m "Rewrite the selection in place from the Services menu

Failure leaves the selection untouched, which is the opposite of dictation's
fallback and deliberately so: the user's words are already on screen, and
overwriting them with a degraded version because a request timed out is a
destructive surprise on text nobody asked us to touch."
```

---

### Task 7: Open in Orbit Flow

**Files:**
- Create: `Sources/OrbitFlow/UI/MainRoute.swift`
- Modify: `Sources/OrbitFlow/UI/MainWindow.swift` (`TranscriptionList.opened`, line 155)
- Modify: `Sources/OrbitFlow/Core/RewriteService.swift` (`openSelection`)

**Interfaces:**
- Consumes: `RunLog.record`, `AppDelegate.showMainWindow`.
- Produces: `@MainActor @Observable final class MainRoute` with `static let shared`,
  `var openRun: UUID?`, and `func open(_ id: UUID)`.

- [ ] **Step 1: Lift the routing state out of the view**

Create `Sources/OrbitFlow/UI/MainRoute.swift`:

```swift
import Foundation
import Observation

/// Which transcription the main window is showing, when something outside the window
/// needs to say so.
///
/// `TranscriptionList` held this as private `@State`, which is right until a second
/// caller appears — the Services menu now has to open a specific run. This is the
/// smallest thing that lets both reach the same destination. It is not a router and
/// should not grow into one: if a third caller shows up, that is the moment to think
/// about navigation properly, not now.
@MainActor
@Observable
final class MainRoute {
    static let shared = MainRoute()

    /// Non-nil while one transcription is open for editing and rewriting. Held by id,
    /// not by value: the detail page writes rewrites back as they land, and a snapshot
    /// here would go stale the moment it did.
    var openRun: UUID?

    private init() {}

    func open(_ id: UUID) { openRun = id }
}
```

- [ ] **Step 2: Point the list at it**

In `Sources/OrbitFlow/UI/MainWindow.swift`, delete the `@State private var opened: UUID?`
declaration and its doc comment (lines 151–155), and add:

```swift
    @State private var route = MainRoute.shared
```

Replace the three uses. `body`:

```swift
    var body: some View {
        if let opened = route.openRun {
            TranscriptionDetail(runID: opened) {
                withAnimation(DS.Motion.panel) { route.openRun = nil }
            }
        } else {
            list
        }
    }
```

and the row's `onOpen`:

```swift
onOpen: { withAnimation(DS.Motion.panel) { route.openRun = run.id } },
```

- [ ] **Step 3: Implement the row**

In `Sources/OrbitFlow/Core/RewriteService.swift`, replace the stub `openSelection`:

```swift
    /// Unlike the in-place rows, this one deliberately activates the app — bringing the
    /// window forward is the whole point of it.
    @objc func openSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = selection(from: pboard) else { return }

        // The same call the "Add text" composer makes, with a different engine label so
        // history says where this came from.
        let run = DictationRun(
            date: Date(),
            engine: "Selection",
            audioSeconds: 0,
            processSeconds: 0,
            text: text
        )
        RunLog.record(run)
        MainRoute.shared.open(run.id)
        AppDelegate.showMainWindow()
    }
```

- [ ] **Step 4: Build**

Run: `make test && make app`
Expected: tests PASS, build succeeds.

- [ ] **Step 5: Verify by hand**

Run: `make install`

Select a paragraph in any app, right-click ▸ Services ▸ Orbit Flow ▸ Open in Orbit Flow.

Expected: Orbit Flow comes to the front on the transcription detail page, "What you said"
holds the selected text, and the mode buttons and instruction field are live. Run
**Professional** — a version appears and persists after clicking Transcriptions and
reopening the run. The history row reads `Selection`.

Also confirm the ordinary path still works: from the transcriptions list, click a row and
confirm it opens, and Back returns to the list.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrbitFlow/UI/MainRoute.swift Sources/OrbitFlow/UI/MainWindow.swift Sources/OrbitFlow/Core/RewriteService.swift
git commit -m "Add Open in Orbit Flow

Files the selection as a run and opens it on the detail page, which already has
modes, a custom instruction field, an engine picker and kept versions. Routing
state lifts out of TranscriptionList's private @State so both the row tap and
the Services menu can reach the same destination."
```

---

### Task 8: Documentation and the full verification pass

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-04-on-demand-rewrite-design.md` (status line)

- [ ] **Step 1: Run the full matrix**

Run: `make test && make install`

Work through every row. All must pass before the feature is done.

| # | Setup | Action | Expect |
|---|---|---|---|
| 1 | On demand, key + model | dictate a sentence | pasted text is rules- or on-device-cleaned, **never** cloud-rewritten; no "Rewriting…" |
| 2 | Always, key + model | dictate a sentence | "Rewriting…" appears, pasted text is cloud-rewritten |
| 3 | On demand | TextEdit selection, Rewrite with Orbit Flow | replaced in place, ⌘Z undoes it |
| 4 | On demand | Cursor or Slack selection, same | replaced via ⌘V fallback |
| 5 | On demand | Safari selection, same | unchanged; "also copied to clipboard"; ⌘V pastes the rewrite |
| 6 | On demand | Services ▸ Orbit Flow ▸ each of the four modes | four visibly different results |
| 7 | On demand | Open in Orbit Flow | app activates on the detail page with the text loaded |
| 8 | On demand, Wi-Fi off | any rewrite row | **selection unchanged**, pill names the failure |
| 9 | Off | any rewrite row | selection unchanged, pill points at Settings |
| 10 | No key saved, Apple Intelligence on | any rewrite row | rewrites on-device, still replaces in place |
| 11 | Bind ⌥⌘R to "Rewrite with Orbit Flow" in System Settings ▸ Keyboard ▸ Shortcuts ▸ Services | select text, press it | same as row 3 |
| 12 | Detail page under On demand | open any run | cloud/on-device picker is live, not blocked |
| 13 | Menu bar under On demand | open the menu | Rewrite mode picker is present |
| 14 | Settings | switch provider to one with no key while set to Always | drops to On demand, note explains why |
| 15 | On demand, HUD pill set to Compact, Wi-Fi off | Services ▸ Orbit Flow ▸ any row | pill widens and shows the failure message legibly — not truncated, not silently dropped |
| 16 | `defaults write ai.pivotstudio.orbitflow cleanupTier cloud`, `defaults write ai.pivotstudio.orbitflow tierBeforeCloud onDevice`, `defaults delete ai.pivotstudio.orbitflow aiRewriteUse` | relaunch | AI rewrite reads Always; `defaults read ai.pivotstudio.orbitflow cleanupTier` reads `onDevice` |
| 17 | Same as 16, but `tierBeforeCloud` never set (`defaults delete ai.pivotstudio.orbitflow tierBeforeCloud`) | relaunch | AI rewrite reads Always; `cleanupTier` reads `rules` |
| 18 | Set AI rewrite to On demand, quit | relaunch | still reads On demand — the migration does not re-fire on a second launch |
| 19 | No key saved, Apple Intelligence on | select "What's the capital of France?", Services ▸ Orbit Flow ▸ Faithful | **selection unchanged**, pill names a rejection — the on-device path is guarded the same as cloud |
| 20 | On demand | Open in Orbit Flow once with the main window closed, then again with it open on the **Settings** tab | both times the app activates on the detail page with the text loaded, never left showing Settings |
| 21 | Off | Open in Orbit Flow | selection unchanged, pill points at Settings — same refusal as the other five rows |
| 22 | On demand, key + model | invoke a rewrite row, then invoke a second row before the first returns | the second refuses ("Already rewriting — one at a time."); only one paste, one API call |

- [ ] **Step 2: Document it in the README**

Find the section describing the cleanup tiers and the AI rewrite toggle. Replace the
toggle's description with the three states, and add:

```markdown
### Rewriting text you didn't dictate

Set **AI rewrite** to **On demand** and dictation pastes clean, untouched text —
the rewrite waits until you ask for it.

Select text in any app and right-click ▸ **Services**:

- **Rewrite with Orbit Flow** — rewrites the selection in place, using the mode
  set in Settings or the menu bar.
- **Orbit Flow ▸ Faithful / Casual / Professional / Problem-solver** — the same,
  with the mode chosen at the moment you use it.
- **Orbit Flow ▸ Open in Orbit Flow** — brings the selection into the app, where
  you get every mode, your own written instructions, a cloud/on-device switch,
  and every version kept side by side.

Services rows sit one level down under **Services ▸** — macOS doesn't let any app
add a top-level right-click item. Give the one you use a keyboard shortcut in
**System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services** and it becomes a
single keystroke.

If a rewrite fails, your selection is left exactly as it was. That's the opposite
of what dictation does, on purpose: a spoken sentence you'd lose is worth
degrading to a rule-based cleanup, but text already on your screen is not worth
overwriting with a worse version of itself because a request timed out.

The result is always copied to your clipboard as well, because a selection in a
web page or a PDF can't be replaced and macOS gives no way to know that in
advance.
```

- [ ] **Step 3: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-04-on-demand-rewrite-design.md`, change
`**Status:** approved design, not yet implemented.` to `**Status:** implemented.`

Add under it, since the implementation departed from the spec in three places and the
spec is the document someone reads first:

```markdown
**Implementation notes:** three departures from this design, all deliberate.
(1) `AIRewriteUse` and the engine rule live in `OrbitFlowAIRewrite`, not the app
target — §7 asked for testable free functions, and the app target is an
executable that no test target can import. (2) §2's "tier dance" was replaced by
deleting `CleanupTier.cloud` and `tierBeforeCloud` outright: two properties able
to disagree about whether text leaves the Mac is a drift bug waiting to happen,
and a one-time migration removes the possibility instead of managing it.
(3) §4's "user notification" is the HUD pill, not `UNUserNotificationCenter` —
the HUD is already non-activating, which the notification centre is not required
to be, and it costs no new permission prompt.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-09-04-on-demand-rewrite-design.md
git commit -m "Document on-demand rewrite

Records the three places the implementation departed from the design and why."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1.1 menu shape | 5 |
| §1.2 Info.plist entries | 5 |
| §1.3 `pbs -flush` on install | 5 |
| §2 three-way setting + migration | 1, 3 |
| §2.1 `isCloudReady` and menu-bar picker | 3 (Step 5) |
| §3 no `NSReturnTypes`, `TextInjector` return path | 5 (plist), 6 (delivery) |
| §3.1 engine rule | 2, 6 |
| §3.2 "Rewriting…" progress | 4, 6 |
| §4 failure leaves the selection alone | 6 (Step 1 catch block, Step 3 row 5) |
| §4.1 read-only selections → clipboard + notice | 6 (`deliver`) |
| §5 Open in Orbit Flow + `MainRoute` | 7 |
| §6 files touched | all — plus `HUDView.swift`, `HUDPanel` observation, and `MainRoute.swift`, which §6 missed |
| §7 testing | 1, 2 (unit); 8 (manual matrix) |
| §8 ceilings | 8 (README) |

**Departures from the spec**, all flagged in Task 8 Step 3: logic location, the tier
deletion, and the HUD as the notification surface.

**Type consistency:** `AIRewriteUse.rewritesDictation` / `.servesOnDemand` /
`.resolve(stored:legacyTierWasCloud:)` are used in Tasks 3, 5, 6 exactly as defined in
Task 1. `OnDemandRewrite.engine(use:hasKey:model:onDeviceAvailable:)` returning
`Result<Engine, Unavailable>` is consumed in Task 6 exactly as defined in Task 2.
`controller.flash(_:)` and `controller.setRewriting(_:)` are defined in Task 4 and used in
Tasks 5 and 6. `MainRoute.shared.open(_:)` is defined and used in Task 7. The six `@objc`
method names match the six `NSMessage` values in Task 5's plist.

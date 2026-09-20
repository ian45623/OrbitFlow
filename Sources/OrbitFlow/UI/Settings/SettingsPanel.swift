import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import OrbitFlowAIRewrite
import OrbitFlowHistory
import OrbitFlowHotkey
import OrbitFlowModels
import OrbitFlowStats

/// The settings content, shared by the Settings tab in the main window and the standard
/// ⌘, window. One view rather than two, so the two can never drift apart.
///
/// Three decisions, each on its own surface with a line of plain English underneath saying
/// what changes. Nothing here is a preference for its own sake.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var speaker = Speaker.shared

    /// Typed into, then saved to the key store and cleared. Never populated *from* the
    /// store — the UI shows that a key exists, not what it is.
    @State private var keyDraft = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var availableModels: [String] = []

    @State private var hasElevenLabsKey = false
    @State private var elevenLabsKeyField = ""
    @State private var elevenLabsVoices: [ElevenLabs.Voice] = []
    @State private var elevenLabsModels: [String] = []
    @State private var elevenLabsTest: TestResult?
    @State private var isTestingElevenLabs = false
    /// A key for the overridden read-aloud provider, which may be one the rewrite tier
    /// isn't using. Nil when no override is set.
    @State private var hasOverrideKey = false
    /// Typed into and cleared on save, like `keyDraft` — the store is never read back into
    /// a field.
    @State private var overrideKeyDraft = ""

    @State private var updater = Updater.shared
    @State private var isConfirmingClear = false

    /// Shortcut recording. The capture itself lives in `ShortcutRecorder`, shared with
    /// onboarding; this screen only says what to do with the key that comes back.
    @State private var recorder = ShortcutRecorder()

    /// `SMAppService` is the store for this — there is no mirrored bool in `Settings`,
    /// so the switch can never disagree with System Settings ▸ General ▸ Login Items.
    /// Held in state only so the toggle redraws; re-read after every change.
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?

    /// For "Run setup again", which opens the onboarding scene.
    @Environment(\.openWindow) private var openWindow

    private enum TestResult: Equatable {
        case success(count: Int)
        case failure(String)
    }

    /// Which section the sidebar has selected.
    @State private var section: SettingsSection = .dictation

    /// The run log, for the week's figures. Reloaded by `RunLog.record`, so the strip is
    /// current without this screen polling anything.
    @State private var runs = RunStore.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: $section,
                badges: badges,
                hasMicrophone: Permissions.hasMicrophone,
                hasAccessibility: Permissions.hasAccessibility,
                versionLine: versionLine
            )
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader
                    sectionBody
                }
                .padding(DS.Space.panel)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Color.canvas)
        }
        .onAppear {
            refreshKeyPresence()
            refreshElevenLabsKeyPresence()
            loginItem = SMAppService.mainApp.status
        }
        .onChange(of: settings.aiProvider) {
            // Each provider has its own key and its own model list.
            availableModels = []
            testResult = nil
            keyDraft = ""
            settings.aiModel = settings.aiProvider.defaultModel
            refreshKeyPresence()
            // A cloud rewrite with no key *and model* for this provider falls back on every
            // call — the same "working cloud setup" OnDemandRewrite.engine and the Settings
            // migration both use. Don't leave dictation armed for a setup that isn't there
            // yet; the on-demand rows degrade to on-device on their own, but Always has no
            // such per-call fallback message, so it needs to actually change.
            //
            // This used to read `if settings.aiRewriteUse == .always` with no further
            // check, which was unreachable dead code while the Provider picker was gone —
            // restoring the picker (C1) made it live, and unconditional was wrong: switching
            // between two providers that both already have a working setup would still trip
            // it and silently disarm dictation rewrite the user never touched.
            let hasWorkingCloudSetup = hasStoredKey
                && !settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if settings.aiRewriteUse == .always, !hasWorkingCloudSetup {
                settings.aiRewriteUse = .onDemand
            }
        }
        .onChange(of: settings.readAloudProviderOverride) { refreshElevenLabsKeyPresence() }
        .onChange(of: settings.readAloudEnabled) { _, isOn in
            if !isOn { controller.stopReadingAloud() }
            // The tap only listens for mouse-ups while the feature is on.
            controller.reloadHotkey()
        }
        .onDisappear { recorder.stop(resuming: controller) }
    }

    /// What the sidebar shows on the right of a row: the state you'd otherwise have to
    /// open the section to learn.
    private var badges: [SettingsSection: String] {
        var badges: [SettingsSection: String] = [:]
        if settings.aiRewriteUse == .off { badges[.cleanupAI] = "Off" }
        if !settings.readAloudEnabled { badges[.readAloud] = "Off" }
        let entries = DictionaryStore.shared.entries.count
        if entries > 0 { badges[.dictionary] = "\(entries)" }
        return badges
    }

    private var versionLine: String {
        switch updater.phase {
        case .available(let build, _): "v\(Updater.currentVersion) · build \(build) ready"
        case .upToDate: "v\(Updater.currentVersion) · up to date"
        default: "v\(Updater.currentVersion) · build \(Updater.currentBuild)"
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(section.title)
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Color.ink)
                Text(section.summary)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkMuted)
            }
            Spacer()
            if section == .dictation {
                HStack(spacing: DS.Space.snug) {
                    StatusDot(
                        color: controller.isHotkeyArmed ? DS.Color.positive : DS.Color.caution,
                        isOn: true
                    )
                    MetaLabel(text: controller.isHotkeyArmed ? "Hotkey armed" : "Hotkey off")
                }
            }
            if section == .aiModels {
                modelReadout
            }
        }
        .padding(.bottom, DS.Space.roomy)
    }

    /// Quality, speed, and where the work happens — the whole page in three lines.
    ///
    /// `Runs on` has no bar because where is not a quantity. It is the only line here
    /// that can change colour, and it says "Mac + cloud" in words as well.
    private var modelReadout: some View {
        let readout = AIModelsSection.readout(for: settings)
        return VStack(alignment: .leading, spacing: DS.Space.tight) {
            bar("Quality", readout.qualityFraction, readout.quality.displayName)
            bar("Speed", readout.speedFraction, readout.speed.displayName)
            Hairline()
            HStack(spacing: DS.Space.snug) {
                Text("Runs on")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
                Spacer(minLength: DS.Space.snug)
                StatusDot(
                    color: readout.leavesMac ? DS.Color.caution : DS.Color.positive,
                    isOn: true
                )
                Text(readout.leavesMac ? "Mac + cloud" : "This Mac")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
            }
        }
        .padding(DS.Space.base)
        .frame(width: 210)
        .background(DS.Color.surface, in: .rect(cornerRadius: DS.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
        )
    }

    private func bar(_ label: String, _ fraction: Double, _ value: String) -> some View {
        HStack(spacing: DS.Space.snug) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkMuted)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.field)
                    Capsule().fill(DS.Color.ink)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text(value)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .frame(width: 62, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .dictation: dictationSection
        case .aiModels: aiModelsSection
        case .cleanupAI: cleanupSection
        case .readAloud: readAloudSection
        case .dictionary: dictionarySection
        case .history: historySection
        case .updates: updatesSection
        case .general: generalSection
        }
    }

    // MARK: - Dictation

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controller.isHotkeyArmed {
                accessibilityNotice
                    .padding(.bottom, DS.Space.base)
            }

            SettingsRow(label: "Push-to-talk key", help: "Hold to talk, or tap to stay on.") {
                shortcutList
            } detail: {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    note("Tap a shortcut to start dictating and tap it again to stop — the text "
                        + "lands wherever your cursor is. Or hold it down and let go, if you'd "
                        + "rather not think about stopping.")
                    note("The record button works regardless of what's focused, so you can still "
                        + "record without touching the key.")
                    note("A shortcut can be a modifier on its own, like Right ⌥ or fn, or a "
                        + "combination like ⌃⌥Space. If a lone modifier turns out to be part of "
                        + "another shortcut, like ⌘ in ⌘C, the recording it started is thrown away.")
                }
            }

            Hairline()

            SettingsRow(label: "Recording pill", help: "The indicator while you talk.") {
                Segmented(
                    options: HUDSize.allCases.map { ($0, $0.displayName) },
                    selection: $settings.hudSize
                )
            } detail: {
                note("Compact is just the level trace, discard, and confirm. Full adds the "
                    + "transcript as it resolves, so you can read it before it lands. "
                    + "Either way: ✓ stops and pastes, ✕ throws the recording away, and "
                    + "Escape does the same as ✕. Takes effect on your next dictation.")
            }

            Hairline()

            SettingsRow(label: "Sound", help: "A tick when a dictation starts and lands.") {
                Toggle("", isOn: $settings.soundEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Hairline()

            SettingsRow(label: "Clean up text", help: "Drops fillers, fixes spacing and punctuation.") {
                Toggle("", isOn: $settings.cleanupEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            } detail: {
                note("Dictionary corrections run either way. What the cleanup pass itself does "
                    + "is set in Cleanup & AI.")
            }

            Hairline()

            StatsStrip(stats: weekStats)
        }
    }

    /// The run log reduced to the four figures. Which engines count as on-device is app
    /// knowledge, so it is decided here rather than in `OrbitFlowStats`.
    private var weekStats: DictationStats {
        let samples = runs.runs.map { run in
            DictationSample(
                date: run.date,
                words: run.text.split(whereSeparator: \.isWhitespace).count,
                processSeconds: run.processSeconds,
                corrections: run.corrections?.count ?? 0,
                isOnDevice: !run.engine.contains("·")
            )
        }
        return DictationStats.over(samples, since: Date().addingTimeInterval(-7 * 24 * 60 * 60))
    }

    // MARK: - AI Models

    private var aiModelsSection: some View {
        AIModelsSection(settings: settings) { section = $0 }
    }

    // MARK: - Cleanup & AI

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "AI rewrite", help: "When a model rewrites what you said.") {
                Segmented(
                    options: AIRewriteUse.allCases.map { ($0, $0.displayName) },
                    selection: Binding(
                        get: { settings.aiRewriteUse },
                        // Always without a key rewrites nothing and falls back on every
                        // single utterance, which looks like the feature is broken
                        // rather than unconfigured.
                        set: { settings.aiRewriteUse = ($0 == .always && !canUseCloud) ? .onDemand : $0 }
                    )
                )
            } detail: {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    note(settings.aiRewriteUse.summary)
                    if settings.aiRewriteUse != .off, !canUseCloud { note(cloudFallbackNote) }
                    if settings.aiRewriteUse == .always, !settings.cleanupEnabled {
                        note("\"Clean up text\" is off in Dictation, so dictation isn't being "
                            + "rewritten right now. The right-click rows still work.")
                    }
                }
            }

            Hairline()

            VStack(alignment: .leading, spacing: DS.Space.base) {
                providerControls
            }
            .padding(.vertical, DS.Space.base)

            if settings.aiRewriteUse != .off {
                Hairline()
                SettingsRow(label: "Mode", help: "How a rewrite is asked to change your words.") {
                    Segmented(
                        options: RewriteMode.allCases.map { ($0, $0.displayName) },
                        selection: $settings.rewriteMode
                    )
                } detail: {
                    note(settings.rewriteMode.summary
                        + " Also the mode used by right-click ▸ Services ▸ Rewrite with Orbit Flow.")
                }
            }
        }
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                label: "Entries",
                help: "Corrections applied to every transcript, on this Mac only."
            ) {
                HStack(spacing: DS.Space.base) {
                    MetaLabel(text: "\(DictionaryStore.shared.entries.count) entries")
                    ActionButton(title: "Open dictionary", kind: .secondary) {
                        MainRoute.shared.section = .dictionary
                        AppDelegate.showMainWindow()
                    }
                }
            }

            Hairline()

            SettingsRow(label: "File", help: "Plain text you can edit or back up yourself.") {
                ActionButton(title: "Reveal in Finder", kind: .quiet) {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }
    }

    // MARK: - History & privacy

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                label: "What's kept",
                help: "Every dictation, on this Mac. No account, no analytics, no server."
            ) {
                MetaLabel(text: "\(runs.runs.count) recordings")
            } detail: {
                note("Audio is never written to disk — only the text, the engine that produced "
                    + "it, and how long it took. Cloud rewrites send the text to the provider "
                    + "you configured, and nothing else ever leaves this Mac.")
            }

            Hairline()

            SettingsRow(label: "Clear history", help: "Deletes every recorded dictation.") {
                ActionButton(title: "Clear…", kind: .quiet) { isConfirmingClear = true }
                    .confirmationDialog(
                        "Delete every dictation?",
                        isPresented: $isConfirmingClear
                    ) {
                        Button("Delete all", role: .destructive) {
                            RunLog.clear()
                            RunStore.shared.reload()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This can't be undone. Settings, dictionary entries and keys are kept.")
                    }
            }

            Hairline()

            SettingsRow(
                label: "Auto-delete",
                help: "Trim history as new dictations arrive."
            ) {
                Picker("", selection: historyModeBinding) {
                    ForEach(HistoryRetentionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } detail: {
                note("By count or by age, never both — one rule, so there's no question "
                    + "which one deleted something. Off by default, and what goes is gone: "
                    + "there is no trash to recover it from.")
            }

            if settings.historyMode != .off {
                Hairline()
                if settings.historyMode == .count { historyLimitRow } else { historyDaysRow }
                Hairline()

                SettingsRow(
                    label: "Keep pinned",
                    help: "Pinned dictations survive the trim."
                ) {
                    Toggle("", isOn: $settings.historyKeepsPinned)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: settings.historyKeepsPinned) { RunLog.enforceRetention() }
                } detail: {
                    note("Pinned dictations don't count toward the limit either, so pinning "
                        + "one never pushes another out. Turn this off and the limit applies "
                        + "to everything, pins included.")
                }
            }

            Hairline()

            SettingsRow(
                label: "When you close the window",
                help: "Orbit Flow keeps running and the key stays armed."
            ) {
                MetaLabel(text: "Stays running")
            } detail: {
                note("Reopen it from the menu bar or the Dock icon; quit from the Dock, the "
                    + "menu bar, or ⌘Q.")
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "Install automatically", help: "Never while you're dictating or listening.") {
                Toggle("", isOn: $settings.autoUpdate)
                    .toggleStyle(.switch)
                    .labelsHidden()
            } detail: {
                note("Orbit Flow checks every few hours. With this on, it quits, updates, and "
                    + "reopens by itself.")
            }

            Hairline()

            SettingsRow(label: "This build", help: "Signed and notarized by its developer.") {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    MetaLabel(text: "v\(Updater.currentVersion) · build \(Updater.currentBuild)")
                    updateRow
                }
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "Launch at login", help: "Starts with your Mac, hotkey already armed.") {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    if loginItem == .requiresApproval {
                        note("macOS is holding this back. Approve Orbit Flow under Login Items.")
                        ActionButton(title: "Open login items", kind: .quiet) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                    if let loginItemError { note(loginItemError) }
                }
            }

            Hairline()

            SettingsRow(label: "Microphone", help: "Needed to hear you at all.") {
                permissionControl(granted: Permissions.hasMicrophone) {
                    Permissions.openMicrophoneSettings()
                }
            }

            Hairline()

            SettingsRow(label: "Accessibility", help: "Needed to see your key and type for you.") {
                permissionControl(granted: Permissions.hasAccessibility) {
                    Permissions.openAccessibilitySettings()
                }
            }

            Hairline()

            SettingsRow(label: "Setup", help: "The four-step window you saw on first launch.") {
                ActionButton(title: "Run setup again", kind: .quiet) {
                    Settings.shared.onboardingCompleted = false
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            // A login item and a TCC grant both point at a path. ~/Library/Caches is
            // purgeable and `make run` rewrites the bundle there on every build, so a
            // copy running from it loses both — which is exactly what "it keeps asking
            // for permission" looks like from the outside.
            if !isInstalledCopy {
                Hairline()
                note("This copy is running from "
                    + "\(Bundle.main.bundleURL.deletingLastPathComponent().path), which "
                    + "macOS can delete. Run `make install` and launch it from "
                    + "Applications so the login item and the Accessibility grant stick.")
                    .padding(.vertical, DS.Space.base)
            }
        }
    }

    private func permissionControl(granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                StatusDot(color: granted ? DS.Color.positive : DS.Color.caution, isOn: true)
                MetaLabel(text: granted ? "Allowed" : "Not allowed", reserving: 11)
            }
            if !granted {
                ActionButton(title: "Open System Settings", kind: .secondary, action: open)
            }
        }
    }

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            ForEach(settings.shortcutKeys, id: \.self) { key in
                HStack {
                    Text(key.displayName)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                    Spacer()
                    if settings.shortcutKeys.count > 1 {
                        ActionButton(title: "Remove", kind: .quiet) {
                            settings.shortcutKeys = ShortcutKeys.removing(key, from: settings.shortcutKeys)
                            controller.reloadHotkey()
                        }
                    }
                }
            }

            if recorder.isRecording {
                HStack {
                    Text("Press a key or combination…")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkMuted)
                    Spacer()
                    ActionButton(title: "Cancel", kind: .quiet) { recorder.stop(resuming: controller) }
                }
                .padding(DS.Space.snug)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))

                if let problem = recorder.problem {
                    Text(problem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.caution)
                }
            } else {
                ActionButton(title: "Record shortcut", systemImage: "plus", kind: .quiet) {
                    recorder.start(pausing: controller) { key in
                        settings.shortcutKeys = ShortcutKeys.adding(key, to: settings.shortcutKeys)
                    }
                }
            }
        }
        .onDisappear { recorder.stop(resuming: controller) }
    }

    private var readAloudSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
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
                + "play is saved to History. Where an app doesn't share its selection with "
                + "macOS — web pages in Chrome, Word, Cursor and VS Code — ▶ copies the "
                + "selection to read it, then puts your clipboard back.")

            Hairline()

            Picker("Reading mode", selection: $settings.readingMode) {
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            note(settings.readingMode.summary)

            if settings.readingMode.usesAI {
                note("Sends the highlighted text to your AI provider before reading it.")
            }

            if settings.readingMode == .custom {
                TextField("Menu label", text: $settings.readingModeCustomLabel)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    "Instruction — e.g. “Rewrite this as three short takeaways.”",
                    text: $settings.readingModeCustomInstruction,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                if settings.readingModeCustomInstruction
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    note("Custom stays greyed out in the pill until this has an instruction.")
                }
            }

            if settings.readingMode.usesAI {
                Picker("AI for reading modes", selection: $settings.readAloudProviderOverride) {
                    Text("Same as AI rewrite (\(settings.aiProvider.displayName))")
                        .tag(AIProvider?.none)
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(AIProvider?.some(provider))
                    }
                }
                if let override = settings.readAloudProviderOverride {
                    TextField(
                        "Model",
                        text: $settings.readAloudModelOverride,
                        prompt: Text(override.defaultModel.isEmpty ? "Model ID" : override.defaultModel)
                    )
                    .textFieldStyle(.roundedBorder)
                    if hasOverrideKey {
                        note("A key is saved for \(override.displayName).")
                    } else {
                        // Stored under the provider, not the feature, so a key entered
                        // here is the same key AI rewrite would use if you pointed it at
                        // this provider too. Without this field the only way to store one
                        // was to repoint rewrite at it, save, and repoint back.
                        note("No key saved for \(override.displayName).")
                        HStack {
                            SecureField("Paste your \(override.displayName) key", text: $overrideKeyDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") { saveOverrideKey(override) }
                                .disabled(overrideKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Link("Get a \(override.displayName) key ↗", destination: override.keyURL)
                            .font(DS.Font.caption)
                    }
                } else {
                    note("One key covers both features. Pick OpenRouter in AI rewrite and a single key reaches every model.")
                }
            }

            Hairline()

            // The engine itself is chosen in AI Models now; each branch below only
            // configures whichever one is picked there. `VoiceEngine` has a `.kokoro`
            // case that a two-way `if` would silently fold into the `else` (ElevenLabs)
            // branch — Kokoro users would see an API key field for a model that needs
            // no key. The three-case switch makes every case's UI its own branch, so
            // adding a fourth engine later fails to compile here instead of misrouting.
            // `AIModelsSection.source(of:)` switches over the same enum to decide which
            // segment is highlighted — that one needs the same treatment too.
            switch settings.readAloudEngine {
            case .system:
                systemVoiceRows
            case .kokoro:
                kokoroVoiceRows
            case .elevenLabs:
                elevenLabsRows
            }

            Hairline()

            FieldLabel(text: "Speed", color: DS.Color.ink, emphasis: true)
            HStack(spacing: DS.Space.base) {
                speedPicker
                // `isPreparing` counts as busy too: with ElevenLabs, `speak()` returns
                // before a sound is made, and a second press during that window would
                // cancel a request already billed and send a duplicate.
                ActionButton(
                    title: speaker.isSpeaking || speaker.isPreparing ? "Stop" : "Preview",
                    kind: .secondary
                ) {
                    if speaker.isSpeaking || speaker.isPreparing {
                        speaker.stop()
                    } else {
                        speaker.speak("This is how highlighted text will sound.")
                    }
                }
                // ElevenLabs needs a key and a chosen voice before there is anything to
                // preview; Preview living below the switch now, not inside its branch,
                // means this disable has to be spelled out here instead of being implicit
                // in whether the button was even built.
                .disabled(
                    settings.readAloudEngine == .elevenLabs
                        && (!hasElevenLabsKey || settings.elevenLabsVoiceID.isEmpty)
                )
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The system-voice picker, note, and button — unchanged from before AI Models
    /// existed, just no longer gated behind an inline `if`.
    @ViewBuilder
    private var systemVoiceRows: some View {
        FieldLabel(text: "Voice", color: DS.Color.ink, emphasis: true)
        let voices = readAloudVoices
        Picker("", selection: Binding(
            // A saved voice outside the listed rows — uninstalled since, another
            // language, a novelty voice — has no row to select, and a picker with no
            // selection shows blank, so it shows as "System default". Only the
            // uninstalled one really speaks as the default.
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
    }

    /// Kokoro's ANE voice pack ships exactly one English voice today. The brief this
    /// was built from listed five ids (Heart, Bella, Michael, Emma, George); checked
    /// against the actual HuggingFace tree
    /// (`FluidInference/kokoro-82m-coreml/ANE/`), only `af_heart.bin` is there —
    /// requesting any of the other four 404s at synthesis time instead of speaking.
    /// So this shows the one id that is real rather than offering a choice that isn't
    /// one — a `Picker` with a single, permanently-selected option is a control that
    /// promises a decision it can't deliver. A plain label makes the same true statement
    /// without the promise. Turn this back into a picker when FluidInference ships more
    /// ANE voices — `af_heart` won't be the only tag by then.
    private var kokoroVoiceRows: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            FieldLabel(text: "Voice", color: DS.Color.ink, emphasis: true)
            Text("Heart (American, female)")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            note("The only voice Kokoro ships today. Downloaded with Kokoro — nothing is "
                + "sent anywhere when it speaks.")
        }
    }

    /// One speed control for both engines, mirroring the pill's menu.
    ///
    /// It replaced a pair of sliders — an `AVSpeechUtterance` rate and ElevenLabs' own
    /// `speed` — that were measured in different units, so "the same speed" on one engine
    /// was a different speed on the other. A multiple of natural pace means the same thing
    /// whichever voice is talking, and it is the only form that fits on the pill.
    private var speedPicker: some View {
        Picker("Speed", selection: $settings.readAloudSpeed) {
            ForEach(ReadingMode.speeds, id: \.self) { speed in
                Text(ReadingMode.speedLabel(speed)).tag(speed)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var elevenLabsRows: some View {
        HStack {
            SecureField("ElevenLabs API key", text: $elevenLabsKeyField)
                .textFieldStyle(.roundedBorder)
            Button("Save") { saveElevenLabsKey() }
                .disabled(elevenLabsKeyField.isEmpty)
            if hasElevenLabsKey {
                Button("Remove") { removeElevenLabsKey() }
            }
        }
        if hasElevenLabsKey {
            note("A key is saved.")
        } else {
            Link("Get an ElevenLabs key ↗",
                 destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                .font(DS.Font.caption)
        }

        HStack {
            Button("Test and load voices") { loadElevenLabs() }
                .disabled(isTestingElevenLabs || !hasElevenLabsKey)
            if isTestingElevenLabs { ProgressView().controlSize(.small) }
        }
        if let result = elevenLabsTest { resultRow(result) }

        // Both pickers show what is saved before Test has been pressed — the selection
        // persists, so a picker that hides itself until the list is fetched reads as the
        // setting having been lost. The bare id is the only name we have until then.
        if !elevenLabsVoices.isEmpty || !settings.elevenLabsVoiceID.isEmpty {
            Picker("Voice", selection: $settings.elevenLabsVoiceID) {
                Text("None").tag("")
                if !settings.elevenLabsVoiceID.isEmpty,
                   !elevenLabsVoices.contains(where: { $0.id == settings.elevenLabsVoiceID }) {
                    Text(settings.elevenLabsVoiceID).tag(settings.elevenLabsVoiceID)
                }
                ForEach(elevenLabsVoices) { voice in
                    Text(voice.category.map { "\(voice.name) (\($0))" } ?? voice.name)
                        .tag(voice.id)
                }
            }
        }
        Picker("Model", selection: $settings.elevenLabsModel) {
            if !settings.elevenLabsModel.isEmpty,
               !elevenLabsModels.contains(settings.elevenLabsModel) {
                Text(settings.elevenLabsModel).tag(settings.elevenLabsModel)
            }
            ForEach(elevenLabsModels, id: \.self) { Text($0).tag($0) }
        }
        note("Flash is the fastest and about half the credit cost.")
        // Speed and Preview live below the switch in `readAloudSection` now, shared by
        // all three engines — this used to have its own copy, which meant ElevenLabs
        // showed two of each.
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

    /// Shown when the event tap isn't live. Without this the app fails silently: the key
    /// picker still offers choices, the record button still records, and holding the key
    /// just does nothing at all with no indication why.
    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(alignment: .top, spacing: DS.Space.snug) {
                StatusDot(color: DS.Color.caution, isOn: true)
                    .padding(.top, DS.Space.tight)
                Text("The hotkey is off. macOS hasn't granted Orbit Flow accessibility access, "
                    + "so it can't see the key — and it can't type text into other apps either.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.snug) {
                ActionButton(title: "Open accessibility settings") {
                    Permissions.openAccessibilitySettings()
                }
                // The tap is created once at launch, so a grant made while the app is
                // running needs the tap rebuilt before the key does anything.
                ActionButton(title: "Try again", kind: .quiet) {
                    controller.reloadHotkey()
                }
            }
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
    }

    @ViewBuilder
    private var updateRow: some View {
        switch updater.phase {
        case .idle, .upToDate, .failed:
            if updater.phase == .upToDate { note("You're on the latest build.") }
            if case .failed(let message) = updater.phase {
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    StatusDot(color: DS.Color.signal, isOn: true)
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ActionButton(title: "Check for updates") { updater.check() }
        case .checking:
            note("Checking…")
        case .available(let build, _):
            note("Build \(build) is available. Orbit Flow will quit, update, and reopen.")
            ActionButton(title: "Install update", kind: .primary) { updater.install() }
        case .installing:
            note("Downloading and installing…")
        }
    }

    /// Registering points the login item at *this* bundle, wherever it happens to be.
    private var isInstalledCopy: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem == .enabled },
            set: { isOn in
                do {
                    loginItemError = nil
                    if isOn {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Registration fails silently otherwise: the switch springs back with no
                    // explanation, which reads as the app being broken rather than macOS
                    // refusing the bundle.
                    loginItemError = "macOS refused: \(error.localizedDescription)"
                }
                loginItem = SMAppService.mainApp.status
            }
        )
    }

    /// A cloud rewrite needs both halves. Either one missing means every call would
    /// fall back, so the UI must not present it as configured.
    private var canUseCloud: Bool { hasStoredKey && !settings.aiModel.isEmpty }

    /// What actually happens without a working cloud setup, which is not the same
    /// sentence for dictation as it is for the right-click rows. `CloudFormatter`
    /// degrades to the rule-based cleanup, because losing an utterance the user already
    /// spoke is worse than a plain one; `OnDemandRewrite` degrades to Apple's on-device
    /// model instead, because the entire point of a Services row is a rewrite, and
    /// on-device still is one. Reachable under `Always` only through the legacy-key
    /// migration — the picker itself clamps back to On demand — but that's exactly the
    /// case this note has to describe correctly rather than the common one.
    private var cloudFallbackNote: String {
        let keyStep = hasStoredKey
            ? "Press Test below to pick a model."
            : "Save an API key below to use \(settings.aiProvider.displayName)."
        if settings.aiRewriteUse == .always {
            return keyStep + " Until then, dictation falls back to the rule-based cleanup, "
                + "and the right-click rows use Apple's on-device model instead of the cloud."
        }
        return keyStep + " Until then, the right-click rows use Apple's on-device model. "
            + "Always needs both a key and a model before you can pick it — without them "
            + "it springs back to On demand."
    }

    private func refreshKeyPresence() {
        hasStoredKey = KeyStore.hasKey(account: settings.aiProvider.rawValue)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeyStore.save(key, account: settings.aiProvider.rawValue) else {
            // Do not clear the draft — the user would lose what they typed with nothing
            // stored, and the row below would claim a key is saved because the previous
            // item is still there.
            testResult = .failure("Couldn't save the key. Check that ~/Library/Application "
                + "Support/OrbitFlow is writable and try again.")
            return
        }
        keyDraft = ""
        testResult = nil
        refreshKeyPresence()
        // A key just saved here may be for the same provider the read-aloud override
        // points at — "AI for reading modes" has to notice immediately, not just when
        // its own picker changes.
        refreshElevenLabsKeyPresence()
    }

    private func removeKey() {
        KeyStore.delete(account: settings.aiProvider.rawValue)
        keyDraft = ""
        testResult = nil
        availableModels = []
        refreshKeyPresence()
        // Same reasoning as in saveKey(): the override's key-presence note reads this
        // provider's key too.
        refreshElevenLabsKeyPresence()
        // A cloud rewrite with no key for this provider falls back on every call. Don't
        // leave dictation armed for it; the on-demand rows degrade to on-device on their own.
        if settings.aiRewriteUse == .always { settings.aiRewriteUse = .onDemand }
    }

    /// Fetches the provider's model list. This is the only place a key problem is
    /// legible — everywhere else it degrades quietly to the rule pass.
    private func runTest() {
        guard let key = KeyStore.read(account: settings.aiProvider.rawValue), !key.isEmpty else {
            testResult = .failure("Save an API key first.")
            return
        }
        let provider = settings.aiProvider
        isTesting = true
        testResult = nil
        Task {
            let result: TestResult
            var ids: [String] = []
            do {
                ids = try await CloudRewriter(provider: provider, key: key).models()
                result = .success(count: ids.count)
            } catch let failure as RewriteFailure {
                result = .failure(failure.summary)
            } catch {
                result = .failure(error.localizedDescription)
            }
            isTesting = false
            // The user can switch providers while this is in flight. Results belonging to
            // a provider they are no longer looking at must not be shown under the new
            // one's name — drop them instead.
            guard provider == settings.aiProvider else { return }
            if case .success = result {
                availableModels = ids
                if settings.aiModel.isEmpty {
                    settings.aiModel = provider.defaultModel.isEmpty
                        ? (ids.first ?? "")
                        : provider.defaultModel
                }
            }
            testResult = result
        }
    }

    private func refreshElevenLabsKeyPresence() {
        hasElevenLabsKey = KeyStore.hasKey(account: Speaker.keyAccount)
        hasOverrideKey = settings.readAloudProviderOverride
            .map { KeyStore.hasKey(account: $0.rawValue) } ?? false
    }

    /// Stores a key for the provider read aloud is overridden to. Same store and same
    /// account name as `saveKey()` — this is only a second way in to the same drawer.
    private func saveOverrideKey(_ provider: AIProvider) {
        let key = overrideKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave the draft alone if the store refused it: clearing it would lose what was
        // typed while the note below still said no key was saved.
        guard !key.isEmpty, KeyStore.save(key, account: provider.rawValue) else { return }
        overrideKeyDraft = ""
        // Both flags, as saveKey() does: the override may point at the provider AI rewrite
        // is using, and that section's row must not still say the key is missing.
        refreshKeyPresence()
        refreshElevenLabsKeyPresence()
    }

    private func saveElevenLabsKey() {
        let key = elevenLabsKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeyStore.save(key, account: Speaker.keyAccount) else {
            elevenLabsTest = .failure("Couldn't save the key.")
            return
        }
        elevenLabsKeyField = ""
        refreshElevenLabsKeyPresence()
        loadElevenLabs()
    }

    private func removeElevenLabsKey() {
        KeyStore.delete(account: Speaker.keyAccount)
        elevenLabsVoices = []
        elevenLabsModels = []
        elevenLabsTest = nil
        refreshElevenLabsKeyPresence()
    }

    /// Doubles as the connection test: voices and models coming back means the key, the
    /// host and the network all work.
    private func loadElevenLabs() {
        guard let key = KeyStore.read(account: Speaker.keyAccount), !key.isEmpty else {
            elevenLabsTest = .failure("Add a key first.")
            return
        }
        isTestingElevenLabs = true
        elevenLabsTest = nil
        Task { @MainActor in
            defer { isTestingElevenLabs = false }
            do {
                let (voiceData, voiceResponse) = try await Speaker.session
                    .data(for: ElevenLabs.voicesRequest(key: key))
                if let http = voiceResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    elevenLabsTest = .failure(
                        ElevenLabs.failureMessage(from: voiceData) ?? "HTTP \(http.statusCode)"
                    )
                    return
                }
                let voices = ElevenLabs.voices(from: voiceData)
                guard !voices.isEmpty else {
                    elevenLabsTest = .failure("No voices on this account.")
                    return
                }
                elevenLabsVoices = voices
                if settings.elevenLabsVoiceID.isEmpty {
                    settings.elevenLabsVoiceID = voices[0].id
                }

                let (modelData, modelResponse) = try await Speaker.session
                    .data(for: ElevenLabs.modelsRequest(key: key))
                if let http = modelResponse as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    // The voices call above already proved the key and the account work —
                    // this failure belongs to the models endpoint alone, and must not read
                    // as the connection itself being broken.
                    elevenLabsModels = []
                    elevenLabsTest = .failure(
                        ElevenLabs.failureMessage(from: modelData)
                            ?? "Voices loaded, but the model list didn't (HTTP \(http.statusCode))."
                    )
                    return
                }
                elevenLabsModels = ElevenLabs.models(from: modelData)

                // `TestResult.success` carries a model count and `resultRow` renders it as
                // "Connected. N models available." — which is literally true here, so the
                // existing row is reused rather than given a second shape. The voice count
                // shows itself in the picker that just filled in.
                elevenLabsTest = .success(count: elevenLabsModels.count)
            } catch {
                elevenLabsTest = .failure("Couldn't reach ElevenLabs.")
            }
        }
    }

    /// Provider, key, and model. Always visible — the key has to be enterable *before*
    /// the toggle it unlocks can be switched on.
    @ViewBuilder
    private var providerControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            FieldLabel(text: "Provider", color: DS.Color.ink, emphasis: true)
            // A menu rather than a Segmented: five options do not fit the 520pt measure,
            // and this matches the Model picker directly below it. AI Models chooses the
            // *tier* (Apple/Local/Cloud) for rewrite; this is where the cloud tier's
            // *provider* is actually chosen, so it has to live here rather than there —
            // AI Models has nowhere to put a provider, key, and model for five providers.
            Picker("", selection: $settings.aiProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                FieldLabel(text: "API key")
                HStack(spacing: DS.Space.snug) {
                    SecureField("Paste your key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .padding(.horizontal, DS.Space.base)
                        .padding(.vertical, DS.Space.snug)
                        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control)
                                .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
                        )
                    ActionButton(title: "Save") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    ActionButton(title: isTesting ? "Testing…" : "Test", kind: .secondary) {
                        runTest()
                    }
                    .disabled(isTesting || !hasStoredKey)
                }

                HStack(spacing: DS.Space.snug) {
                    if hasStoredKey {
                        StatusDot(color: DS.Color.positive, isOn: true)
                        Text("A key is saved for \(settings.aiProvider.displayName).")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkMuted)
                        ActionButton(title: "Remove", kind: .quiet) { removeKey() }
                    } else {
                        Link("Get a \(settings.aiProvider.displayName) key ↗",
                             destination: settings.aiProvider.keyURL)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkMuted)
                    }
                }

                if let testResult { resultRow(testResult) }
            }

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                if availableModels.isEmpty {
                    EntryField(
                        label: "Model",
                        text: $settings.aiModel,
                        prompt: settings.aiProvider.defaultModel.isEmpty
                            ? "Press Test to load models"
                            : settings.aiProvider.defaultModel
                    )
                } else {
                    FieldLabel(text: "Model")
                    // A picker over what the provider actually serves. Free text returns
                    // whenever the list is empty, so a model our parsing missed is still
                    // reachable.
                    Picker("", selection: $settings.aiModel) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: TestResult) -> some View {
        HStack(alignment: .top, spacing: DS.Space.snug) {
            switch result {
            case .success(let count):
                StatusDot(color: DS.Color.positive, isOn: true)
                Text("Connected. \(count) model\(count == 1 ? "" : "s") available.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
            case .failure(let message):
                StatusDot(color: DS.Color.signal, isOn: true)
                // The provider's own words. A bad key should read as a bad key.
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `Slider` works in `Double`, and a range split across two lines reads as a prefix
    /// `...` to the parser, so the conversion is named rather than inlined.
    private static let historyLimitBounds =
        Double(Settings.historyLimitRange.lowerBound)...Double(Settings.historyLimitRange.upperBound)

    /// The limit slider. Its own row because a slider and its readout don't fit beside a
    /// switch at this column width, and because it only exists while auto-delete is on.
    private var historyLimitRow: some View {
        SettingsRow(
            label: "Keep newest",
            help: "How many dictations to hold on to."
        ) {
            HStack(spacing: DS.Space.base) {
                Slider(
                    value: Binding(
                        get: { Double(settings.historyLimit) },
                        // Rounded here rather than with `step:`, which would draw 390 tick
                        // marks under the track — they merge into one solid line.
                        set: { settings.historyLimit = Self.roundedLimit($0) }
                    ),
                    in: Self.historyLimitBounds
                ) { editing in
                    // On commit only. Trimming on every frame of a drag would rewrite the
                    // whole log a hundred times on the way to the number you wanted.
                    if !editing { RunLog.enforceRetention() }
                }
                .tint(DS.Color.ink)
                .frame(maxWidth: 260)

                MetaLabel(
                    text: "\(settings.historyLimit) dictations",
                    color: DS.Color.ink,
                    reserving: 15
                )
            }
        } detail: {
            note("Counted from the newest. Once history passes this, the oldest are deleted "
                + "as each new dictation arrives.")
        }
    }

    /// The window slider. Eight stops rather than a free run of days: the presets are the
    /// windows anyone actually wants, and a linear day slider would bury everything from a
    /// week to three months in the first tenth of its travel.
    ///
    /// It slides over *indices* into the presets, which is what makes the stops evenly
    /// spaced on screen while the values they carry keep doubling.
    private var historyDaysRow: some View {
        SettingsRow(
            label: "Keep for",
            help: "How far back history reaches."
        ) {
            HStack(spacing: DS.Space.base) {
                Slider(
                    value: Binding(
                        get: { Double(Self.presetIndex(of: settings.historyDays)) },
                        set: { settings.historyDays = Self.preset(at: Int($0.rounded())) }
                    ),
                    in: 0...Double(RetentionRule.dayPresets.count - 1),
                    step: 1
                ) { editing in
                    if !editing { RunLog.enforceRetention() }
                }
                .tint(DS.Color.ink)
                .frame(maxWidth: 260)

                MetaLabel(
                    text: RetentionRule.dayLabel(settings.historyDays),
                    color: DS.Color.ink,
                    reserving: 8
                )
            }
        } detail: {
            note("Counted from when each dictation was recorded. Anything older than the "
                + "window is deleted as each new dictation arrives.")
        }
    }

    /// Nearest multiple of the step, clamped to the slider's own bounds so a drag to the
    /// end lands on 2000 rather than on 1998.
    private static func roundedLimit(_ value: Double) -> Int {
        let step = Double(Settings.historyLimitStep)
        let rounded = Int((value / step).rounded() * step)
        return min(max(rounded, Settings.historyLimitRange.lowerBound),
                   Settings.historyLimitRange.upperBound)
    }

    /// Where a stored window sits on the slider. A value that isn't a preset — an older
    /// build's, or a hand-edited default — takes the nearest stop rather than snapping to
    /// the start and quietly shortening the user's window.
    private static func presetIndex(of days: Int) -> Int {
        let presets = RetentionRule.dayPresets
        let nearest = presets.enumerated().min {
            abs($0.element - days) < abs($1.element - days)
        }
        return nearest?.offset ?? 0
    }

    private static func preset(at index: Int) -> Int {
        let presets = RetentionRule.dayPresets
        return presets[min(max(index, 0), presets.count - 1)]
    }

    /// Switching modes trims immediately against the new rule — a setting that waits until
    /// the next dictation to mean anything is worse than one that bites.
    private var historyModeBinding: Binding<HistoryRetentionMode> {
        Binding(
            get: { settings.historyMode },
            set: { mode in
                settings.historyMode = mode
                if mode != .off { RunLog.enforceRetention() }
            }
        )
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The standard ⌘, window. Kept alongside the Settings tab because macOS users reach for
/// ⌘, without looking, and it costs one wrapper.
struct SettingsWindow: View {
    @Bindable var controller: DictationController

    var body: some View {
        SettingsPanel(controller: controller)
            .frame(width: 860, height: 600)
            .background(DS.Color.canvas)
    }
}

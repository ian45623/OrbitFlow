import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import OrbitFlowAIRewrite
import OrbitFlowHotkey

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

    /// Shared, so a download started from the menu bar — or by a first dictation —
    /// shows up here too.
    @State private var parakeet = ParakeetDownload.shared
    @State private var updater = Updater.shared
    @State private var isConfirmingRemove = false

    /// Shortcut recording: the local key monitor while it's live, the modifier pressed on
    /// its own so far (committed on release unless a key joins it), and why the last
    /// attempt was refused.
    @State private var recordMonitor: Any?
    @State private var pendingModifier: Int64?
    @State private var recordProblem: String?

    /// `SMAppService` is the store for this — there is no mirrored bool in `Settings`,
    /// so the switch can never disagree with System Settings ▸ General ▸ Login Items.
    /// Held in state only so the toggle redraws; re-read after every change.
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemError: String?

    private enum TestResult: Equatable {
        case success(count: Int)
        case failure(String)
    }

    /// Settings read as a column, not a page. Capped so the tab in an 860pt window and the
    /// 520pt ⌘, window lay out identically instead of one stretching into a banner.
    private let measure: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                group("Shortcut keys") {
                    if !controller.isHotkeyArmed { accessibilityNotice }

                    shortcutList

                    note("Tap a shortcut to start dictating and tap it again to stop — the text "
                        + "lands wherever your cursor is. Or hold it down and let go, if you'd "
                        + "rather not think about stopping.")
                    note("The record button works regardless of what's focused, so you can still "
                        + "record without touching the key.")
                    note("A shortcut can be a modifier on its own, like Right ⌥ or fn, or a "
                        + "combination like ⌃⌥Space. If a lone modifier turns out to be part of "
                        + "another shortcut, like ⌘ in ⌘C, the recording it started is thrown away.")
                }

                group("Model") {
                    Segmented(
                        options: SpeechEngineChoice.allCases.map {
                            ($0, $0 == .apple ? "Apple" : "Parakeet")
                        },
                        selection: $settings.engine
                    )
                    note(settings.engine == .apple
                        ? "Apple's on-device transcriber. Streams text while you speak, and needs no download."
                        : "Parakeet on the Neural Engine. Resolves when you let go, and is more accurate on English.")
                    if settings.engine == .parakeet { parakeetModelRow }
                }

                group("Dictation pill") {
                    Segmented(
                        options: HUDSize.allCases.map { ($0, $0.displayName) },
                        selection: $settings.hudSize
                    )
                    note(settings.hudSize == .compact
                        ? "Just the level trace, discard, and confirm."
                        : "Adds the transcript as it resolves, so you can read it before it lands.")
                    note("Either way: ✓ stops and pastes, ✕ throws the recording away, and "
                        + "Escape does the same as ✕ without reaching for the mouse. "
                        + "Takes effect on your next dictation.")
                }

                readAloudGroup

                group("Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Text("Clean up transcripts")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers and fixes spacing and punctuation. Dictionary corrections "
                        + "run either way.")

                    Hairline()

                    FieldLabel(text: "AI rewrite", color: DS.Color.ink, emphasis: true)
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
                    note(settings.aiRewriteUse.summary)

                    if settings.aiRewriteUse != .off, !canUseCloud {
                        note(cloudFallbackNote)
                    }

                    if settings.aiRewriteUse == .always, !settings.cleanupEnabled {
                        note("\"Clean up transcripts\" is off, so dictation isn't being rewritten right "
                            + "now. The right-click rows still work.")
                    }

                    providerControls

                    if settings.aiRewriteUse != .off {
                        Hairline()
                        FieldLabel(text: "Mode", color: DS.Color.ink, emphasis: true)
                        Segmented(
                            options: RewriteMode.allCases.map { ($0, $0.displayName) },
                            selection: $settings.rewriteMode
                        )
                        note(settings.rewriteMode.summary
                            + " Also the mode used by right-click ▸ Services ▸ Rewrite with Orbit Flow.")
                    }
                }
                .onAppear { refreshKeyPresence() }
                .onChange(of: settings.aiProvider) {
                    // Each provider has its own key and its own model list.
                    availableModels = []
                    testResult = nil
                    keyDraft = ""
                    settings.aiModel = settings.aiProvider.defaultModel
                    refreshKeyPresence()
                    // A cloud rewrite with no key for this provider falls back on every call. Don't
                    // leave dictation armed for it; the on-demand rows degrade to on-device on their own.
                    if settings.aiRewriteUse == .always { settings.aiRewriteUse = .onDemand }
                }

                group("Launch at login") {
                    Toggle(isOn: launchAtLoginBinding) {
                        Text("Open Orbit Flow when I log in")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)

                    if loginItem == .requiresApproval {
                        note("macOS is holding this back. Approve Orbit Flow under Login Items "
                            + "and it will start with your Mac.")
                        ActionButton(title: "Open login items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } else {
                        note("Orbit Flow starts with your Mac, hotkey already armed.")
                    }

                    if let loginItemError {
                        note(loginItemError)
                    }

                    // A login item and a TCC grant both point at a path. ~/Library/Caches is
                    // purgeable and `make run` rewrites the bundle there on every build, so a
                    // copy running from it loses both — which is exactly what "it keeps asking
                    // for permission" looks like from the outside.
                    if !isInstalledCopy {
                        note("This copy is running from "
                            + "\(Bundle.main.bundleURL.deletingLastPathComponent().path), which "
                            + "macOS can delete. Run `make install` and launch it from "
                            + "Applications so the login item and the Accessibility grant stick.")
                    }
                }
                .onAppear { loginItem = SMAppService.mainApp.status }

                group("When you close the window") {
                    Text("Orbit Flow keeps running and the key stays armed. Reopen it from the menu "
                        + "bar or the Dock icon; quit from the Dock, the menu bar, or ⌘Q.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Updates") {
                    note("Version \(Updater.currentVersion) (build \(Updater.currentBuild))")
                    updateRow
                }
            }
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.wide)
        }
    }

    /// Picking Parakeet used to end in a sentence about a 470 MB download and no way to
    /// start one: the only trigger was a menu bar item you had to find, or a first dictation
    /// that stalled for minutes looking like a hang. The download belongs next to the choice
    /// that needs it, with a number attached to the waiting.
    @ViewBuilder
    private var parakeetModelRow: some View {
        switch parakeet.phase {
        case .ready:
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    StatusDot(color: DS.Color.positive, isOn: true)
                    // Says the thing the dot alone doesn't: yes, it's already here, and
                    // this much of your disk is it.
                    Text("Downloaded and ready\(parakeet.installedSize.map { " — \(byteCount($0)) on this Mac" } ?? ""). "
                        + "Nothing left to install.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ActionButton(title: "Remove model", kind: .quiet) { isConfirmingRemove = true }
                    .confirmationDialog(
                        "Remove the Parakeet model?",
                        isPresented: $isConfirmingRemove
                    ) {
                        Button("Remove", role: .destructive) { parakeet.removeFromDisk() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Frees \(parakeet.installedSize.map(byteCount) ?? "about 470 MB"). "
                            + "You can download it again from here at any time; dictation falls "
                            + "back to Apple's engine until you do.")
                    }
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
        case .working(let label, let fraction):
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.ink)
                // Named phases rather than one bar: most of the wait is the download, but
                // the compile at the end is slow and silent, and a bar parked at 100%
                // reads as a hang.
                Text("\(label)… \(Int(fraction * 100))% — this keeps going if you close "
                    + "the window. Apple's engine still works meanwhile.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
        case .missing, .failed:
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                if case .failed(let message) = parakeet.phase {
                    HStack(alignment: .top, spacing: DS.Space.snug) {
                        StatusDot(color: DS.Color.signal, isOn: true)
                        Text("The download stopped: \(message)")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Parakeet runs entirely on your Mac, so its model has to live here: "
                        + "a one-time 470 MB download. Nothing to find or install by hand — "
                        + "press the button and it fetches itself.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ActionButton(
                    title: parakeet.phase == .missing ? "Download model (470 MB)" : "Try again",
                    kind: .primary
                ) {
                    parakeet.start()
                }
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
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

            if recordMonitor != nil {
                HStack {
                    Text("Press a key or combination…")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkMuted)
                    Spacer()
                    ActionButton(title: "Cancel", kind: .quiet) { stopRecording() }
                }
                .padding(DS.Space.snug)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))

                if let recordProblem {
                    Text(recordProblem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.caution)
                }
            } else {
                ActionButton(title: "Record shortcut", systemImage: "plus", kind: .quiet) {
                    startRecording()
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    /// Captures the next key press in this window. The event tap is paused meanwhile, both
    /// so the current shortcuts don't start dictating and because the tap would swallow
    /// Right ⌥ and Right ⌘ before this monitor ever saw them.
    private func startRecording() {
        guard recordMonitor == nil else { return }
        controller.pauseHotkey()
        recordProblem = nil
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let flags = event.cgEvent?.flags else { return nil }
            let keyCode = Int64(event.keyCode)

            if event.type == .flagsChanged {
                let key = Shortcut(keyCode: keyCode)
                // Caps Lock has no hold state to read; commit it so the refusal shows.
                guard let flag = key.deviceFlag else {
                    commit(key)
                    return nil
                }
                if flags.contains(flag) {
                    pendingModifier = keyCode
                } else if pendingModifier == keyCode {
                    commit(key)
                }
                return nil
            }

            pendingModifier = nil
            if keyCode == Int64(kVK_Escape), flags.intersection(Shortcut.modifierMask).isEmpty {
                stopRecording()
                return nil
            }
            commit(Shortcut(keyCode: keyCode, modifiers: flags, characters: event.charactersIgnoringModifiers))
            return nil
        }
    }

    private func commit(_ key: Shortcut) {
        if let problem = key.problem {
            recordProblem = problem
            return
        }
        settings.shortcutKeys = ShortcutKeys.adding(key, to: settings.shortcutKeys)
        stopRecording()
    }

    private func stopRecording() {
        guard let recordMonitor else { return }
        NSEvent.removeMonitor(recordMonitor)
        self.recordMonitor = nil
        pendingModifier = nil
        controller.reloadHotkey()
    }

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

            Picker("Voice", selection: $settings.readAloudEngine) {
                ForEach(VoiceEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if settings.readAloudEngine == .system {
                Hairline()

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
                }
            } else {
                elevenLabsRows
            }
        }
        .onAppear { refreshElevenLabsKeyPresence() }
        .onChange(of: settings.readAloudProviderOverride) { refreshElevenLabsKeyPresence() }
        .onChange(of: settings.readAloudEnabled) { _, isOn in
            if !isOn { controller.stopReadingAloud() }
            // The tap only listens for mouse-ups while the feature is on.
            controller.reloadHotkey()
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

        FieldLabel(text: "Speed", color: DS.Color.ink, emphasis: true)
        speedPicker
        // `isPreparing` counts as busy too: with ElevenLabs, `speak()` returns before a
        // sound is made, and a second press during that window would cancel a request
        // already billed and send a duplicate.
        Button(speaker.isSpeaking || speaker.isPreparing ? "Stop" : "Preview") {
            if speaker.isSpeaking || speaker.isPreparing {
                speaker.stop()
            } else {
                speaker.speak("This is how Orbit Flow will read your selection.")
            }
        }
        .disabled(!hasElevenLabsKey || settings.elevenLabsVoiceID.isEmpty)
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
            // and this matches the Model picker directly below it.
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

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func group<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                FieldLabel(text: label, color: DS.Color.ink, emphasis: true)
                content()
            }
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .frame(width: 560, height: 560)
            .background(DS.Color.canvas)
    }
}

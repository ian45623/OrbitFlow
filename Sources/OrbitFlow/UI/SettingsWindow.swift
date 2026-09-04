import SwiftUI
import OrbitFlowAIRewrite

/// The settings content, shared by the Settings tab in the main window and the standard
/// ⌘, window. One view rather than two, so the two can never drift apart.
///
/// Three decisions, each on its own surface with a line of plain English underneath saying
/// what changes. Nothing here is a preference for its own sake.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    /// Typed into, then saved to the Keychain and cleared. Never populated *from* the
    /// Keychain — the UI shows that a key exists, not what it is.
    @State private var keyDraft = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var availableModels: [String] = []

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
                group("Push to talk") {
                    if !controller.isHotkeyArmed { accessibilityNotice }

                    Segmented(
                        options: PushToTalkKey.allCases.map { ($0, $0.displayName) },
                        selection: Binding(
                            get: { settings.pushToTalkKey },
                            set: { key in
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                        )
                    )
                    note("Tap this key to start dictating and tap it again to stop — the text "
                        + "lands wherever your cursor is. Or hold it down and let go, if you'd "
                        + "rather not think about stopping.")
                    note("The record button works regardless of what's focused, so you can still "
                        + "record without touching the key.")
                    // These three are the only safe choices, and it's worth saying why rather
                    // than leaving it looking like an unfinished picker: the event tap watches
                    // modifier changes, and a dedicated right-hand modifier is the only kind
                    // that can be held down without typing anything into your document.
                    note("Right ⌥ and Right ⌘ are consumed while held. fn is passed through, so "
                        + "fn+arrow, fn+delete and the emoji picker keep working.")
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
                        : "Parakeet on the Neural Engine. Resolves when you let go; downloads a 470 MB model once.")
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

                    Toggle(isOn: aiRewriteBinding) {
                        Text("AI rewrite")
                            .font(DS.Font.body)
                            .foregroundStyle(
                                hasStoredKey && !settings.aiModel.isEmpty
                                    ? DS.Color.ink : DS.Color.inkFaint
                            )
                    }
                    .toggleStyle(.switch)
                    .disabled(!hasStoredKey || settings.aiModel.isEmpty)

                    if hasStoredKey, !settings.aiModel.isEmpty {
                        // Say plainly what turning this on does. The app's whole pitch is
                        // that it runs on your Mac; this is the one feature that doesn't.
                        note("Sends each transcript to \(settings.aiProvider.displayName) to be "
                            + "rewritten. Your text leaves this Mac.")
                    } else if !hasStoredKey {
                        note("Save an API key below to turn this on. Without one, every "
                            + "dictation would silently fall back to the rule-based pass.")
                    } else {
                        note("Press Test to pick a model. Without one, every dictation "
                            + "would silently fall back to the rule-based pass.")
                    }

                    if settings.cleanupTier == .cloud, !settings.cleanupEnabled {
                        note("\"Clean up transcripts\" is off, so nothing is being rewritten "
                            + "right now. Turn it back on to use AI rewrite.")
                    }

                    providerControls

                    if settings.cleanupTier == .cloud {
                        Hairline()
                        FieldLabel(text: "Mode", color: DS.Color.ink, emphasis: true)
                        Segmented(
                            options: RewriteMode.allCases.map { ($0, $0.displayName) },
                            selection: $settings.rewriteMode
                        )
                        note(settings.rewriteMode.summary)
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
                    // Same reasoning as removeKey: a cloud tier with no key for the
                    // selected provider falls back on every single utterance, so don't
                    // leave it armed just because it was armed for the previous one.
                    if settings.cleanupTier == .cloud, !hasStoredKey {
                        settings.cleanupTier = settings.tierBeforeCloud
                    }
                }

                group("When you close the window") {
                    Text("Orbit Flow keeps running and the key stays armed. Reopen it from the menu "
                        + "bar or the Dock icon; quit from the Dock, the menu bar, or ⌘Q.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.wide)
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

    /// The AI rewrite switch is a view over `cleanupTier`, not a second stored flag —
    /// one source of truth. Turning it off restores whatever tier was in use before.
    private var aiRewriteBinding: Binding<Bool> {
        Binding(
            get: { settings.cleanupTier == .cloud },
            set: { isOn in
                if isOn {
                    if settings.cleanupTier != .cloud {
                        settings.tierBeforeCloud = settings.cleanupTier
                    }
                    settings.cleanupTier = .cloud
                } else {
                    settings.cleanupTier = settings.tierBeforeCloud
                }
            }
        )
    }

    private func refreshKeyPresence() {
        hasStoredKey = Keychain.hasKey(account: settings.aiProvider.rawValue)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard Keychain.save(key, account: settings.aiProvider.rawValue) else {
            // Do not clear the draft — the user would lose what they typed with nothing
            // stored, and the row below would claim a key is saved because the previous
            // item is still there.
            testResult = .failure("Couldn't save the key to the Keychain. Unlock your "
                + "login keychain and try again.")
            return
        }
        keyDraft = ""
        testResult = nil
        refreshKeyPresence()
    }

    private func removeKey() {
        Keychain.delete(account: settings.aiProvider.rawValue)
        keyDraft = ""
        testResult = nil
        availableModels = []
        refreshKeyPresence()
        // A tier with no key falls back on every utterance. Don't leave it armed.
        if settings.cleanupTier == .cloud { settings.cleanupTier = settings.tierBeforeCloud }
    }

    /// Fetches the provider's model list. This is the only place a key problem is
    /// legible — everywhere else it degrades quietly to the rule pass.
    private func runTest() {
        guard let key = Keychain.read(account: settings.aiProvider.rawValue), !key.isEmpty else {
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

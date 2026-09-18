import OrbitFlowAIRewrite
import SwiftUI

/// One transcription, opened for repair and rewriting.
///
/// Two columns: **what you said on the left, what you do with it on the right.** The
/// left column is the transcript and nothing else. The right column runs from top to
/// bottom in the order you use it — the modes and the instruction field, then the
/// versions they produced, then the version you're reading.
///
/// Versions are tabs, not buttons, and that distinction is load-bearing: bordered
/// controls *do* something, underlined words are *places to look*. When both were
/// bordered, a row of modes above a row of version names read as the same control twice.
///
/// Versions swap in place, in the same spot on screen. That is what makes four rewrites
/// of one paragraph comparable at all — stacked down a page they were four screens of
/// near-identical prose, and reading them meant scrolling past the editor every time.
///
/// Rewrites are persisted as they land — clicking Back must not throw away work that cost
/// a round-trip — and nothing here overwrites the run's own text. A version leaves the
/// page by being copied.
struct TranscriptionDetail: View {
    let runID: UUID
    let onBack: () -> Void

    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var speaker = Speaker.shared
    /// The text every rewrite runs on. Loaded once; edits live here until saved.
    @State private var source = ""
    @State private var savedSource = ""
    @State private var instruction = ""
    /// Runs that haven't landed yet, newest first. Successful ones move to the stored list.
    @State private var pending: [Version] = []
    @State private var selected: UUID?
    /// The transcript is read by default and edited on request: correcting a misheard word
    /// is rare, and a text box where a paragraph should be reads as a form to fill in.
    @State private var isEditing = false
    @State private var engine: Engine = .cloud
    /// Read once rather than per redraw: this is a file read, not a property.
    @State private var hasKey = false

    private enum Engine: Hashable { case cloud, onDevice }

    /// A rewrite as the page shows it — stored or still running, they render the same.
    private struct Version: Identifiable {
        let id: UUID
        let instruction: String
        let engine: String
        var date: Date?
        var text: String?
        var failure: String?
    }

    private var run: DictationRun? { store.runs.first { $0.id == runID } }

    private var versions: [Version] {
        pending + (run?.rewrites ?? []).reversed().map {
            Version(id: $0.id, instruction: $0.instruction, engine: $0.engine, date: $0.date, text: $0.text)
        }
    }

    private var current: Version? {
        versions.first { $0.id == selected } ?? versions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.wide) {
                    transcriptSection
                    Hairline()
                    modesSection
                    if let blocked = blockedReason {
                        Text(blocked)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    versionsSection
                    dictionarySection
                }
                .padding(DS.Space.wide)
                // One column, capped at a readable measure. The two-column layout this
                // replaced assumed a full window; in a pane beside a list it made the
                // transcript — the thing you are here to read — the narrowest thing on
                // screen, and stacked every control into a clipped vertical strip.
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Color.canvas)
        // Keyed on the run: this view now *stays* on screen in Recent while the selection
        // changes under it, and a plain `.task` would only ever run for the first run shown
        // — leaving the editor holding the previous transcript, which `saveCorrection()`
        // would then write into the newly selected run.
        .task(id: runID) {
            pending = []
            selected = nil
            instruction = ""
            isEditing = false
            hasKey = KeyStore.hasKey(account: settings.aiProvider.rawValue)
            if !isCloudReady, OnDeviceRewriter.isAvailable { engine = .onDevice }
            source = run.map { $0.original ?? $0.text } ?? ""
            savedSource = source
            runRequestedRewrite()
        }
        .onChange(of: MainRoute.shared.rewriteRequest) { runRequestedRewrite() }
    }

    // MARK: - Header

    /// One line: what produced this and where it went, then the three things you do to it.
    /// Everything rarer lives behind the ⋯, so the row never wraps in a narrow pane.
    private var header: some View {
        HStack(spacing: DS.Space.snug) {
            if let run {
                MetaLabel(text: [
                    run.engine,
                    run.date.formatted(.dateTime.month().day().hour().minute()),
                    run.destinationApp.map { "landed in \($0)" },
                ].compactMap { $0 }.joined(separator: " · "))
                .layoutPriority(-1)

                Spacer(minLength: DS.Space.snug)

                ActionButton(
                    title: (run.isPinned ?? false) ? "Unpin" : "Pin",
                    kind: .secondary
                ) {
                    RunLog.modify(run.id) { $0.isPinned = !($0.isPinned ?? false) }
                }

                // Reads whatever the page is showing: the selected rewrite if there is one,
                // otherwise the transcript. Replaying doesn't file a new entry — this one is
                // already in History.
                let spoken = current?.text ?? source
                // `isPreparing` counts as busy too: with ElevenLabs, `speak()` returns
                // before a sound is made, and a second press during that window would
                // cancel a request already billed and send a duplicate.
                ActionButton(
                    title: speaker.isSpeaking || speaker.isPreparing ? "Stop" : "Read aloud",
                    kind: .secondary,
                    isEnabled: speaker.isSpeaking || speaker.isPreparing || !spoken.trimmed.isEmpty
                ) {
                    if speaker.isSpeaking || speaker.isPreparing {
                        speaker.stop()
                    } else {
                        speaker.speak(spoken)
                    }
                }

                ActionButton(title: "Copy", kind: .primary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(current?.text ?? source, forType: .string)
                }

                Menu {
                    Button("Reveal dictionary file") {
                        NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                    }
                    Divider()
                    Button("Delete this dictation", role: .destructive) {
                        RunLog.delete(run)
                        onBack()
                    }
                } label: {
                    Text("⋯")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.inkMuted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.base) {
                MetaLabel(text: "Transcript")
                ActionButton(title: isEditing ? "Done" : "Edit", kind: .quiet) {
                    if isEditing, source != savedSource { saveCorrection() }
                    withAnimation(DS.Motion.panel) { isEditing.toggle() }
                }
                if isEditing, source != savedSource {
                    ActionButton(title: "Revert", kind: .quiet) { source = savedSource }
                }
                Spacer()
                if let run {
                    MetaLabel(text: "\(wordCount) words · \(Int(run.audioSeconds.rounded()))s audio")
                }
            }

            if isEditing {
                ProseEditor(text: $source, minHeight: 140)
                Text("Fix a misheard word here, then rewrite from the corrected text.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            } else {
                Text(source)
                    .font(DS.Font.display)
                    .lineSpacing(DS.Font.proseLeading)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var wordCount: Int {
        source.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Rewriting

    /// The modes on one line, the instruction under them, and what will run it on the
    /// right — so the choice and the thing making the choice are never separated.
    private var modesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
                Flow(spacing: DS.Space.snug) {
                    ForEach(RewriteMode.allCases, id: \.self) { mode in
                        ActionButton(title: mode.displayName, kind: .secondary, isEnabled: canRun) {
                            start(mode)
                        }
                    }
                    ActionButton(title: "All modes", kind: .quiet, isEnabled: canRun) {
                        for mode in RewriteMode.allCases { start(mode) }
                    }
                }
                Spacer(minLength: DS.Space.snug)
                // Only when there's a choice to make. One engine available is not a choice.
                if isCloudReady, OnDeviceRewriter.isAvailable {
                    Segmented(
                        options: [(.cloud, "Cloud"), (.onDevice, "On-device")],
                        selection: $engine
                    )
                    .fixedSize()
                } else {
                    MetaLabel(text: engineLabel)
                }
            }

            HStack(spacing: DS.Space.snug) {
                TextField("Ask for something else — “tighten this to one line”", text: $instruction)
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
                    .onSubmit(runCustom)
                ActionButton(
                    title: "Run",
                    kind: .secondary,
                    isEnabled: canRun && !instruction.trimmed.isEmpty,
                    action: runCustom
                )
            }
        }
    }

    // MARK: - Versions

    /// Every rewrite, newest first, read straight down the column.
    ///
    /// This replaced a tab rail: with four modes and a custom instruction the tabs wrapped
    /// into three clipped rows in a pane this width, and hid every version but one behind a
    /// click. Reading them in sequence is the whole point of running more than one.
    @ViewBuilder
    private var versionsSection: some View {
        if versions.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                MetaLabel(text: "No rewrites yet")
                Text("Run a mode, or write your own instruction. Every version you run is kept here.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                ForEach(versions) { version in
                    VStack(alignment: .leading, spacing: DS.Space.snug) {
                        HStack(spacing: DS.Space.snug) {
                            Text(version.instruction)
                                .font(DS.Font.bodyEmphasis)
                                .foregroundStyle(DS.Color.ink)
                                .lineLimit(1)
                            versionMeta(version)
                            Spacer()
                            if let text = version.text { CopyButton(text: text) }
                            ActionButton(title: "Delete", kind: .quiet) { delete(version) }
                        }
                        versionBody(version)
                    }
                    .onTapGesture { selected = version.id }
                }
            }
        }
    }

    /// What produced this version and when.
    private func versionMeta(_ version: Version) -> some View {
        MetaLabel(
            text: version.date.map { "\(version.engine) · \($0.formatted(.dateTime.hour().minute()))" }
                ?? version.engine
        )
        .lineLimit(1)
    }

    @ViewBuilder
    private func versionBody(_ version: Version) -> some View {
        if let failure = version.failure {
            Text(failure)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.caution)
        } else if let text = version.text {
            Text(text)
                .font(DS.Font.prose)
                .lineSpacing(DS.Font.proseLeading)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MetaLabel(text: "Rewriting…")
        }
    }

    // MARK: - Dictionary

    /// What the dictionary changed in this transcript, which is the only place the user can
    /// see a rule actually earning its place.
    @ViewBuilder
    private var dictionarySection: some View {
        if let corrections = run?.corrections, !corrections.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                HStack {
                    MetaLabel(text: "Dictionary fired")
                    Spacer()
                    ActionButton(title: "Open in Dictionary", kind: .quiet) {
                        MainRoute.shared.section = .dictionary
                    }
                }
                Flow(spacing: DS.Space.snug) {
                    ForEach(corrections, id: \.self) { correction in
                        HStack(spacing: DS.Space.tight) {
                            Text(correction.from)
                                .strikethrough()
                                .foregroundStyle(DS.Color.inkFaint)
                            Text(correction.to)
                                .foregroundStyle(DS.Color.ink)
                            if correction.count > 1 {
                                MetaLabel(text: "×\(correction.count)")
                            }
                        }
                        .font(DS.Font.caption)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.chip))
                    }
                }
            }
        }
    }

    // MARK: - Running

    /// Whether a cloud rewrite can run from this page.
    ///
    /// Deliberately not a question about dictation. Under `onDemand` the cloud is fully
    /// configured and dictation simply doesn't use it — testing the dictation tier here
    /// would black out cloud rewrites on the page this feature routes text into.
    private var isCloudReady: Bool {
        settings.aiRewriteUse.servesOnDemand && !settings.aiModel.isEmpty && hasKey
    }

    private var canRun: Bool {
        (engine == .cloud ? isCloudReady : OnDeviceRewriter.isAvailable) && !source.trimmed.isEmpty
    }

    /// Why the buttons are dead, when they are. Silence here reads as a broken page.
    private var blockedReason: String? {
        if canRun { return nil }
        if source.trimmed.isEmpty { return "Nothing to rewrite." }
        if engine == .onDevice { return OnDeviceRewriter.unavailableReason }
        if OnDeviceRewriter.isAvailable {
            return "Cloud rewrite isn't set up. Switch to on-device, or add a key in Settings."
        }
        return "Set AI rewrite to On demand or Always in Settings, with a key and a model."
    }

    private var engineLabel: String {
        engine == .cloud
            ? "\(settings.aiProvider.displayName) · \(settings.aiModel)"
            : "Apple on-device"
    }

    private func saveCorrection() {
        let corrected = source
        RunLog.modify(runID) { run in
            // A run that was never rewritten has no separate original — its text *is* the
            // original, so the correction belongs there instead.
            if run.original == nil {
                run.text = corrected
            } else {
                run.original = corrected
            }
        }
        savedSource = corrected
    }

    private func delete(_ version: Version) {
        pending.removeAll { $0.id == version.id }
        RunLog.modify(runID) { $0.rewrites?.removeAll { $0.id == version.id } }
        if selected == version.id { selected = nil }
    }

    private func runCustom() {
        let typed = instruction.trimmed
        guard canRun, !typed.isEmpty else { return }
        // No guard: an instruction like "make this three bullets" blows the length band by
        // design, and unlike dictation nothing here is typed into another app — the user
        // reads the result and decides whether to copy it.
        start(label: typed, system: RewriteMode.customSystemPrompt(typed), checking: nil)
    }

    /// ⌘⌥R in Recent asks for a rewrite without opening the page first. Consumed once —
    /// leaving it set would rerun on every redraw.
    private func runRequestedRewrite() {
        guard MainRoute.shared.rewriteRequest == runID else { return }
        MainRoute.shared.rewriteRequest = nil
        start(settings.rewriteMode)
    }

    private func start(_ mode: RewriteMode) {
        start(label: mode.displayName, system: mode.systemPrompt, checking: mode)
    }

    private func start(label: String, system: String, checking mode: RewriteMode?) {
        let text = source.trimmed
        guard canRun, !text.isEmpty else { return }

        let item = Version(id: UUID(), instruction: label, engine: engineLabel)
        pending.insert(item, at: 0)
        // Reading a version you didn't ask for is worse than reading nothing, so a running
        // rewrite takes the pane only when nothing has been chosen yet.
        if selected == nil || versions.count == 1 { selected = item.id }

        let engine = self.engine
        let provider = settings.aiProvider
        let model = settings.aiModel
        let key = engine == .cloud ? (KeyStore.read(account: provider.rawValue) ?? "") : ""
        let engineLabel = self.engineLabel

        Task {
            do {
                let output: String
                // Both timeouts are far longer than dictation's. There's no utterance
                // waiting to be pasted here, so waiting beats a failure the user has to
                // repeat by hand.
                if engine == .cloud {
                    output = try await CloudRewriter(
                        provider: provider, key: key, timeout: .seconds(45)
                    ).rewrite(text, model: model, system: system, checking: mode)
                } else {
                    output = try await OnDeviceRewriter.rewrite(
                        text, system: system, timeout: .seconds(60)
                    )
                }
                let stored = Rewrite(
                    date: Date(),
                    instruction: label,
                    engine: engineLabel,
                    source: text,
                    text: output
                )
                RunLog.modify(runID) { $0.rewrites = ($0.rewrites ?? []) + [stored] }
                // Follow the selection across: the chip the user is looking at is this run.
                if selected == item.id { selected = stored.id }
                pending.removeAll { $0.id == item.id }
            } catch {
                let reason = (error as? RewriteFailure)?.summary ?? OnDeviceRewriter.describe(error)
                if let index = pending.firstIndex(where: { $0.id == item.id }) {
                    pending[index].failure = reason
                }
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

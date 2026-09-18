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

    /// One thing to read: what was said, what landed, or a rewrite of either.
    ///
    /// The pane is a stack of these. They all have the same shape — a label saying what this
    /// version *is*, what produced it, and the text — because that is the question being
    /// asked every time: which of these do I want, and where did it come from.
    private struct Entry: Identifiable {
        enum Kind {
            /// The engine's own words, before anything touched them.
            case spoken
            /// The cleanup pass — what actually landed in the other app.
            case landed
            case rewrite
        }

        let id: UUID
        let kind: Kind
        /// What this version is: "What you said", "Cleaned up", or the mode that made it.
        let label: String
        /// What produced it, and when.
        let engine: String
        var date: Date?
        var text: String?
        var failure: String?
    }

    /// Newest first, with the original at the bottom: a rewrite is read against the thing it
    /// came from, and the thing it came from doesn't move.
    private var entries: [Entry] {
        var entries: [Entry] = versions.map {
            Entry(
                id: $0.id,
                kind: .rewrite,
                label: $0.instruction,
                engine: $0.engine,
                date: $0.date,
                text: $0.text,
                failure: $0.failure
            )
        }

        if let run {
            // Only when cleanup actually changed something: `original` is kept exactly then,
            // and an identical pair of entries would say the pass had done work it hadn't.
            if run.original != nil {
                entries.append(
                    Entry(
                        id: landedID,
                        kind: .landed,
                        label: "Cleaned up",
                        engine: "This is what landed",
                        date: run.date,
                        text: run.text
                    )
                )
            }
            entries.append(
                Entry(
                    id: spokenID,
                    kind: .spoken,
                    label: "What you said",
                    engine: "\(run.engine) · \(Int(run.audioSeconds.rounded()))s audio",
                    date: run.date,
                    text: source
                )
            )
        }
        return entries
    }

    /// Stable ids for the two entries that aren't rewrites, so selection survives redraws.
    private var spokenID: UUID { runID }
    private var landedID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? runID
    }

    /// The text the next rewrite runs on: whichever entry is selected, and the landed text
    /// by default. Rewriting a rewrite is the point of selecting one.
    private var sourceText: String {
        entries.first { $0.id == selected }?.text ?? run?.text ?? source
    }

    private var sourceLabel: String {
        entries.first { $0.id == selected }?.label ?? (run?.original != nil ? "Cleaned up" : "What you said")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.base) {
                    ForEach(entries) { entry in
                        entryCard(entry)
                    }
                    dictionarySection
                }
                .padding(DS.Space.base)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .background(DS.Color.canvas)
        // Keyed on the run: this view stays on screen in Recent while the selection changes
        // under it, and a plain `.task` would only ever run for the first run shown —
        // leaving the editor holding the previous transcript, which `saveCorrection()` would
        // then write into the newly selected run.
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

    /// One line: what produced this dictation and when, then the three things you do to it.
    /// Everything rarer lives behind the ⋯, so the row never wraps in a narrow pane.
    private var header: some View {
        HStack(spacing: DS.Space.snug) {
            if let run {
                MetaLabel(text: "\(run.engine) · \(run.date.formatted(.dateTime.month().day().hour().minute()))")
                    .layoutPriority(-1)

                Spacer(minLength: DS.Space.snug)

                let isPinned = run.isPinned ?? false
                IconButton(
                    systemImage: isPinned ? "pin.fill" : "pin",
                    label: isPinned ? "Unpin this dictation" : "Pin this dictation",
                    isOn: isPinned
                ) {
                    RunLog.modify(run.id) { $0.isPinned = !($0.isPinned ?? false) }
                }

                // Reads whatever is selected, or the landed text. Replaying doesn't file a
                // new entry — this one is already in History.
                let spoken = sourceText
                // `isPreparing` counts as busy too: with ElevenLabs, `speak()` returns
                // before a sound is made, and a second press during that window would
                // cancel a request already billed and send a duplicate.
                let isSpeaking = speaker.isSpeaking || speaker.isPreparing
                IconButton(
                    systemImage: isSpeaking ? "stop.fill" : "play.fill",
                    label: isSpeaking ? "Stop reading" : "Read this aloud",
                    isOn: isSpeaking,
                    isEnabled: isSpeaking || !spoken.trimmed.isEmpty
                ) {
                    if isSpeaking {
                        speaker.stop()
                    } else {
                        speaker.speak(spoken)
                    }
                }

                IconButton(systemImage: "doc.on.doc", label: "Copy to the clipboard") {
                    copy(sourceText)
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

    // MARK: - Entries

    /// Every version reads the same way, whatever made it: a label, what produced it, its
    /// own copy button, and the text. Clicking one aims the composer at it.
    @ViewBuilder
    private func entryCard(_ entry: Entry) -> some View {
        let isSource = selected == entry.id || (selected == nil && isDefaultSource(entry))

        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Text(entry.label)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                MetaLabel(text: entry.date.map { "\(entry.engine) · \($0.formatted(.dateTime.hour().minute()))" } ?? entry.engine)
                    .lineLimit(1)
                    .layoutPriority(-1)

                Spacer(minLength: DS.Space.snug)

                if isSource {
                    MetaLabel(text: "Rewriting from this")
                }
                if entry.kind == .spoken {
                    ActionButton(title: isEditing ? "Done" : "Edit", kind: .quiet) {
                        if isEditing, source != savedSource { saveCorrection() }
                        withAnimation(DS.Motion.panel) { isEditing.toggle() }
                    }
                }
                if let text = entry.text {
                    IconButton(systemImage: "doc.on.doc", label: "Copy this version") { copy(text) }
                }
                if entry.kind == .rewrite {
                    IconButton(systemImage: "trash", label: "Delete this rewrite") {
                        delete(Version(id: entry.id, instruction: entry.label, engine: entry.engine))
                    }
                }
            }

            if entry.kind == .spoken, isEditing {
                ProseEditor(text: $source, minHeight: 120)
                Text("Fix a misheard word here, then rewrite from the corrected text.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            } else if let failure = entry.failure {
                Text(failure)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.caution)
            } else if let text = entry.text {
                Text(text)
                    .font(entry.kind == .rewrite ? DS.Font.prose : DS.Font.display)
                    .lineSpacing(DS.Font.proseLeading)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MetaLabel(text: "Rewriting…")
            }
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(entry.kind == .rewrite ? DS.Color.surface : DS.Color.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(
                    isSource ? DS.Color.ink : DS.Color.line,
                    lineWidth: isSource ? DS.Border.emphasis : DS.Border.hairline
                )
        )
        .contentShape(.rect)
        .onTapGesture { withAnimation(DS.Motion.press) { selected = entry.id } }
    }

    /// With nothing chosen, a rewrite runs on what landed — the text that actually reached
    /// the other app — falling back to the transcript when cleanup changed nothing.
    private func isDefaultSource(_ entry: Entry) -> Bool {
        run?.original != nil ? entry.kind == .landed : entry.kind == .spoken
    }

    // MARK: - Composer

    /// Pinned to the bottom, like the place you type in any conversation: the modes, a free
    /// instruction, and a line saying which version the next run will read from.
    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
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
                    kind: .primary,
                    isEnabled: canRun && !instruction.trimmed.isEmpty,
                    action: runCustom
                )
            }

            if let blocked = blockedReason {
                Text(blocked)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.caution)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MetaLabel(text: "Rewriting from: \(sourceLabel)")
            }
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Hairline() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            .padding(.horizontal, DS.Space.base)
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
        (engine == .cloud ? isCloudReady : OnDeviceRewriter.isAvailable) && !sourceText.trimmed.isEmpty
    }

    /// Why the buttons are dead, when they are. Silence here reads as a broken page.
    private var blockedReason: String? {
        if canRun { return nil }
        if sourceText.trimmed.isEmpty { return "Nothing to rewrite." }
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
        let text = sourceText.trimmed
        guard canRun, !text.isEmpty else { return }

        let item = Version(id: UUID(), instruction: label, engine: engineLabel)
        pending.insert(item, at: 0)

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
                // Follow the selection across, so a rewrite of a rewrite keeps aiming at
                // the version the user was reading.
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

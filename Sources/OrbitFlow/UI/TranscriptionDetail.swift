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
    /// The text every rewrite runs on. Loaded once; edits live here until saved.
    @State private var source = ""
    @State private var savedSource = ""
    @State private var instruction = ""
    /// Runs that haven't landed yet, newest first. Successful ones move to the stored list.
    @State private var pending: [Version] = []
    @State private var selected: UUID?
    /// Read all versions in one scroll instead of one at a time.
    @State private var isComparing = false
    @State private var engine: Engine = .cloud
    /// Read once rather than per redraw: this is a Keychain query, not a property.
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
            Divider()
            HStack(spacing: 0) {
                sourceColumn
                    .frame(width: 320)
                Divider()
                versionColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .background(DS.Color.canvas)
        .task {
            hasKey = Keychain.hasKey(account: settings.aiProvider.rawValue)
            if !isCloudReady, OnDeviceRewriter.isAvailable { engine = .onDevice }
            source = run.map { $0.original ?? $0.text } ?? ""
            savedSource = source
        }
    }

    // MARK: - Header

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
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.tight)
        .background(DS.Color.surface)
    }

    // MARK: - Left: the transcript and the controls

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(spacing: DS.Space.snug) {
                Text("What you said")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkMuted)
                Spacer()
                if source != savedSource {
                    ActionButton(title: "Revert", kind: .quiet) { source = savedSource }
                    ActionButton(title: "Save", kind: .quiet, action: saveCorrection)
                } else {
                    CopyButton(text: source)
                }
            }
            ProseEditor(text: $source, minHeight: 120)
                .frame(maxHeight: .infinity)
            Text("Fix a misheard word here, then rewrite from the corrected text.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkFaint)
        }
        .padding(DS.Space.base)
    }

    // MARK: - Right: the versions

    private var versionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            if versions.isEmpty {
                empty
            } else {
                rail
                Divider()
                reader
            }
        }
    }

    /// Everything that starts a rewrite, in one block at the top of the column.
    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Flow {
                ActionButton(title: "All modes", kind: .primary, isEnabled: canRun) {
                    for mode in RewriteMode.allCases { start(mode) }
                }
                ForEach(RewriteMode.allCases, id: \.self) { mode in
                    ActionButton(title: mode.displayName, kind: .secondary, isEnabled: canRun) {
                        start(mode)
                    }
                }
            }

            HStack(spacing: DS.Space.snug) {
                TextField("Or write an instruction — turn this into short bullet points", text: $instruction)
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
                // Only when there's a choice to make. One engine available is not a choice.
                if isCloudReady, OnDeviceRewriter.isAvailable {
                    Segmented(
                        options: [(.cloud, "Cloud"), (.onDevice, "On-device")],
                        selection: $engine
                    )
                    .fixedSize()
                }
            }

            if let blocked = blockedReason {
                Text(blocked)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.caution)
            }
        }
        .padding(DS.Space.base)
    }

    private var empty: some View {
        VStack(spacing: DS.Space.snug) {
            Text("No rewrites yet")
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.ink)
            Text("Run a mode, or write your own instruction.\nEvery version you run is kept here.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var reader: some View {
        if isComparing {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.wide) {
                    ForEach(versions) { version in
                        VStack(alignment: .leading, spacing: DS.Space.snug) {
                            HStack(spacing: DS.Space.snug) {
                                Text(version.instruction)
                                    .font(DS.Font.bodyEmphasis)
                                    .foregroundStyle(DS.Color.ink)
                                    .lineLimit(1)
                                versionMeta(version)
                            }
                            versionBody(version)
                        }
                    }
                }
                .padding(DS.Space.base)
            }
        } else if let current {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    versionMeta(current)
                    Spacer()
                    if let text = current.text { CopyButton(text: text) }
                    ActionButton(title: "Delete", kind: .quiet) { delete(current) }
                }
                ScrollView {
                    versionBody(current)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DS.Space.base)
        }
    }

    /// What produced this version and when. The name is on its tab, so it isn't repeated.
    private func versionMeta(_ version: Version) -> some View {
        HStack(spacing: DS.Space.snug) {
            Text(version.date.map { "\(version.engine) · \($0.formatted(.dateTime.hour().minute()))" } ?? version.engine)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkFaint)
                .lineLimit(1)
            if isComparing, let text = version.text {
                Spacer()
                CopyButton(text: text)
                ActionButton(title: "Delete", kind: .quiet) { delete(version) }
            }
        }
    }

    /// Every version, newest first. A word with a rule under it — the same idiom as the
    /// window's own tabs, because that is what these are: places to look, not actions.
    private var rail: some View {
        HStack(alignment: .center, spacing: DS.Space.snug) {
            Flow(spacing: DS.Space.roomy, lineSpacing: DS.Space.tight) {
                ForEach(versions) { version in
                    versionTab(version)
                }
            }
            Spacer(minLength: 0)
            if versions.count > 1 {
                ActionButton(title: isComparing ? "One at a time" : "Compare all", kind: .quiet) {
                    withAnimation(DS.Motion.panel) { isComparing.toggle() }
                }
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.top, DS.Space.snug)
        .background(DS.Color.surface)
    }

    private func versionTab(_ version: Version) -> some View {
        let isCurrent = !isComparing && current?.id == version.id
        let tint = version.failure == nil
            ? (isCurrent ? DS.Color.ink : DS.Color.inkFaint)
            : DS.Color.caution
        return Button {
            withAnimation(DS.Motion.press) {
                isComparing = false
                selected = version.id
            }
        } label: {
            VStack(spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.tight) {
                    if version.text == nil, version.failure == nil {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                    }
                    Text(version.instruction)
                        .font(DS.Font.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(tint)
                }
                .frame(maxWidth: 180)
                Rectangle()
                    .fill(isCurrent ? DS.Color.ink : Color.clear)
                    .frame(height: DS.Border.emphasis)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(version.date.map { "\(version.engine) · \($0.formatted(.dateTime.hour().minute()))" } ?? version.engine)
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
                .frame(maxWidth: DS.Font.proseMeasure, alignment: .leading)
        } else {
            Text("Rewriting…")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkFaint)
        }
    }

    // MARK: - Running

    private var isCloudReady: Bool {
        settings.cleanupEnabled
            && settings.cleanupTier == .cloud
            && !settings.aiModel.isEmpty
            && hasKey
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
        return "Turn on AI rewrite in Settings, with a key and a model, to rewrite from here."
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
        let key = engine == .cloud ? (Keychain.read(account: provider.rawValue) ?? "") : ""
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

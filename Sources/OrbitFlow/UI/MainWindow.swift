import OrbitFlowDictionary
import AppKit
import SwiftUI

/// The app's main window.
///
/// Almost all of the work happens somewhere else — you hold a key in another app and text
/// appears there. So this window is a reading surface: what was said, and what the app has
/// been taught. One quiet header holds the two sections and the record control; everything
/// below it is content.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var section: Section = .transcriptions

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcriptions: "Transcriptions"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(controller: controller, section: $section)

            switch section {
            case .transcriptions: TranscriptionList()
            case .dictionary: DictionaryPanel()
            case .settings: SettingsPanel(controller: controller)
            }
        }
        .background(DS.Color.canvas)
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - Header

/// Sections on the left, recording on the right. The only control in the window that does
/// something irreversible-feeling gets the accent; nothing else competes with it.
private struct Header: View {
    @Bindable var controller: DictationController
    @Binding var section: MainWindow.Section

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.wide) {
            HStack(spacing: DS.Space.roomy) {
                ForEach(MainWindow.Section.allCases) { candidate in
                    tab(candidate)
                }
            }

            Spacer()

            if !controller.isHotkeyArmed {
                Button {
                    withAnimation(DS.Motion.panel) { section = .settings }
                } label: {
                    HStack(spacing: DS.Space.tight) {
                        StatusDot(color: DS.Color.caution, isOn: true)
                        Text("Hotkey off")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                .help("Orbit Flow can't see the push-to-talk key. Open Settings to fix it.")
            }

            Waveform(level: controller.level, isActive: isRecording, color: DS.Color.inkMuted)
                .frame(width: 96, height: 20)

            // Fixed width so the header doesn't shift as the digits tick over, and blank
            // rather than 00:00 at rest — a stopped clock is noise.
            Numeral(text: isRecording ? counterText : "", large: true, color: DS.Color.ink)
                .frame(width: 48, alignment: .trailing)

            RecordButton(isRecording: isRecording) {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            }
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.base)
        .background(DS.Color.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// A word with a rule under it. A segmented control here would read as a form field,
    /// and these are places in the app rather than a setting.
    private func tab(_ candidate: MainWindow.Section) -> some View {
        let isActive = section == candidate
        return Button {
            withAnimation(DS.Motion.panel) { section = candidate }
        } label: {
            VStack(spacing: DS.Space.tight) {
                Text(candidate.title)
                    .font(DS.Font.title)
                    .foregroundStyle(isActive ? DS.Color.ink : DS.Color.inkFaint)
                Rectangle()
                    .fill(isActive ? DS.Color.ink : Color.clear)
                    .frame(height: DS.Border.emphasis)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transcriptions

/// Everything that's been dictated, newest first, searchable, each copyable.
private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, placeholder: "Search transcriptions")
                .padding(.horizontal, DS.Space.wide)
                .padding(.vertical, DS.Space.base)

            Hairline()

            if runs.isEmpty {
                EmptyPanel(
                    label: store.runs.isEmpty ? "Nothing dictated yet" : "No matches",
                    detail: store.runs.isEmpty
                        ? "Hold \(settings.pushToTalkKey.displayName) and talk, or press record above. What you say lands here."
                        : "Nothing recorded contains “\(query)”."
                )
            } else {
                ScrollView {
                    // Rows are separated, not boxed: a transcript history reads as one
                    // document, and a stack of cards would fight the prose inside them.
                    LazyVStack(spacing: 0) {
                        ForEach(runs) { run in
                            TranscriptionRow(run: run) {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            }
                            if run.id != runs.last?.id { Hairline() }
                        }
                    }
                }
                footer
            }
        }
    }

    private var footer: some View {
        HStack {
            FieldLabel(
                text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")",
                color: DS.Color.inkFaint
            )
            Spacer()
            ActionButton(title: "Delete all", kind: .quiet) { isConfirmingClear = true }
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Hairline() }
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Text(run.engine)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
                Numeral(text: String(format: "%.2fs", run.processSeconds), color: DS.Color.inkFaint)

                Spacer()

                if isHovering {
                    ActionButton(title: didCopy ? "Copied" : "Copy", kind: .quiet, action: copy)
                    ActionButton(title: "Delete", kind: .quiet, action: onDelete)
                } else {
                    Text(run.date, style: .time)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkFaint)
                }
            }

            // The transcript is the content of this app, so it is set as prose: serif,
            // extra leading, and a measure short enough to read comfortably.
            Text(run.text)
                .font(DS.Font.prose)
                .lineSpacing(DS.Font.proseLeading)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Font.proseMeasure, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? DS.Color.surfaceHover : DS.Color.canvas)
        .onHover { isHovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
private struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            FieldLabel(text: "Corrected", color: DS.Color.inkFaint)
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.tight) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.inkFaint)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DS.Color.inkFaint)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.inkMuted)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.inkFaint)
                    }
                }
                .font(DS.Font.caption)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.hair)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
                )
            }
            Spacer()
        }
    }
}

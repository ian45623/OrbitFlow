import OrbitFlowDictionary
import OrbitFlowHotkey
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

    /// Which tab is showing lives on `MainRoute` now, not private `@State` — the Services
    /// menu's "Open in Orbit Flow" has to be able to force this window onto Transcriptions
    /// from outside the view, and `@State` can't be reached from there.
    @Bindable private var route = MainRoute.shared

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcriptions: "Recent"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(controller: controller, section: $route.section)

            switch route.section {
            case .transcriptions: RecentPane()
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
                        MetaLabel(text: "Hotkey off", color: DS.Color.caution)
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

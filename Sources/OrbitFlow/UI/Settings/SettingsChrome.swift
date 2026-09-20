import SwiftUI
import OrbitFlowStats

/// The eight places a setting can live.
///
/// Named for what someone is trying to change, not for the subsystem that implements it —
/// "Cleanup & AI" rather than "Formatting", because the question people arrive with is
/// "why is it rewording me", not "which formatter ran".
enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation, aiModels, cleanupAI, readAloud, dictionary, history, updates, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .aiModels: "AI Models"
        case .cleanupAI: "Cleanup & AI"
        case .readAloud: "Read aloud"
        case .dictionary: "Dictionary"
        case .history: "History & privacy"
        case .updates: "Updates"
        case .general: "General"
        }
    }

    /// One line under the section title. What this section is *for*, so the rows below can
    /// stop explaining themselves (rule 04).
    var summary: String {
        switch self {
        case .dictation: "How you start talking, and what lands in the other app."
        case .aiModels: "Which model does each job, and whether it runs on this Mac."
        case .cleanupAI: "What happens to the words before they land."
        case .readAloud: "Having text read back to you."
        case .dictionary: "Words this Mac keeps getting wrong."
        case .history: "What's kept, where it lives, and how to clear it."
        case .updates: "How new builds arrive."
        case .general: "Launching, permissions, and setup."
        }
    }
}

/// The section list, with a live footer: the two permissions and the build.
///
/// The footer is here rather than in General because a permission that has come undone is
/// the single most common reason the app looks broken, and the sidebar is the one thing on
/// screen in every section.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let badges: [SettingsSection: String]
    let hasMicrophone: Bool
    let hasAccessibility: Bool
    let versionLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaLabel(text: "Settings")
                .padding(.horizontal, DS.Space.roomy)
                .padding(.vertical, DS.Space.base)

            ForEach(SettingsSection.allCases) { section in
                row(section)
            }

            Spacer()

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                permission("Microphone", granted: hasMicrophone)
                permission("Accessibility", granted: hasAccessibility)
                MetaLabel(text: versionLine)
            }
            .padding(DS.Space.roomy)
        }
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Color.surface)
    }

    private func row(_ section: SettingsSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(section.title)
                    .font(section == selection ? DS.Font.bodyEmphasis : DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                Spacer(minLength: DS.Space.tight)
                if let badge = badges[section] {
                    MetaLabel(text: badge)
                }
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(section == selection ? DS.Color.surfaceHover : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.snug)
    }

    private func permission(_ name: String, granted: Bool) -> some View {
        HStack(spacing: DS.Space.snug) {
            StatusDot(color: granted ? DS.Color.positive : DS.Color.caution, isOn: true)
            // The dot says it in colour, the label says it in words: hue never carries
            // state on its own (rule 01).
            MetaLabel(text: granted ? name : "\(name) off", color: granted ? DS.Color.inkFaint : DS.Color.caution)
        }
    }
}

/// One setting: what it is, one line about it, and the control. Longer explanation folds
/// behind the "?" rather than being deleted — the prose was right, it just shouldn't be a
/// wall you read to find a switch.
struct SettingsRow<Control: View, Detail: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var control: () -> Control
    @ViewBuilder var detail: () -> Detail

    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.roomy) {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(label)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    if let help {
                        Text(help)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 210, alignment: .leading)

                control()
                    .frame(maxWidth: .infinity, alignment: .leading)

                if Detail.self != EmptyView.self {
                    Button {
                        withAnimation(DS.Motion.panel) { showsDetail.toggle() }
                    } label: {
                        Text("?")
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Color.inkMuted)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(DS.Color.line, lineWidth: DS.Border.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if showsDetail {
                detail()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.base)
                    .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
            }
        }
        .padding(.vertical, DS.Space.base)
    }
}

extension SettingsRow where Detail == EmptyView {
    init(label: String, help: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, help: help, control: control, detail: { EmptyView() })
    }
}

/// The week in four numbers, under the Dictation rows.
///
/// Every figure is drawn from the run log, which never leaves the Mac — this is the only
/// place the app counts anything about how it's used, and it counts it for the user.
struct StatsStrip: View {
    let stats: DictationStats

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            MetaLabel(text: "This week")
            HStack(alignment: .top, spacing: DS.Space.panel) {
                figure(words, "Words dictated")
                figure(latency, "Median latency")
                figure("\(stats.corrections)", "Corrections fired")
                figure(onDevice, "On device")
            }
        }
        .padding(.top, DS.Space.roomy)
    }

    private var words: String {
        stats.words.formatted(.number.grouping(.automatic))
    }

    /// "—" rather than "0.00s" when nothing ran: no data and a fast week are different
    /// facts, and a zero here would read as the second.
    private var latency: String {
        stats.medianLatency.map { String(format: "%.2fs", $0) } ?? "—"
    }

    private var onDevice: String {
        stats.onDeviceShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text(value)
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.ink)
            MetaLabel(text: label)
        }
    }
}

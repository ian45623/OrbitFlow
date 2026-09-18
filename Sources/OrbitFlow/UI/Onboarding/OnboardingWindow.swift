import AppKit
import OrbitFlowHotkey
import SwiftUI

/// What a new user meets first: the four things to set up, on one screen.
///
/// The window explains each permission *before* macOS asks for it, which is the whole
/// reason it exists — the system prompt for Accessibility says nothing about why a
/// dictation app wants to control your computer, and the microphone prompt used to arrive
/// mid-sentence during someone's first hold.
struct OnboardingWindow: View {
    @Bindable var controller: DictationController
    @State private var model = OnboardingModel()
    @State private var runs = RunStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// Runs already logged when the window opened. Anything newer is this session's test.
    @State private var runCountAtOpen = RunStore.shared.runs.count

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            steps
            Spacer(minLength: DS.Space.roomy)
            Hairline()
            footer
        }
        .frame(width: 720, height: 620, alignment: .topLeading)
        .background(DS.Color.canvas)
        .onAppear {
            // macOS brings this window back at launch if it was open when the app quit, and
            // `restorationBehavior(.disabled)` on the scene doesn't stop it. Rather than
            // greeting someone who finished setup last week, the window closes itself:
            // it exists only while something needs setting up. "Run setup again" clears
            // `onboardingCompleted` first, so that route still opens it.
            guard AppDelegate.wantsOnboarding else {
                dismiss()
                return
            }
            model.startWatching(controller: controller)
            runCountAtOpen = runs.runs.count
        }
        .onDisappear {
            model.stopWatching()
            model.recorder.stop(resuming: controller)
        }
        .onChange(of: runs.runs.count) { _, _ in noteTestDictation() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                Text("Talk instead of type.")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.ink)
                Text("Four things to set up. Everything stays on this Mac — no account, "
                    + "no cloud, no analytics.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Font.proseMeasure * 0.7, alignment: .leading)
            }
            Spacer()
            progress
        }
        .padding(DS.Space.panel)
    }

    private var progress: some View {
        HStack(spacing: DS.Space.snug) {
            MetaLabel(text: "\(model.completedCount) of \(OnboardingModel.Step.allCases.count)")
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.line).frame(width: 84, height: 3)
                Capsule()
                    .fill(DS.Color.ink)
                    .frame(
                        width: 84 * CGFloat(model.completedCount) / CGFloat(OnboardingModel.Step.allCases.count),
                        height: 3
                    )
            }
            .animation(DS.Motion.panel, value: model.completedCount)
        }
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: DS.Space.snug) {
            ForEach(OnboardingModel.Step.allCases) { step in
                StepRow(
                    title: step.title,
                    description: step.summary,
                    state: model.state(of: step),
                    meta: model.meta(of: step),
                    metaReserving: model.metaWidth(of: step),
                    isExpanded: model.expanded == step
                ) {
                    detail(for: step)
                }
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(DS.Motion.panel) { model.expanded = step }
                }
            }
        }
        .padding(.horizontal, DS.Space.panel)
    }

    @ViewBuilder
    private func detail(for step: OnboardingModel.Step) -> some View {
        switch step {
        case .microphone: microphoneDetail
        case .accessibility: accessibilityDetail
        case .key: keyDetail
        case .dictation: dictationDetail
        }
    }

    private var microphoneDetail: some View {
        HStack(spacing: DS.Space.base) {
            note(model.microphoneNeedsSettings
                ? "macOS only asks once, and it has already been refused. Switch Orbit Flow "
                    + "on under Privacy & Security ▸ Microphone."
                : "macOS asks once. Nothing is recorded until you hold your key.")
            if model.microphoneNeedsSettings {
                ActionButton(title: "Open System Settings", kind: .primary) {
                    Permissions.openMicrophoneSettings()
                }
            } else {
                ActionButton(title: "Allow microphone", kind: .primary) {
                    Task { await model.requestMicrophone() }
                }
            }
        }
    }

    private var accessibilityDetail: some View {
        HStack(spacing: DS.Space.base) {
            note("macOS asks once. Orbit Flow appears in the list — switch it on and come "
                + "straight back.")
            ActionButton(title: "Open System Settings", kind: .primary) {
                model.openAccessibility()
            }
        }
    }

    private var keyDetail: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            VStack(spacing: DS.Space.tight) {
                Text(ShortcutKeys.displaySummary(Settings.shared.shortcutKeys))
                    .font(DS.Font.metaEmphasis)
                    .foregroundStyle(DS.Color.ink)
                MetaLabel(
                    text: model.recorder.isRecording
                        ? "Press the key you want to hold"
                        : "Captured — press again to replace"
                )
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Space.roomy)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))

            if let problem = model.recorder.problem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.caution)
            }

            HStack(spacing: DS.Space.base) {
                ActionButton(title: "Use this key", kind: .primary) {
                    model.recorder.stop(resuming: controller)
                    withAnimation(DS.Motion.panel) { model.expanded = .dictation }
                }
                ActionButton(title: "Press another key", kind: .quiet) {
                    model.recorder.start(pausing: controller) { key in
                        Settings.shared.shortcutKeys = [key]
                    }
                }
            }
        }
    }

    private var dictationDetail: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text("Hold \(ShortcutKeys.displaySummary(Settings.shared.shortcutKeys)) and say anything.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                if controller.state.isActive {
                    HStack(spacing: DS.Space.snug) {
                        StatusDot(color: DS.Color.signal, isOn: true, size: 8)
                        Waveform(level: controller.level, isActive: true)
                            .frame(height: 16)
                    }
                }
                TestField(text: model.testResult ?? "")
            }
            .padding(DS.Space.base)
            .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))

            HStack(spacing: DS.Space.base) {
                if let meta = model.testMeta {
                    MetaLabel(text: meta)
                }
                if model.testCameBackEmpty {
                    Text("Nothing came through — hold the key and speak again.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.caution)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.base)
            .background(DS.Color.caution.opacity(0.10), in: .rect(cornerRadius: DS.Radius.control))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let waiting = model.waitingFor {
                MetaLabel(text: waiting)
            }
            Spacer()
            ActionButton(title: "Skip for now", kind: .quiet) { finish(openMain: false) }
            ActionButton(
                title: model.isFinished ? "Start using Orbit Flow" : "Continue",
                kind: .primary,
                // Only once the open step has actually happened: a Continue that skips
                // past an ungranted permission teaches people to click through setup.
                isEnabled: model.isFinished || model.state(of: model.expanded) == .done
            ) {
                if model.isFinished {
                    finish(openMain: true)
                } else {
                    withAnimation(DS.Motion.panel) { model.expanded = nextStep() }
                }
            }
        }
        .padding(DS.Space.panel)
    }

    private func nextStep() -> OnboardingModel.Step {
        let all = OnboardingModel.Step.allCases
        guard let index = all.firstIndex(of: model.expanded), index + 1 < all.count else {
            return model.expanded
        }
        return all[index + 1]
    }

    private func finish(openMain: Bool) {
        Settings.shared.onboardingCompleted = true
        model.stopWatching()
        if openMain { openWindow(id: "main") }
        dismiss()
    }

    /// A dictation logged while this window is up is the test in step 4 — the app records
    /// every run, so the newest one past the count we opened with is the one they just did.
    private func noteTestDictation() {
        guard runs.runs.count > runCountAtOpen, let run = runs.runs.first else { return }
        runCountAtOpen = runs.runs.count
        model.recordTestDictation(text: run.text, engine: run.engine, seconds: run.processSeconds)
    }
}

/// The box the first dictation lands in. `NSTextView` rather than SwiftUI's `TextEditor`
/// because this has to be a genuine focused text field — the point of the step is that the
/// normal insertion path works, not that we can display a string.
private struct TestField: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.font = NSFont(name: "Newsreader", size: 14) ?? .systemFont(ofSize: 14)
        view.textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: 0xEDEDE7)
                : NSColor(hex: 0x141414)
        }
        view.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        // Focus lands here as soon as the step opens, so the hold pastes into this box
        // rather than into whatever was frontmost before onboarding appeared.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if !text.isEmpty, view.string != text { view.string = text }
    }
}

import AVFoundation
import Observation
import OrbitFlowHotkey
import SwiftUI

/// The state behind the onboarding window: which step is open, what each one has achieved,
/// and what the footer is waiting for.
///
/// Everything here is a question about the *system* — has TCC granted this, is a key set,
/// has a dictation landed — so the model reads `Permissions` and `Settings` rather than
/// storing its own copies. The one thing it does store is the first dictation's result,
/// because nothing else in the app keeps "did a dictation happen while this window was up".
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case microphone, accessibility, key, dictation

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .key: "Your key"
            case .dictation: "First dictation"
            }
        }

        var summary: String {
            switch self {
            case .microphone: "Audio becomes text on this Mac."
            case .accessibility: "So it can see your key and paste at the cursor."
            case .key: "Hold it to talk. Suggested:"
            case .dictation: "Say one sentence and watch it land."
            }
        }
    }

    /// The step showing its detail. Everything else is one line.
    var expanded: Step

    /// What the first dictation produced, once it has produced something.
    private(set) var testResult: String?

    /// Engine and latency for that dictation — the `PARAKEET · 0.28s` slot.
    private(set) var testMeta: String?

    /// Set when a hold produced nothing, so step 4 can say so rather than looking dead.
    private(set) var testCameBackEmpty = false

    /// True once macOS has refused to ask for the microphone again.
    private(set) var microphoneNeedsSettings = false

    let recorder = ShortcutRecorder()

    private var poll: Task<Void, Never>?

    init(startingAt step: Step? = nil) {
        expanded = step ?? Self.firstIncompleteStep(
            hasMicrophone: Permissions.hasMicrophone,
            hasAccessibility: Permissions.hasAccessibility
        )
        microphoneNeedsSettings = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    /// Which step to open on: the first permission that isn't granted, or the dictation
    /// test once both are. Pure, so the window's one piece of branching can be reasoned
    /// about without a window.
    ///
    /// The key step is never the answer — a shortcut is always set — so someone who only
    /// wants to change it taps the row rather than being routed there.
    static func firstIncompleteStep(hasMicrophone: Bool, hasAccessibility: Bool) -> Step {
        if !hasMicrophone { return .microphone }
        if !hasAccessibility { return .accessibility }
        return .dictation
    }

    // MARK: - Step state

    func state(of step: Step) -> StepState {
        switch step {
        case .microphone:
            Permissions.hasMicrophone ? .done : (expanded == step ? .needsYou : .waiting)
        case .accessibility:
            Permissions.hasAccessibility ? .done : (expanded == step ? .needsYou : .waiting)
        case .key:
            // Always satisfiable: a shortcut is set from first launch (Right ⌥), so this
            // step is a confirmation, never a blocker.
            .done
        case .dictation:
            testResult != nil ? .done : .waiting
        }
    }

    func meta(of step: Step) -> String {
        switch step {
        case .microphone:
            Permissions.hasMicrophone ? "Allowed" : "Not yet allowed"
        case .accessibility:
            Permissions.hasAccessibility ? "Allowed" : "Not yet allowed"
        case .key:
            ShortcutKeys.displaySummary(Settings.shared.shortcutKeys)
        case .dictation:
            testResult != nil ? "Done" : (testMeta ?? "30 seconds")
        }
    }

    /// The longest string each slot can hold, so the right edge doesn't move as values
    /// change (rule 3's fixed slot).
    func metaWidth(of step: Step) -> Int {
        switch step {
        case .microphone, .accessibility: "Not yet allowed".count
        case .key: 10
        case .dictation: "30 seconds".count
        }
    }

    var completedCount: Int {
        Step.allCases.filter { state(of: $0) == .done }.count
    }

    /// What the footer says it is waiting for, or nil when nothing is outstanding.
    var waitingFor: String? {
        if !Permissions.hasAccessibility { return "Waiting for accessibility…" }
        if !Permissions.hasMicrophone { return "Waiting for microphone…" }
        return nil
    }

    var isFinished: Bool {
        Permissions.hasMicrophone && Permissions.hasAccessibility && testResult != nil
    }

    // MARK: - Actions

    func requestMicrophone() async {
        let granted = await Permissions.requestMicrophone()
        microphoneNeedsSettings = !granted
        if granted { advance(from: .microphone) }
    }

    func openAccessibility() {
        // Shows macOS's own prompt when we aren't trusted yet, then opens the pane behind
        // it — the prompt's button does the same thing, and people close it by reflex.
        _ = Permissions.promptForAccessibility()
        Permissions.openAccessibilitySettings()
    }

    /// TCC has no notification for a grant, so the only way to notice one is to look.
    /// Runs while the window is open and stops with it.
    func startWatching(controller: DictationController) {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Permissions.hasAccessibility, !controller.isHotkeyArmed {
                    _ = controller.reloadHotkey()
                    self.advance(from: .accessibility)
                }
                // Reading these keeps the window's observation of them live.
                _ = Permissions.hasMicrophone
            }
        }
    }

    func stopWatching() {
        poll?.cancel()
        poll = nil
    }

    /// Called when a dictation lands while the window is up.
    func recordTestDictation(text: String, engine: String, seconds: Double) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testCameBackEmpty = true
            return
        }
        testCameBackEmpty = false
        testResult = text
        testMeta = "\(engine) · \(String(format: "%.2f", seconds))s"
    }

    /// Opens the next step that still needs something, so finishing one moves the window on
    /// without the user hunting for what changed.
    private func advance(from step: Step) {
        guard expanded == step else { return }
        expanded = Self.firstIncompleteStep(
            hasMicrophone: Permissions.hasMicrophone,
            hasAccessibility: Permissions.hasAccessibility
        )
    }
}

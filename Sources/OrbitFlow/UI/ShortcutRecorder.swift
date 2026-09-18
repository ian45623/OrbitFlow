import AppKit
import Carbon.HIToolbox
import Observation
import OrbitFlowHotkey
import SwiftUI

/// Captures the next key the user presses, for the two screens that let them choose one:
/// Settings and onboarding.
///
/// The event tap is paused while recording, both so the current shortcuts don't start
/// dictating and because the tap would swallow Right ⌥ and Right ⌘ before this monitor
/// ever saw them. A modifier pressed on its own is committed on *release*, not on press:
/// held down, it may still be the start of a combination like ⌘C.
@MainActor
@Observable
final class ShortcutRecorder {
    /// True while the monitor is live and the next key press will be captured.
    private(set) var isRecording = false

    /// Why the last attempt was refused — Caps Lock, a key macOS reserves — or nil.
    private(set) var problem: String?

    private var monitor: Any?
    private var pendingModifier: Int64?
    private var onCapture: ((Shortcut) -> Void)?

    /// Pauses the tap and captures the next press. `onCapture` receives keys that pass
    /// `Shortcut.problem`; refused ones set `problem` and leave recording live.
    func start(pausing controller: DictationController, onCapture: @escaping (Shortcut) -> Void) {
        guard monitor == nil else { return }
        self.onCapture = onCapture
        controller.pauseHotkey()
        problem = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let flags = event.cgEvent?.flags else { return nil }
            let keyCode = Int64(event.keyCode)

            if event.type == .flagsChanged {
                let key = Shortcut(keyCode: keyCode)
                // Caps Lock has no hold state to read; commit it so the refusal shows.
                guard let flag = key.deviceFlag else {
                    self.commit(key, controller: controller)
                    return nil
                }
                if flags.contains(flag) {
                    self.pendingModifier = keyCode
                } else if self.pendingModifier == keyCode {
                    self.commit(key, controller: controller)
                }
                return nil
            }

            self.pendingModifier = nil
            if keyCode == Int64(kVK_Escape), flags.intersection(Shortcut.modifierMask).isEmpty {
                self.stop(resuming: controller)
                return nil
            }
            self.commit(
                Shortcut(keyCode: keyCode, modifiers: flags, characters: event.charactersIgnoringModifiers),
                controller: controller
            )
            return nil
        }
    }

    /// Removes the monitor and rearms the tap. Safe to call when not recording, which is
    /// what makes it usable from `onDisappear`.
    func stop(resuming controller: DictationController) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        pendingModifier = nil
        isRecording = false
        _ = controller.reloadHotkey()
    }

    private func commit(_ key: Shortcut, controller: DictationController) {
        if let problem = key.problem {
            self.problem = problem
            return
        }
        let capture = onCapture
        stop(resuming: controller)
        capture?(key)
    }
}

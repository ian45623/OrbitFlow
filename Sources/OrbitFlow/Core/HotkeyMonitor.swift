import AppKit
import Carbon.HIToolbox
import Foundation
import OrbitFlowHotkey

/// Watches for a held shortcut — a lone modifier or a key combination — using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressed: Set<Shortcut> = []

    var keys: [Shortcut] = ShortcutKeys.fallback
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key went down while a lone-modifier shortcut was held, so that modifier was
    /// half of a chord like ⌘C. Its release is ignored after this.
    var onChord: (() -> Void)?

    /// The left mouse button came up anywhere on the system — which is when a selection
    /// made by dragging or double-clicking is finished. Always passed through untouched,
    /// and nothing about the click is read here: the tap is disabled by macOS if it runs
    /// slowly, so the selection is looked up afterwards, by the caller.
    var onMouseUp: (() -> Void)?

    /// Escape was pressed. Return `true` to swallow it, `false` to let it through.
    ///
    /// The decision belongs to the caller, not here, and it matters: Escape is swallowed
    /// **only** when there is a recording to throw away. Consuming it unconditionally would
    /// break dismissing a dialog, leaving a vim insert mode, or clearing a search field in
    /// every app on the machine, for the entire time Orbit Flow is running.
    var onEscape: (() -> Bool)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        // `keyDown`/`keyUp` are here for key-combination shortcuts, chord detection and
        // Escape. The tap is handed every key on the system, so `handle` compares the key
        // code against the shortcuts and Escape and nothing else — no key is stored or logged.
        var mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        // `leftMouseUp` is here only while read aloud is on, and is only ever forwarded. This
        // is an active tap, so every event in the mask waits on this app's main run loop
        // before reaching its destination — not something to put every click on the system
        // through for a feature that is off. Settings rebuilds the tap when it's toggled.
        if Settings.shared.readAloudEnabled {
            mask |= 1 << CGEventType.leftMouseUp.rawValue
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. The tap was added to the main run loop, so this
                // callback genuinely does run on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(ShortcutKeys.displaySummary(self.keys))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        pressed = []
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        switch type {
        case .flagsChanged:
            guard let key = keys.first(where: { $0.isModifierOnly && $0.keyCode == keyCode }),
                  let flag = key.deviceFlag
            else { return false }

            let nowPressed = flags.contains(flag)
            guard nowPressed != pressed.contains(key) else { return false }

            if nowPressed {
                pressed.insert(key)
                onPress?()
            } else {
                pressed.remove(key)
                onRelease?()
            }
            return key.consumesEvent

        case .keyDown:
            // Auto-repeat of a held combination: swallow it, or the key types while you talk.
            if pressed.contains(where: { !$0.isModifierOnly && $0.keyCode == keyCode }) { return true }

            if pressed.contains(where: \.isModifierOnly) {
                pressed = pressed.filter { !$0.isModifierOnly }
                onChord?()
            }

            if !isRepeat, let key = keys.first(where: { $0.matches(keyCode: keyCode, flags: flags) }) {
                pressed.insert(key)
                onPress?()
                return true
            }

            // Escape cancels an in-flight dictation, and is swallowed only if there was one.
            guard keyCode == Int64(kVK_Escape) else { return false }
            return onEscape?() ?? false

        case .keyUp:
            // Matched on key code alone: the modifiers are often let go first.
            guard let key = pressed.first(where: { !$0.isModifierOnly && $0.keyCode == keyCode })
            else { return false }
            pressed.remove(key)
            onRelease?()
            return true

        case .leftMouseUp:
            onMouseUp?()
            return false

        default:
            return false
        }
    }
}

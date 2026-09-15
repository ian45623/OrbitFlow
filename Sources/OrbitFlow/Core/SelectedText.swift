import AppKit
import ApplicationServices

/// Reads what is highlighted in the frontmost app, through Accessibility.
///
/// This runs on every mouse-up while read aloud is on, so it is built to be cheap and to
/// fail quietly. The AX calls run off the main thread: they block for as long as the other
/// app takes to answer, and the main run loop is also where the event tap runs, so every
/// key press and click on the system would wait behind a slow app. Only the frontmost-app
/// lookup stays on the main actor, and just its pid crosses over.
///
/// It asks the frontmost *application* element rather than the system-wide one because the
/// messaging timeout has to be short — a hung app must not hold a read for AX's default six
/// seconds on each click — and a timeout set on the system-wide element is global to the
/// whole process, which would also shorten the calls `TextInjector` depends on.
///
/// Apps that don't expose their selection (some browsers, Electron apps, terminals) just
/// return nil, and the pill doesn't appear. There is no ⌘C fallback: it cannot run on
/// every mouse-up without clobbering the clipboard.
@MainActor
enum SelectedText {
    /// The frontmost app to read from, or nil when that is Orbit Flow itself: its own
    /// windows already show their text, and offering it would file a History entry to read
    /// a History entry.
    static func frontmostAppPID() -> pid_t? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return pid
    }

    nonisolated static func read(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Checked before the value is ever asked for, so a password is never read into
        // this process at all — not merely not offered.
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == kAXSecureTextFieldSubrole {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let text = value as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

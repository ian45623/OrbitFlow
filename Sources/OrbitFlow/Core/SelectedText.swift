import AppKit
import ApplicationServices

/// Reads what is highlighted in the frontmost app, through Accessibility.
///
/// This runs on every mouse-up while read aloud is on, on the main thread, so it is built
/// to be cheap and to fail quietly. It asks the frontmost *application* element rather
/// than the system-wide one because the messaging timeout has to be short — a hung app
/// must not stall Orbit Flow for AX's default six seconds on each click — and a timeout set
/// on the system-wide element is global to the whole process, which would also shorten
/// the calls `TextInjector` depends on.
///
/// Apps that don't expose their selection (some browsers, Electron apps, terminals) just
/// return nil, and the pill doesn't appear. There is no ⌘C fallback: it cannot run on
/// every mouse-up without clobbering the clipboard.
@MainActor
enum SelectedText {
    static func read() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              // Orbit Flow's own windows already show their text, and offering it would file
              // a History entry to read a History entry.
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
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

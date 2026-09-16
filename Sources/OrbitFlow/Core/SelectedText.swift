import AppKit
import ApplicationServices
import OrbitFlowHotkey

// DEBUG TRACE — temporary, remove before commit. Codes and lengths only, never text.
nonisolated func readAloudTrace(_ line: String) {
    let url = URL(fileURLWithPath: "/tmp/orbitflow-readaloud-trace.log")
    let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
}

/// Finds out what is highlighted in the frontmost app.
///
/// Accessibility first, on every mouse-up while read aloud is on. It is cheap and silent,
/// but many apps don't answer: Chrome reports page selections through a different API and
/// updates it a beat late, Electron apps (Cursor, VS Code, Slack) expose no focused element
/// unless a screen reader asks, and Word's document doesn't support selected text. For
/// those, `read` says `.unknown` and the pill offers to copy instead — `copy()` runs only
/// when ▶ is pressed, never on a click, because it borrows the clipboard.
///
/// The AX calls run off the main thread: they block for as long as the other app takes to
/// answer, and the main run loop is also where the event tap runs, so every key press and
/// click on the system would wait behind a slow app. Only the frontmost-app lookup stays on
/// the main actor, and just its pid crosses over.
///
/// It asks the frontmost *application* element rather than the system-wide one because the
/// messaging timeout has to be short — a hung app must not hold a read for AX's default six
/// seconds on each click — and a timeout set on the system-wide element is global to the
/// whole process, which would also shorten the calls `TextInjector` depends on.
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

    nonisolated static func read(pid: pid_t) -> SelectionReading {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focused: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused
        )
        readAloudTrace("read pid=\(pid) focusedErr=\(focusedError.rawValue)")
        guard focusedError == .success, let focused else {
            return classifySelection(focusedError: focusedError.rawValue, selectedError: nil, value: nil)
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Checked before the value is ever asked for, so a password is never read into
        // this process at all — not merely not offered. Reported as empty, not unknown, so
        // the pill never offers to copy out of a password field either.
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == kAXSecureTextFieldSubrole {
            return .empty
        }

        var value: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value
        )
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        readAloudTrace("  role=\(role as? String ?? "nil") selErr=\(selectedError.rawValue) len=\((value as? String)?.count ?? -1)")
        return classifySelection(
            focusedError: 0, selectedError: selectedError.rawValue, value: value as? String
        )
    }

    /// Copies the frontmost app's selection with ⌘C, reads it, and puts the clipboard back.
    ///
    /// Only for a ▶ the user pressed on a copy offer. The pill never takes focus, so the
    /// app they selected in is still the one that receives the keystroke. Nil when the
    /// clipboard doesn't change within half a second — nothing was selected after all, or
    /// the app ignores ⌘C.
    static func copy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = TextInjector.snapshot(of: pasteboard)
        let before = pasteboard.changeCount

        TextInjector.postCommand(key: 8) // kVK_ANSI_C

        // Apps copy asynchronously; poll rather than guess one delay that suits all of them.
        for _ in 0..<10 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard pasteboard.changeCount != before else {
            readAloudTrace("copy: clipboard unchanged")
            return nil
        }

        let text = pasteboard.string(forType: .string)
        // Put back exactly what was there — including nothing, which `restore` alone would
        // leave as the copied selection.
        if saved?.isEmpty ?? true {
            pasteboard.clearContents()
        } else {
            TextInjector.restore(saved, to: pasteboard)
        }
        readAloudTrace("copy: len=\(text?.count ?? -1)")

        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

import AppKit
import Foundation
import OrbitFlowAIRewrite

/// The right-click entry point: rewrite a selection made in any other app.
///
/// Registered as `NSApp.servicesProvider`. macOS calls one of the `@objc` methods below
/// with the selected text on a pasteboard; the rows themselves are declared in
/// `Info.plist`, which is why they cannot be hidden when the feature is off.
@MainActor
final class RewriteService: NSObject {
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
    }

    @objc func rewriteDefault(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: Settings.shared.rewriteMode) }

    @objc func rewriteFaithful(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .faithful) }

    @objc func rewriteCasual(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .casual) }

    @objc func rewriteProfessional(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .professional) }

    @objc func rewriteProblemSolver(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { run(pboard, mode: .problemSolver) }

    @objc func openSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = selection(from: pboard) else { return }
        controller.flash("Open: \(text.prefix(20))…")
    }

    // MARK: - Shared path

    private func run(_ pboard: NSPasteboard, mode: RewriteMode) {
        guard let text = selection(from: pboard) else { return }
        controller.flash("\(mode.displayName): \(text.prefix(20))…")
    }

    /// Nil when the pasteboard carries nothing usable — an empty selection, or a
    /// whitespace-only one, both of which would waste a round trip.
    private func selection(from pboard: NSPasteboard) -> String? {
        guard let raw = pboard.string(forType: .string) else {
            controller.flash("Nothing selected.")
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            controller.flash("Nothing selected.")
            return nil
        }
        return trimmed
    }
}

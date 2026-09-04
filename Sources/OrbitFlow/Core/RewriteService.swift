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

    /// Unlike the in-place rows, this one deliberately activates the app — bringing the
    /// window forward is the whole point of it.
    @objc func openSelection(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = selection(from: pboard) else { return }

        // `Off` has no way to hide this row — the menu is a static Info.plist array —
        // so the setting has to mean something here the same way it does for the other
        // five rows: filing text to disk and opening the window is not "doing nothing".
        guard Settings.shared.aiRewriteUse.servesOnDemand else {
            controller.flash(OnDemandRewrite.Unavailable.turnedOff.summary)
            return
        }

        // The same call the "Add text" composer makes, with a different engine label so
        // history says where this came from.
        let run = DictationRun(
            date: Date(),
            engine: "Selection",
            audioSeconds: 0,
            processSeconds: 0,
            text: text
        )
        RunLog.record(run)
        MainRoute.shared.open(run.id)
        AppDelegate.showMainWindow()
    }

    // MARK: - Shared path

    private func run(_ pboard: NSPasteboard, mode: RewriteMode) {
        guard let text = selection(from: pboard) else { return }

        // Two impatient right-clicks would otherwise mean two billed calls racing to
        // paste into the same field — the second to land silently overwrites the first.
        // One in flight at a time is the whole fix; there is no work worth queuing.
        guard !controller.isRewriting else {
            controller.flash("Already rewriting — one at a time.")
            return
        }

        let settings = Settings.shared
        let provider = settings.aiProvider
        let model = settings.aiModel
        let hasKey = Keychain.hasKey(account: provider.rawValue)

        let engine: OnDemandRewrite.Engine
        switch OnDemandRewrite.engine(
            use: settings.aiRewriteUse,
            hasKey: hasKey,
            model: model,
            onDeviceAvailable: OnDeviceRewriter.isAvailable
        ) {
        case .success(let chosen):
            engine = chosen
        case .failure(let reason):
            controller.flash(reason.summary)
            return
        }

        let key = engine == .cloud ? (Keychain.read(account: provider.rawValue) ?? "") : ""
        controller.setRewriting(true)

        Task { @MainActor in
            defer { controller.setRewriting(false) }
            do {
                // Longer than dictation's 8s. Nothing is queued behind this and the user
                // asked for it explicitly, so waiting beats a failure they have to
                // right-click again to retry.
                let output: String
                if engine == .cloud {
                    output = try await CloudRewriter(
                        provider: provider, key: key, timeout: .seconds(30)
                    ).rewrite(text, model: model, mode: mode)
                } else {
                    output = try await OnDeviceRewriter.rewrite(
                        text, system: mode.systemPrompt, timeout: .seconds(30)
                    )
                    // CloudRewriter applies this internally; OnDeviceRewriter deliberately
                    // applies no policy at all, so the guard has to run here or the
                    // on-device path would be the one place a model's answer could
                    // overwrite the selection it was asked to rewrite.
                    if let reason = RewriteGuard.rejection(original: text, output: output, mode: mode) {
                        throw RewriteFailure.rejected(reason)
                    }
                }
                deliver(output, mode: mode)
            } catch {
                // The opposite of CloudFormatter's contract, on purpose. Dictation falls
                // back to the rule pass because an utterance already spoken must not be
                // lost. Here the user's own words are already on screen and already good
                // enough to have been written — overwriting a paragraph with a degraded
                // version of itself because a request timed out is a destructive
                // surprise on text nobody asked us to touch. So: change nothing.
                let reason = (error as? RewriteFailure)?.summary
                    ?? OnDeviceRewriter.describe(error)
                Log.inject.info("on-demand rewrite failed (\(reason, privacy: .private))")
                controller.flash("Rewrite failed — \(reason)")
            }
        }
    }

    /// Puts the result where the user can use it.
    ///
    /// A selection in a web page or a PDF cannot be replaced, and macOS gives no way to
    /// know that before trying — `TextInjector` falls back to ⌘V, which a read-only view
    /// simply ignores, and neither step reports back. So the result also goes on the
    /// pasteboard and the notice says so, which is true whether or not the injection
    /// landed. Dictation can inject silently; this cannot.
    private func deliver(_ output: String, mode: RewriteMode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        TextInjector.insert(output)
        controller.flash("\(mode.displayName) — also copied to clipboard")
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

import AppKit
import SwiftUI

/// The floating capsule that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    /// Transparent breathing room around the capsule, on every side.
    ///
    /// The panel is the clipping boundary for everything SwiftUI draws, so a capsule sized
    /// exactly to the panel has nowhere to put its shadow: the blur is cut off flush at the
    /// edge and the corners read as hard squares instead of fading out. The margin has to
    /// clear `DS.Shadow.hud`'s radius *plus* its downward offset.
    static let shadowMargin: CGFloat = 12

    /// The window size for a given pill: the capsule plus margin on all sides.
    static func panelSize(for hud: HUDSize) -> CGSize {
        CGSize(
            width: hud.pillSize.width + shadowMargin * 2,
            height: hud.pillSize.height + shadowMargin * 2
        )
    }

    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize(for: Settings.shared.hudSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // The pill carries a discard and a confirm button, so it has to receive clicks.
        // This is safe only because `canBecomeKey` is false: a non-activating panel takes
        // the click without activating the app, so the text field you were typing in keeps
        // focus and `TextInjector` still has somewhere to insert.
        ignoresMouseEvents = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        contentView = NSHostingView(rootView: HUDView(controller: controller))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, horizontally centered on the active screen.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        // Offset by the margin so the *capsule* sits 96pt up, not the invisible panel around
        // it — otherwise changing the pill size would appear to move the pill.
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 96 - Self.shadowMargin
            )
        )
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        // The pill size is a setting, and this is the only moment it can change without the
        // user seeing it resize under them.
        setContentSize(Self.panelSize(for: Settings.shared.hudSize))
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}

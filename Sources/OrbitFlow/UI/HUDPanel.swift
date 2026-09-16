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

    /// The read-aloud capsule's width.
    ///
    /// Narrower than Full, because read aloud has no transcript to show — just two short
    /// menus between two discs — and a 300pt bar of mostly empty capsule sits over what you
    /// are trying to read. 230 fits the longest mode name ("With example") beside the
    /// widest speed ("1.75×") without either truncating.
    ///
    /// Messages are the exception and borrow Full's width: an error names what failed
    /// ("ElevenLabs rejected the key — check it in Settings.") and is the one thing here
    /// worth widening the pill for.
    static func readAloudPillWidth(isMessage: Bool) -> CGFloat {
        isMessage ? HUDSize.full.pillSize.width : 230
    }

    /// Read in `present()` to decide whether this pill needs to be full-sized for a
    /// notice or read aloud. Stored rather than reaching for a shared singleton so the
    /// panel doesn't need to know how the controller it was handed relates to anything else.
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
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
        // The pill carries buttons — discard and confirm, or ✕ and ▶/■ while reading aloud —
        // so it has to receive clicks.
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
        // `visibleFrame` already stops above the Dock, so this is the gap between the two:
        // close enough to read as part of the Dock's furniture rather than floating in the
        // middle of whatever you're working in, far enough not to touch it or catch its
        // magnification. Offset by the margin so the *capsule* sits at that gap, not the
        // invisible panel around it — otherwise changing the pill size would move the pill.
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.dockGap - Self.shadowMargin
            )
        )
    }

    /// Space left between the Dock (or the screen's bottom edge) and the pill.
    ///
    /// Enough to clear the Dock's own tooltips: hovering an icon raises its name into the
    /// space just above the Dock, and at a smaller gap that label shows through from behind
    /// the pill. Everything else wants this as small as possible — the pill belongs with the
    /// Dock, not in the middle of what you're reading.
    static let dockGap: CGFloat = 40

    func present() {
        // Read aloud sizes itself: narrow for the two menus, Full's width for a message.
        // Everything else is the pill-size setting, or Full when a notice overrides it.
        let size: CGSize
        if controller.showsReadAloudButton {
            size = CGSize(
                width: Self.readAloudPillWidth(isMessage: controller.isReadAloudMessage)
                    + Self.shadowMargin * 2,
                height: HUDSize.full.pillSize.height + Self.shadowMargin * 2
            )
        } else {
            size = Self.panelSize(for: controller.needsFullHUD ? .full : Settings.shared.hudSize)
        }

        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance. But read aloud and dictation can hand the pill
        // to each other while it's already up — a Compact dictation starting while History
        // speech is showing, or the talk key stopping speech and starting a Compact
        // dictation in the same pass — so a visible pill whose size no longer matches what
        // it needs to show still has to resize, just without the fade: only its *arrival*
        // gets one.
        guard !isVisible || alphaValue < 1 else {
            if frame.size != size {
                setContentSize(size)
                reposition()
            }
            return
        }

        // The pill size is a setting, and this is the only moment it can change without the
        // user seeing it resize under them (besides the same-pill resize above). A notice
        // overrides the setting — see `DictationController.needsFullHUD`.
        setContentSize(size)
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

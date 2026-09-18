import AppKit
import SwiftUI
import OrbitFlowAIRewrite
import OrbitFlowHotkey

@main
struct OrbitFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Orbit Flow", id: "main") {
            // Wrapped rather than opened from the delegate: a SwiftUI `Window` scene has no
            // `NSWindow` until something opens it, and `openWindow` only exists inside a
            // view. The main window is the one scene macOS opens by itself at launch, so it
            // is where the decision to show onboarding instead can be acted on.
            RootWindow(controller: delegate.controller)
        }
        // Recent needs room for three panes — 200 for the rail and 340 for the list before
        // the transcript starts — and the transcript pane has a composer pinned under it,
        // so height is as load-bearing as width. Opening smaller than this means the first
        // thing anyone does is resize the window.
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }

        // Sized by its content and not resizable: it is a sequence of steps, not a
        // surface anyone works in.
        Window("Set up Orbit Flow", id: "onboarding") {
            OnboardingWindow(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
        // macOS reopens windows that were open at quit, which for a setup window means
        // greeting someone who finished setup last week. Whether it should appear is a
        // question about permissions, asked at launch — never a question about what
        // happened to be on screen when the app last quit.
        .restorationBehavior(.disabled)

        Window("Engine comparison", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }

    /// The main window, plus the one thing that has to happen once at launch from inside a
    /// view: opening onboarding.
    private struct RootWindow: View {
        @Bindable var controller: DictationController
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            MainWindow(controller: controller)
                .task {
                    guard AppDelegate.wantsOnboarding else { return }
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                    // A first-run greeting shouldn't arrive stacked on top of a window full
                    // of empty history. Someone returning because a permission broke keeps
                    // theirs — they were already using the app.
                    if !Settings.shared.onboardingCompleted {
                        NSApp.windows.first { $0.title == "Orbit Flow" }?.close()
                    }
                }
        }
    }

    /// The app's own icon, scaled to menu-bar height. Read through LaunchServices rather
    /// than as a second copy of the artwork, so `make icon` updates the Dock and the menu
    /// bar together. Not a template image: the icon is colored on purpose, so it must not
    /// be flattened to a monochrome silhouette.
    private static let menuBarIcon: NSImage = {
        let icon = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = false
        return icon
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var stateObservation: NSObjectProtocol?
    private var rewriteService: RewriteService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)

        // Held in a property because `servicesProvider` is an unowned reference — an
        // inline instance would deallocate and every right-click row would silently
        // do nothing. NSUpdateDynamicServices tells the system to re-read Info.plist,
        // which matters on the launch right after a build changed it.
        let service = RewriteService(controller: controller)
        rewriteService = service
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()

        if !controller.activate() {
            // Only prompt when we're actually untrusted. A tap can fail to be created for
            // other reasons, and showing the grant dialog to someone who already granted it
            // is how an app earns a reputation for asking forever.
            //
            // Onboarding owns this prompt when it's going to show: its Accessibility step
            // explains what the grant is for before macOS asks, which is the entire reason
            // that window exists.
            if !Permissions.hasAccessibility, !Self.wantsOnboarding {
                Permissions.promptForAccessibility()
            }
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Write the dashboard up front so the menu item always opens something, even
        // before the first dictation.
        RunLog.regenerate()

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.compareMode || Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Every `make install` relaunches the app and drops its windows. Restoring the
        // window when it was open last time keeps it from vanishing on each rebuild.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        Updater.shared.startPeriodicChecks { [controller] in
            controller.state != .idle || controller.isReadAloudShowing
        }

        observeState()
        // Both grants, at launch, in one line. "It keeps asking for permission" and "the
        // hotkey does nothing" are the same two bits from the outside, and this is the
        // cheapest way to tell which is actually missing.
        Log.app.info("""
            permissions — accessibility: \(Permissions.hasAccessibility, privacy: .public), \
            microphone: \(Permissions.hasMicrophone, privacy: .public), \
            onboarding completed: \(Settings.shared.onboardingCompleted, privacy: .public)
            """)
        Log.app.info("Orbit Flow ready — hold \(ShortcutKeys.displaySummary(Settings.shared.shortcutKeys)) to dictate")
    }

    /// `orbitflowyt://clear` and `orbitflowyt://show`, used by the legacy HTML dashboard and
    /// as a scriptable way to raise the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "orbitflowyt" {
            switch url.host {
            case "clear":
                RunLog.clear()
                RunStore.shared.reload()
            case "show":
                Self.showComparisonWindow()
            default:
                break
            }
        }
    }

    /// Raises a window without needing SwiftUI's `openWindow` environment value — usable
    /// from the app delegate and from a URL handler.
    ///
    /// Both scenes are `Window` rather than `WindowGroup`, so SwiftUI keeps the `NSWindow`
    /// alive after it's closed and this can find it again by title.
    static func showWindow(titled title: String) {
        if let existing = NSApp.windows.first(where: { $0.title == title }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            Log.app.error("no window titled \(title, privacy: .public) to raise")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showMainWindow() {
        showWindow(titled: "Orbit Flow")
    }

    /// First launch always, and afterwards only when something it set up has come undone
    /// — a TCC grant reset by an update, or a permission switched off by hand.
    static var wantsOnboarding: Bool {
        if !Settings.shared.onboardingCompleted { return true }
        return !Permissions.hasAccessibility || !Permissions.hasMicrophone
    }

    static func showComparisonWindow() {
        RunStore.shared.reload()
        showWindow(titled: "Engine comparison")
    }

    /// Closing the window leaves the app running with the key still armed.
    ///
    /// This is the whole point of a push-to-talk app: dictation happens in *other* apps, so
    /// the window is a reading surface you close when you're done with it, not the app
    /// itself. AppKit already defaults to `false` here, but the default is silent and easy
    /// to lose to a stray SwiftUI scene change — stating it makes it load-bearing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.notice
            _ = controller.isRewriting
            _ = controller.readAloudOffer
            _ = controller.readAloudStatus
            _ = controller.readAloudError
            _ = Speaker.shared.isSpeaking
            _ = Speaker.shared.isPreparing
            _ = Speaker.shared.failure
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The pill is up for a live dictation, for an on-demand rewrite in flight,
                // for the three seconds a notice is on screen, and for as long as there is
                // something to offer or something being read — from anywhere, so there is
                // always one place to stop the voice.
                let wanted = self.controller.state.isActive
                    || self.controller.notice != nil
                    || self.controller.isRewriting
                    || self.controller.isReadAloudShowing
                if wanted {
                    // Before `present`, which reads it for the window's size.
                    self.controller.refreshPillShape()
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var parakeet = ParakeetDownload.shared

    var body: some View {
        Text("Hold \(ShortcutKeys.displaySummary(settings.shortcutKeys)) to dictate")

        Divider()

        // Meaningful whenever a rewrite can run at all — under On demand this picker is what
        // the default right-click row reads. Hidden when nothing can use it, because a mode
        // that changes nothing is worse than no mode at all.
        if settings.aiRewriteUse != .off {
            Picker("Rewrite mode", selection: $settings.rewriteMode) {
                ForEach(RewriteMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }

        Toggle("Compare mode (both engines)", isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker("Engine", selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        Button("Open Orbit Flow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        if !Permissions.hasAccessibility || !Permissions.hasMicrophone || !settings.onboardingCompleted {
            Button("Set up Orbit Flow…") {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Button("Show comparison window") {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead. Silent once it's installed — a permanent "✓ installed" row
        // is a menu item that can never do anything.
        if settings.engine == .parakeet || settings.compareMode {
            switch parakeet.phase {
            case .ready:
                EmptyView()
            case .working(let label, let fraction):
                Text("\(label) Parakeet… \(Int(fraction * 100))%")
            case .missing:
                Button("Download Parakeet model (470 MB)…") { parakeet.start() }
            case .failed:
                Button("Parakeet download failed — try again") { parakeet.start() }
            }
        }

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        Button("Quit Orbit Flow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

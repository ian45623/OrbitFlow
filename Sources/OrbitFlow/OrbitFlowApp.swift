import AppKit
import SwiftUI
import OrbitFlowAIRewrite

@main
struct OrbitFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Orbit Flow", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 620)
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

        Window("Engine comparison", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)

        if !controller.activate() {
            // Only prompt when we're actually untrusted. A tap can fail to be created for
            // other reasons, and showing the grant dialog to someone who already granted it
            // is how an app earns a reputation for asking forever.
            if !Permissions.hasAccessibility { Permissions.promptForAccessibility() }
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

        observeState()
        Log.app.info("Orbit Flow ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
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
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
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
        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        Divider()

        Picker("Push-to-talk key", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

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

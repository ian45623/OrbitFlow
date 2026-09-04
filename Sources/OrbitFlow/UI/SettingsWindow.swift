import SwiftUI

/// The settings content, shared by the Settings tab in the main window and the standard
/// ⌘, window. One view rather than two, so the two can never drift apart.
///
/// Three decisions, each on its own surface with a line of plain English underneath saying
/// what changes. Nothing here is a preference for its own sake.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    /// Settings read as a column, not a page. Capped so the tab in an 860pt window and the
    /// 520pt ⌘, window lay out identically instead of one stretching into a banner.
    private let measure: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                group("Push to talk") {
                    if !controller.isHotkeyArmed { accessibilityNotice }

                    Segmented(
                        options: PushToTalkKey.allCases.map { ($0, $0.displayName) },
                        selection: Binding(
                            get: { settings.pushToTalkKey },
                            set: { key in
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                        )
                    )
                    note("Tap this key to start dictating and tap it again to stop — the text "
                        + "lands wherever your cursor is. Or hold it down and let go, if you'd "
                        + "rather not think about stopping.")
                    note("The record button works regardless of what's focused, so you can still "
                        + "record without touching the key.")
                    // These three are the only safe choices, and it's worth saying why rather
                    // than leaving it looking like an unfinished picker: the event tap watches
                    // modifier changes, and a dedicated right-hand modifier is the only kind
                    // that can be held down without typing anything into your document.
                    note("Right ⌥ and Right ⌘ are consumed while held. fn is passed through, so "
                        + "fn+arrow, fn+delete and the emoji picker keep working.")
                }

                group("Model") {
                    Segmented(
                        options: SpeechEngineChoice.allCases.map {
                            ($0, $0 == .apple ? "Apple" : "Parakeet")
                        },
                        selection: $settings.engine
                    )
                    note(settings.engine == .apple
                        ? "Apple's on-device transcriber. Streams text while you speak, and needs no download."
                        : "Parakeet on the Neural Engine. Resolves when you let go; downloads a 470 MB model once.")
                }

                group("Dictation pill") {
                    Segmented(
                        options: HUDSize.allCases.map { ($0, $0.displayName) },
                        selection: $settings.hudSize
                    )
                    note(settings.hudSize == .compact
                        ? "Just the level trace, discard, and confirm."
                        : "Adds the transcript as it resolves, so you can read it before it lands.")
                    note("Either way: ✓ stops and pastes, ✕ throws the recording away, and "
                        + "Escape does the same as ✕ without reaching for the mouse. "
                        + "Takes effect on your next dictation.")
                }

                group("Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Text("Clean up transcripts")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers and fixes spacing and punctuation. Dictionary corrections "
                        + "run either way.")
                }

                group("When you close the window") {
                    Text("Orbit Flow keeps running and the key stays armed. Reopen it from the menu "
                        + "bar or the Dock icon; quit from the Dock, the menu bar, or ⌘Q.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.wide)
        }
    }

    /// Shown when the event tap isn't live. Without this the app fails silently: the key
    /// picker still offers choices, the record button still records, and holding the key
    /// just does nothing at all with no indication why.
    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(alignment: .top, spacing: DS.Space.snug) {
                StatusDot(color: DS.Color.caution, isOn: true)
                    .padding(.top, DS.Space.tight)
                Text("The hotkey is off. macOS hasn't granted Orbit Flow accessibility access, "
                    + "so it can't see the key — and it can't type text into other apps either.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.snug) {
                ActionButton(title: "Open accessibility settings") {
                    Permissions.openAccessibilitySettings()
                }
                // The tap is created once at launch, so a grant made while the app is
                // running needs the tap rebuilt before the key does anything.
                ActionButton(title: "Try again", kind: .quiet) {
                    controller.reloadHotkey()
                }
            }
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
    }

    private func group<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                FieldLabel(text: label, color: DS.Color.ink, emphasis: true)
                content()
            }
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The standard ⌘, window. Kept alongside the Settings tab because macOS users reach for
/// ⌘, without looking, and it costs one wrapper.
struct SettingsWindow: View {
    @Bindable var controller: DictationController

    var body: some View {
        SettingsPanel(controller: controller)
            .frame(width: 560, height: 560)
            .background(DS.Color.canvas)
    }
}

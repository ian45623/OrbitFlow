import SwiftUI

/// The floating capsule that appears while you're dictating.
///
/// This is the surface you actually see — a few seconds at a time, dozens of times a day,
/// floating over whatever you're really working in. A dark capsule with two discs: discard
/// on the left, confirm on the right, the level trace between them. Two sizes, because that
/// trade is a real preference and not a default — **compact** only confirms it's hearing
/// you, **full** also shows the transcript as it resolves.
struct HUDView: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    private var hud: HUDSize { settings.hudSize }
    private var isListening: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            HUDButton(kind: .discard, size: hud.controlSize) { controller.discard() }

            Waveform(
                level: controller.level,
                isActive: isListening,
                color: isError ? DS.Color.caution : DS.Color.inkOnHUD
            )
            .frame(width: hud.waveWidth)

            if hud == .full {
                Text(label)
                    .font(hasTranscript ? DS.Font.prose : DS.Font.body)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(DS.Motion.press, value: controller.transcript)
            }

            HUDButton(kind: .confirm, size: hud.controlSize) { controller.stopAndInsert() }
        }
        .padding(.horizontal, DS.Space.tight)
        .frame(width: hud.pillSize.width, height: hud.pillSize.height)
        .background {
            // A true capsule: the radius can't exceed half the short side, or the corners
            // flatten into a rounded rectangle.
            let shape = RoundedRectangle(
                cornerRadius: min(DS.Radius.hud, hud.pillSize.height / 2),
                style: .continuous
            )
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(DS.Color.hudSurface))
                .overlay(shape.strokeBorder(DS.Color.hudEdge, lineWidth: DS.Border.hairline))
                .shadow(
                    color: DS.Shadow.hud.color,
                    radius: DS.Shadow.hud.radius,
                    y: DS.Shadow.hud.y
                )
        }
        // The panel is larger than the pill by exactly this much on every side, so the
        // shadow has somewhere to fade out instead of being clipped square at the corners.
        .padding(HUDPanel.shadowMargin)
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    /// True once there are real words to read, which is when the label stops being
    /// interface chrome and becomes the transcript.
    private var hasTranscript: Bool {
        !isError && !controller.transcript.isEmpty
    }

    // Errors are amber, not red: red in this app means recording, and a failed dictation
    // that lights the same lamp as a live one is worse than no lamp at all.
    private var textColor: Color {
        if isError { return DS.Color.caution }
        return hasTranscript ? DS.Color.inkOnHUD : DS.Color.inkOnHUDMuted
    }

    private var label: String {
        switch controller.state {
        case .starting: "Listening…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing:
            if controller.isRewriting { "Rewriting…" }
            else { controller.transcript.isEmpty ? "Transcribing…" : controller.transcript }
        case .error(let message): message
        case .idle: ""
        }
    }
}

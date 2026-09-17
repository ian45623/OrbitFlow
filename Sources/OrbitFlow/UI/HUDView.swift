import OrbitFlowAIRewrite
import SwiftUI

/// The floating capsule that appears while you're dictating.
///
/// This is the surface you actually see — a few seconds at a time, dozens of times a day,
/// floating over whatever you're really working in. A dark capsule with two discs: confirm
/// on the left, discard on the right, the level trace between them — the same hand finds
/// accept and dismiss in the same places everywhere in this app. Two sizes, because that
/// trade is a real preference and not a default — **compact** only confirms it's hearing
/// you, **full** also shows the transcript as it resolves. When read aloud offers
/// highlighted text, or anything is being spoken, the same capsule carries ▶/■, the reading
/// mode and ✕.
struct HUDView: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var speaker = Speaker.shared

    // A notice — or an on-demand rewrite running with no dictation behind it — borrows
    // Full's size regardless of the setting: Compact's 104×26 pill was sized for a
    // waveform, and the on-demand path's messages are the feature's only feedback
    // channel. `HUDPanel` makes the identical decision for the window itself, so the
    // NSPanel's bounds and what SwiftUI draws inside it never disagree.
    private var hud: HUDSize { controller.needsFullHUD ? .full : settings.hudSize }
    private var isListening: Bool { controller.state.isActive }

    var body: some View {
        if controller.showsReadAloudButton { readAloudPill } else { dictationPill }
    }

    private var dictationPill: some View {
        HStack(spacing: DS.Space.snug) {
            dictationControls
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
                .fill(DS.Color.hudSurface)
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

    @ViewBuilder
    private var dictationControls: some View {
        HUDButton(kind: .confirm, size: hud.controlSize) { controller.stopAndInsert() }

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

        // A notice can cover speech that is still playing, and then there is no recording
        // for ✕ to discard — only the voice to stop.
        HUDButton(kind: .discard, size: hud.controlSize) {
            if controller.state.isActive {
                controller.discard()
            } else {
                controller.stopReadingAloud()
            }
        }
    }

    /// Read aloud gets the same capsule as dictation, with the same discs in the same
    /// places — ▶/■ where confirm sits, ✕ where discard sits — and the reading mode where
    /// the transcript would be.
    ///
    /// The mode belongs here rather than only in Settings because it is the decision you
    /// make *about this passage*: whether this one is worth hearing in full or only as a
    /// summary changes page to page, and a control two windows away would never be used.
    private var readAloudPill: some View {
        HStack(spacing: DS.Space.snug) {
            // An offer outranks whatever is playing: a fresh highlight made while the
            // previous passage is still being read is there to be played, and a ■ that
            // throws it away would make the user highlight it again. A transform counts as
            // busy, so the disc that starts it is also the disc that cancels it.
            if controller.readAloudOffer == nil,
               speaker.isSpeaking || speaker.isPreparing || controller.readAloudStatus != nil {
                HUDButton(kind: .stop, size: HUDPanel.readAloudControlSize) {
                    controller.stopReadingAloud()
                }
            } else {
                HUDButton(kind: .play, size: HUDPanel.readAloudControlSize) {
                    controller.readAloud()
                }
            }

            readAloudCentre

            // Speed sits next to the mode because they are the same kind of decision — how
            // you want this passage delivered — and both are things you change on the
            // passage in front of you, not in a settings window.
            if !controller.isReadAloudMessage { speedMenu }

            HUDButton(kind: .discard, size: HUDPanel.readAloudControlSize) {
                controller.stopReadingAloud()
            }
        }
        .padding(.horizontal, DS.Space.tight)
        .frame(width: HUDPanel.readAloudPillSize.width,
               height: HUDPanel.readAloudPillSize.height)
        .background {
            let shape = RoundedRectangle(
                cornerRadius: min(DS.Radius.hud, HUDSize.full.pillSize.height / 2),
                style: .continuous
            )
            shape
                .fill(DS.Color.hudSurface)
                .overlay(shape.strokeBorder(DS.Color.hudEdge, lineWidth: DS.Border.hairline))
                .shadow(
                    color: DS.Shadow.hud.color,
                    radius: DS.Shadow.hud.radius,
                    y: DS.Shadow.hud.y
                )
        }
        // Holding the pointer over an offer keeps it from fading while you decide.
        .onHover { controller.setHoveringReadAloud($0) }
        .padding(HUDPanel.shadowMargin)
    }

    /// One slot, three things it can be, in priority order: an error you must see, what
    /// the pill is busy doing, or the mode menu.
    ///
    /// The menu stays up while the passage plays, because that is when you decide the
    /// summary was too short — changing it mid-playback re-transforms and starts again, and
    /// a control that hides itself in the one state where it does something is no control.
    /// Showing the words being spoken would cost exactly that.
    @ViewBuilder
    private var readAloudCentre: some View {
        if let error = controller.readAloudError ?? speaker.failure {
            Text(error)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.caution)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let status = controller.readAloudStatus ?? voicingStatus {
            Text(status)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnHUDMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            modeMenu
        }
    }

    /// "Voicing" while a networked voice renders, which is the one stage `readAloudStatus`
    /// cannot see — it is cleared before `Speaker` is handed the text.
    private var voicingStatus: String? {
        speaker.isPreparing ? ReadingMode.voicingKeyword : nil
    }

    /// How fast it reads, as a multiple. One control for both engines: it is applied on
    /// playback, so it costs nothing and re-renders nothing to change mid-passage.
    private var speedMenu: some View {
        Menu {
            ForEach(ReadingMode.speeds, id: \.self) { speed in
                Button {
                    controller.setReadingSpeed(speed)
                } label: {
                    if speed == settings.readAloudSpeed {
                        Label(ReadingMode.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(ReadingMode.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(ReadingMode.speedLabel(settings.readAloudSpeed))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnHUDMuted)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A plain SwiftUI `Menu`. Native, so it survives being opened over another app's
    /// window and closes on Escape without the pill having to know about it.
    private var modeMenu: some View {
        Menu {
            ForEach(ReadingMode.allCases, id: \.self) { mode in
                Button {
                    controller.setReadingMode(mode)
                } label: {
                    if mode == settings.readingMode {
                        Label(menuLabel(mode), systemImage: "checkmark")
                    } else {
                        Text(menuLabel(mode))
                    }
                }
                // A custom mode with no instruction would send an empty prompt. Say why
                // it's unavailable by leaving it visible and dead rather than hiding it.
                .disabled(mode == .custom && settings.readingModeCustomInstruction
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(menuLabel(settings.readingMode))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnHUD)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Color.inkOnHUDMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The custom row shows the user's own label once they've given it one — "Custom…" is
    /// what you pick, not what you'd want to read back afterwards.
    private func menuLabel(_ mode: ReadingMode) -> String {
        guard mode == .custom else { return mode.displayName }
        let label = settings.readingModeCustomLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? mode.displayName : label
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    /// True once there are real words to read, which is when the label stops being
    /// interface chrome and becomes the transcript.
    private var hasTranscript: Bool {
        !isError && controller.notice == nil && !controller.transcript.isEmpty
    }

    // Errors are amber, not red: red in this app means recording, and a failed dictation
    // that lights the same lamp as a live one is worse than no lamp at all.
    private var textColor: Color {
        if isError { return DS.Color.caution }
        return hasTranscript ? DS.Color.inkOnHUD : DS.Color.inkOnHUDMuted
    }

    private var label: String {
        // Both of these can be true while the state is `.idle` — an on-demand rewrite runs
        // with no dictation behind it — so they are checked before the state at all.
        if let notice = controller.notice { return notice }
        if case .idle = controller.state, controller.isRewriting { return "Rewriting…" }

        switch controller.state {
        case .starting: return "Listening…"
        case .listening: return controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing:
            if controller.isRewriting { return "Rewriting…" }
            return controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): return message
        case .idle: return ""
        }
    }
}

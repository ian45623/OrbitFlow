import AVFoundation
import SwiftUI
import OrbitFlowModels

/// The three model choices, in one place.
///
/// Each job is its own `Surface` rather than a row in a shared one: a job is a distinct
/// object with its own state machine and its own download, not an item in a list. Depth
/// stays at one step — `Surface` is still the only container in the app.
struct AIModelsSection: View {
    @Bindable var settings: Settings
    /// Opens another Settings section — the Cloud cards send people to where keys live.
    let openSection: (SettingsSection) -> Void

    @State private var parakeet = ParakeetDownload.shared
    @State private var kokoro = KokoroDownload.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            speechPanel
            rewritePanel
            readAloudPanel
        }
    }

    // MARK: - The readout, shown in the section header

    /// `static` so the section header can draw the readout without building a view just
    /// to read a property off it. Everything it needs is in `Settings`.
    static func readout(for settings: Settings) -> ModelGrade.Readout {
        ModelGrade.readout(
            speech: settings.engine == .parakeet ? .local : .apple,
            rewrite: settings.rewriteSource,
            readAloud: source(of: settings.readAloudEngine),
            voice: voiceGrade(for: settings.readAloudVoice),
            // An override is always a cloud `AIProvider` (there is no on-device case to
            // override to) — see `OnDemandRewrite.source`. Without `readingMode.usesAI`
            // the override is never called, so both have to be true for this path to
            // actually leave the Mac.
            readAloudAIOverrideIsCloud:
                settings.readingMode.usesAI && settings.readAloudProviderOverride != nil
        )
    }

    /// Read aloud's source is `readAloudEngine` — one property, three cases, no second
    /// property that could disagree with it.
    static func source(of engine: VoiceEngine) -> ModelSource {
        switch engine {
        case .system: .apple
        case .kokoro: .local
        case .elevenLabs: .cloud
        }
    }

    /// "Apple TTS" is not one product. The grade follows whichever voice is selected,
    /// using the same `quality` the picker already labels voices with.
    static func voiceGrade(for identifier: String?) -> VoiceGrade {
        guard let identifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier)
        else { return .standard }
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }

    private var readAloudSource: ModelSource { Self.source(of: settings.readAloudEngine) }

    // MARK: - Speech to text

    private var speechPanel: some View {
        panel(
            name: "Speech to text",
            why: "What turns your voice into words.",
            selection: Binding(
                get: { settings.engine == .parakeet ? ModelSource.local : .apple },
                set: { settings.engine = $0 == .local ? .parakeet : .apple }
            ),
            disabled: [.cloud: "Orbit Flow has no cloud speech engine. Audio never leaves this Mac."]
        ) {
            if settings.engine == .parakeet {
                ModelStateCard(model: parakeet, isRecommended: true)
            } else {
                plain(
                    "Apple",
                    "Apple's on-device transcriber. Streams text while you speak, and "
                        + "needs no download."
                )
            }
        }
    }

    // MARK: - Rewrite

    private var rewritePanel: some View {
        panel(
            name: "Rewrite",
            why: "What turns a rambling note into a clear one.",
            selection: $settings.rewriteSource,
            disabled: [.local: "Apple Intelligence is the local model. It already runs on this Mac."]
        ) {
            switch settings.rewriteSource {
            case .cloud:
                cloudCard(
                    name: settings.aiProvider.displayName,
                    detail: settings.aiModel.isEmpty
                        ? "No model chosen yet."
                        : "\(settings.aiModel). Your text is sent to \(settings.aiProvider.displayName) to be rewritten.",
                    hasKey: KeyStore.hasKey(account: settings.aiProvider.rawValue),
                    opens: .cleanupAI
                )
            case .apple, .local:
                plain(
                    "Apple Intelligence",
                    OnDeviceRewriter.isAvailable
                        ? "Apple's on-device model. Nothing leaves this Mac, and there is "
                            + "nothing to download."
                        : (OnDeviceRewriter.unavailableReason ?? "Unavailable on this Mac.")
                )
            }
        }
    }

    // MARK: - Read aloud

    private var readAloudPanel: some View {
        panel(
            name: "Read aloud",
            why: "What reads highlighted text back.",
            selection: Binding(
                get: { readAloudSource },
                set: {
                    settings.readAloudEngine = switch $0 {
                    case .apple: .system
                    case .local: .kokoro
                    case .cloud: .elevenLabs
                    }
                }
            ),
            disabled: KokoroModels.isSupportedOS ? [:] : [.local: KokoroModels.unsupportedOSReason]
        ) {
            switch settings.readAloudEngine {
            case .kokoro:
                ModelStateCard(model: kokoro, isRecommended: true)
            case .elevenLabs:
                cloudCard(
                    name: "ElevenLabs",
                    detail: "Your text is sent to ElevenLabs to be spoken.",
                    hasKey: KeyStore.hasKey(account: Speaker.keyAccount),
                    opens: .readAloud
                )
            case .system:
                plain(
                    "Apple",
                    "The system voices. Premium and Enhanced voices sound far more "
                        + "natural — install them in System Settings."
                )
            }
        }
    }

    // MARK: - Shared shapes

    private func panel<Content: View>(
        name: String,
        why: String,
        selection: Binding<ModelSource>,
        disabled: [ModelSource: String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                    Text(name)
                        .font(DS.Font.display)
                        .foregroundStyle(DS.Color.ink)
                    Text(why)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                }

                sourcePicker(selection: selection, disabled: disabled)

                Hairline()
                content()
            }
            .padding(DS.Space.roomy)
        }
    }

    /// A `Segmented` that can refuse.
    ///
    /// A segment with nothing behind it stays on screen so the three rows line up, but it
    /// cannot be picked and its tooltip says why. Both messages tell the user something
    /// true they may not know, which is why this beats hiding them.
    private func sourcePicker(
        selection: Binding<ModelSource>,
        disabled: [ModelSource: String]
    ) -> some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(ModelSource.allCases, id: \.self) { source in
                let reason = disabled[source]
                Button {
                    if reason == nil { withAnimation(DS.Motion.panel) { selection.wrappedValue = source } }
                } label: {
                    Text(source.displayName)
                        .font(DS.Font.label)
                        .foregroundStyle(
                            reason != nil
                                ? DS.Color.inkFaint
                                : (selection.wrappedValue == source ? DS.Color.ink : DS.Color.inkMuted)
                        )
                        .padding(.horizontal, DS.Space.base)
                        .padding(.vertical, DS.Space.snug)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection.wrappedValue == source, reason == nil {
                                RoundedRectangle(cornerRadius: DS.Radius.control)
                                    .fill(DS.Color.surface)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(reason != nil)
                .help(reason ?? "")
            }
        }
        .padding(DS.Space.hair)
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
        .frame(maxWidth: 330)
    }

    private func plain(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Text(name)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cloudCard(
        name: String,
        detail: String,
        hasKey: Bool,
        opens section: SettingsSection
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(name)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.snug) {
                    StatusDot(color: hasKey ? DS.Color.positive : DS.Color.caution, isOn: true)
                    MetaLabel(text: hasKey ? "Key saved" : "No key saved")
                }
                .padding(.top, DS.Space.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ActionButton(title: "Configure", kind: .secondary) { openSection(section) }
        }
    }
}

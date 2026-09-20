import SwiftUI

/// One downloadable model: what it is, what state it is in, and the one thing to do next.
///
/// Renders any `ManagedModel`, so Parakeet and Kokoro are one component rather than two
/// copies that drift. The status line is words as well as a dot, because hue never
/// carries state on its own (rule 01).
struct ModelStateCard<Model: ManagedModel>: View {
    let model: Model
    var isRecommended = false

    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.snug) {
                    Text(model.displayName)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    if isRecommended { Tag(text: "Recommended") }
                }
                Text(model.summary)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .ready:
            HStack(spacing: DS.Space.snug) {
                StatusDot(color: DS.Color.positive, isOn: true)
                MetaLabel(text: model.installedSize.map {
                    "Ready — \(Self.byteCount($0)) on this Mac"
                } ?? "Ready")
            }
            .padding(.top, DS.Space.tight)

        case .working(let label, let fraction):
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                MetaLabel(text: "\(label) — \(Int(fraction * 100))%")
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.ink)
                    .frame(maxWidth: 300)
                Text("This keeps going if you close the window.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
            }
            .padding(.top, DS.Space.tight)

        case .failed(let message):
            HStack(alignment: .top, spacing: DS.Space.snug) {
                StatusDot(color: DS.Color.signal, isOn: true)
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DS.Space.tight)

        case .unavailable(let reason):
            // Same look as `.failed` — a dot plus the reason in words, never color alone.
            // `action` below may still offer Remove: "can't run here" and "can't reclaim
            // the space it's using" are different claims, and only the first is true here.
            HStack(alignment: .top, spacing: DS.Space.snug) {
                StatusDot(color: DS.Color.signal, isOn: true)
                Text(reason)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DS.Space.tight)

        case .missing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.phase {
        case .missing:
            ActionButton(title: "Download \(model.downloadSize)", kind: .primary) {
                model.start()
            }
        case .failed:
            ActionButton(title: "Try again", kind: .primary) { model.start() }
        case .working:
            EmptyView()
        case .unavailable:
            // Nothing the user does here makes the model runnable again — but if an
            // earlier, supported OS already downloaded it, the bytes are still sitting on
            // disk, and reclaiming them is a real, honest action distinct from "use it".
            if model.installedSize != nil {
                removeButton
            } else {
                EmptyView()
            }
        case .ready:
            removeButton
        }
    }

    /// Shared by `.ready` and `.unavailable` (when there's something on disk to free):
    /// same button, same confirmation, only the promise afterward differs — see
    /// `removeMessage`.
    private var removeButton: some View {
        ActionButton(title: "Remove", kind: .quiet) { isConfirmingRemove = true }
            .confirmationDialog(
                "Remove \(model.displayName)?",
                isPresented: $isConfirmingRemove
            ) {
                Button("Remove", role: .destructive) { model.removeFromDisk() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removeMessage)
            }
    }

    /// `.ready` can re-download from this same card whenever it wants; `.unavailable`
    /// can't — removing the files doesn't change whatever makes it unavailable — so the
    /// two states can't share one closing line without one of them lying.
    private var removeMessage: String {
        let freed = "Frees \(model.installedSize.map(Self.byteCount) ?? model.downloadSize). "
        if case .unavailable = model.phase {
            return freed + "It won't offer to download again until it can run on this Mac."
        }
        return freed + "You can download it again from here at any time."
    }

    /// Bytes as the Finder would say them.
    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

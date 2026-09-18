import OrbitFlowHistory
import SwiftUI

/// The middle pane: search, then the dictations grouped into the stretches of work they
/// happened in.
///
/// A session header carries the app and the span; the rows under it carry the time, the
/// latency and what became of the text. Rows are separated rather than boxed — a transcript
/// history reads as one document, and a stack of cards would fight the prose inside them.
struct SessionList: View {
    let items: [HistoryItem]
    @Binding var selection: UUID?
    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding
    let isHistoryEmpty: Bool
    let shortcutSummary: String

    @State private var store = RunStore.shared
    @State private var isConfirmingClear = false
    /// The compose box for pasted text. A flag plus a plain string, deliberately: an
    /// optional draft means the editor's binding changes identity as the box closes, and
    /// a text view whose binding is swapped out from under it while it still holds focus
    /// is how this crashed.
    @State private var isComposing = false
    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    SearchField(text: $query, placeholder: "Search everything")
                        .focused(isSearchFocused)
                    ActionButton(title: "Add text", systemImage: "plus", kind: .quiet) {
                        if isComposing { closeComposer() } else { isComposing = true }
                    }
                }
                if isComposing { composer }
            }
            .padding(DS.Space.base)

            Hairline()

            if items.isEmpty {
                EmptyPanel(
                    label: isHistoryEmpty ? "Nothing yet" : "No matches",
                    detail: isHistoryEmpty
                        ? "Hold \(shortcutSummary) and talk."
                        : "Nothing here matches that."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Hairline()
                        }
                    }
                }
                footer
            }
        }
        .background(DS.Color.canvas)
    }

    /// Text that was never spoken — pasted or typed in. It becomes an ordinary row, so
    /// everything the list and the detail page can do applies to it too.
    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            ProseEditor(text: $draft, minHeight: 88)
                .focused($isDraftFocused)
            HStack {
                Spacer()
                ActionButton(title: "Cancel", kind: .quiet, action: closeComposer)
                ActionButton(title: "Add", kind: .primary, isEnabled: !draft.trimmed.isEmpty) {
                    RunLog.record(
                        DictationRun(
                            date: Date(),
                            engine: "Pasted",
                            audioSeconds: 0,
                            processSeconds: 0,
                            text: draft.trimmed
                        )
                    )
                    closeComposer()
                }
            }
        }
        .onAppear { isDraftFocused = true }
    }

    /// Focus leaves the text view *before* the view goes away. Tearing down a focused
    /// NSTextView is the crash this avoids.
    private func closeComposer() {
        isDraftFocused = false
        draft = ""
        isComposing = false
    }

    private var footer: some View {
        HStack {
            MetaLabel(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            Spacer()
            ActionButton(title: "Delete all", kind: .quiet) { isConfirmingClear = true }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Hairline() }
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        let run = store.runs.first { $0.id == item.id }
        return Button {
            selection = item.id
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                HStack(spacing: DS.Space.snug) {
                    MetaLabel(text: time(item.date))
                    MetaLabel(text: String(format: "%.2fs", run?.processSeconds ?? 0))
                    Spacer()
                    if item.isPinned {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(DS.Color.ink)
                    }
                    if item.wasRewritten {
                        MetaLabel(text: "Rewritten")
                    } else if item.corrections > 0 {
                        MetaLabel(text: "Corrected ×\(item.corrections)")
                    }
                }
                // No `fixedSize` with a line limit: it sizes the row to the *whole*
                // transcript's height and then draws only three lines of it, which is where
                // the empty space under every short row came from.
                Text(run?.text ?? "")
                    .font(DS.Font.prose)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == item.id ? DS.Color.surfaceHover : .clear)
            // The selected row is marked on its leading edge rather than by colour: hue
            // never carries state (rule 01), and a tinted row would compete with the pill.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selection == item.id ? DS.Color.ink : .clear)
                    .frame(width: DS.Border.emphasis)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

}

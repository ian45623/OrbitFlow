import OrbitFlowDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a tag on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.base) {
                SearchField(text: $query, placeholder: "Search dictionary")
                ActionButton(title: "Add word", systemImage: "plus", kind: .secondary) {
                    isAdding = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, DS.Space.wide)
            .padding(.vertical, DS.Space.base)

            Hairline()

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Nothing taught yet" : "No matches",
                    detail: store.entries.isEmpty
                        ? "Add the words it keeps getting wrong — names, jargon, anything it mishears."
                        : "No entry contains “\(query)”."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            DictionaryRow(
                                entry: entry,
                                onEdit: { editing = entry },
                                onToggle: {
                                    var updated = entry
                                    updated.isEnabled.toggle()
                                    store.update(updated)
                                },
                                onDelete: { store.delete(entry) }
                            )
                            if entry.id != entries.last?.id { Hairline() }
                        }
                    }
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    /// The file path is reachable because the spec asks for the dictionary to be editable
    /// outside the UI — which is only true if you can find it.
    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            FieldLabel(
                text: "\(store.entries.count) entr\(store.entries.count == 1 ? "y" : "ies")",
                color: DS.Color.inkFaint
            )
            Spacer()
            ActionButton(title: "Show dictionary file", kind: .quiet) {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            }
            .help(DictionaryStore.fileURL.path)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            StatusDot(isOn: entry.isEnabled)

            Tag(text: entry.kind == .correction ? "Fix" : "Term", color: DS.Color.inkFaint)
                .frame(width: 46, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkMuted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkFaint)
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            Spacer()

            // Kept in the layout and faded rather than inserted on hover, so the row
            // holds one height and the list doesn't shift under the pointer.
            HStack(spacing: DS.Space.base) {
                ActionButton(title: "Edit", kind: .quiet, action: onEdit)
                ActionButton(title: entry.isEnabled ? "Turn off" : "Turn on", kind: .quiet, action: onToggle)
                ActionButton(title: "Delete", kind: .quiet, action: onDelete)
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? DS.Color.surfaceHover : DS.Color.canvas)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            Text(entry == nil ? "Teach it a word" : "Edit this entry")
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.ink)

            Segmented(
                options: [(DictionaryEntry.Kind.term, "Term"), (.correction, "Correction")],
                selection: $kind
            )

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    EntryField(label: "When you say", text: $hear, prompt: "cloud code")
                }
                EntryField(
                    label: kind == .correction ? "Write instead" : "Word or phrase",
                    text: $write,
                    prompt: kind == .correction ? "Claude Code" : "Anthropic"
                )
            }

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    StatusDot(color: DS.Color.caution, isOn: true)
                        .padding(.top, DS.Space.tight)
                    Text(warning.message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                ActionButton(title: "Cancel", kind: .quiet) { dismiss() }
                ActionButton(title: "Save", kind: .primary, isEnabled: isValid) {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 460)
        .background(DS.Color.surface)
    }
}

import OrbitFlowDictionary
import AppKit
import SwiftUI

/// The dictionary: what it knows, and what each thing it knows has actually done.
///
/// Both entry kinds live in one table rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. What's new here is the
/// evidence beside each row: an entry that has never fired and one that fires twenty times a
/// day used to look identical.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var runs = RunStore.shared
    @State private var query = ""
    @State private var kindFilter: KindFilter = .all
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false
    /// The risky entry whose explanation is open, if any.
    @State private var explaining: UUID?

    enum KindFilter: Hashable { case all, words, corrections }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            columnHeadings
            Hairline()

            if visible.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Nothing taught yet" : "No matches",
                    detail: store.entries.isEmpty
                        ? "Add the words it keeps getting wrong — names, jargon, anything it mishears."
                        : "Nothing here matches that."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            DictionaryRow(
                                entry: entry,
                                evidence: evidence[entry.id] ?? EntryEvidence(hits: 0, lastFired: nil),
                                risk: risk(for: entry),
                                isExplaining: explaining == entry.id,
                                onExplain: {
                                    withAnimation(DS.Motion.panel) {
                                        explaining = explaining == entry.id ? nil : entry.id
                                    }
                                },
                                onRequirePhrase: {
                                    var updated = entry
                                    updated.requiresPhrase = true
                                    store.update(updated)
                                    explaining = nil
                                },
                                onEdit: { editing = entry },
                                onToggle: {
                                    var updated = entry
                                    updated.isEnabled.toggle()
                                    store.update(updated)
                                },
                                onDelete: { store.delete(entry) }
                            )
                            Hairline()
                        }
                        if !suggestions.isEmpty { suggestionRow }
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

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: DS.Space.base) {
            SearchField(text: $query, placeholder: "Search entries")
            Segmented(
                options: [(KindFilter.all, "All"), (.words, "Words"), (.corrections, "Corrections")],
                selection: $kindFilter
            )
            ActionButton(title: "Add entry", systemImage: "plus", kind: .primary) {
                isAdding = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.base)
    }

    private var columnHeadings: some View {
        HStack(spacing: DS.Space.base) {
            MetaLabel(text: "Type").frame(width: 52, alignment: .leading)
            MetaLabel(text: "Entry")
            Spacer()
            MetaLabel(text: "Hits").frame(width: 60, alignment: .trailing)
            MetaLabel(text: "Last fired").frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
    }

    /// The file path is reachable because the spec asks for the dictionary to be editable
    /// outside the UI — which is only true if you can find it.
    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            MetaLabel(text: "\(store.entries.count) entr\(store.entries.count == 1 ? "y" : "ies") · plain text file")
            Spacer()
            ActionButton(title: "Show file", kind: .quiet) {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            }
            .help(DictionaryStore.fileURL.path)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Hairline() }
    }

    /// Fixes made by hand often enough to be worth teaching. Adding one is a single click,
    /// which is the point — this is the entry someone meant to make and didn't.
    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            MetaLabel(text: "Suggested from your history")
            Flow(spacing: DS.Space.snug) {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: DS.Space.snug) {
                        Text("you fixed “\(suggestion.hear)” → \(suggestion.write)")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.ink)
                        MetaLabel(text: "\(suggestion.times)×")
                        ActionButton(title: "Add", kind: .secondary) {
                            store.add(.correction(hear: suggestion.hear, write: suggestion.write))
                        }
                    }
                    .padding(.horizontal, DS.Space.base)
                    .padding(.vertical, DS.Space.snug)
                    .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control))
                }
            }
        }
        .padding(DS.Space.wide)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived

    private var visible: [DictionaryEntry] {
        store.filtered(by: query).filter { entry in
            switch kindFilter {
            case .all: true
            case .words: entry.kind == .term
            case .corrections: entry.kind == .correction
            }
        }
    }

    private var evidence: [UUID: EntryEvidence] {
        DictionaryEvidence.evidence(
            for: store.entries,
            in: runs.runs.compactMap { run in
                guard let corrections = run.corrections, !corrections.isEmpty else { return nil }
                return CorrectionRecord(date: run.date, corrections: corrections)
            }
        )
    }

    private var suggestions: [Suggestion] {
        DictionaryEvidence.suggestions(
            from: runs.runs.compactMap { run in
                // Only runs the user actually edited: `original` is kept when the stored
                // text stopped matching what the engine heard.
                guard let original = run.original, original != run.text else { return nil }
                return (original: original, corrected: run.text)
            },
            existing: store.entries
        )
    }

    /// macOS's spell checker is the only list of real words on hand, and asking it is what
    /// tells "super base" (also the word "superbase") from "tee see util" (not a word).
    private func risk(for entry: DictionaryEntry) -> DictionaryRisk? {
        DictionaryEvidence.risk(of: entry) { word in
            let checker = NSSpellChecker.shared
            let range = checker.checkSpelling(of: word, startingAt: 0)
            return range.location == NSNotFound
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let evidence: EntryEvidence
    let risk: DictionaryRisk?
    let isExplaining: Bool
    let onExplain: () -> Void
    let onRequirePhrase: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExplaining, let risk { explanation(risk) }
        }
        .background(isHovering ? DS.Color.surfaceHover : DS.Color.canvas)
        .onHover { isHovering = $0 }
    }

    private var row: some View {
        HStack(spacing: DS.Space.base) {
            MetaLabel(text: entry.kind == .correction ? "Fix" : "Word")
                .frame(width: 52, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkFaint)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkFaint)
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            if risk != nil {
                Button(action: onExplain) {
                    Tag(text: "Risky", color: DS.Color.caution)
                }
                .buttonStyle(.plain)
            } else if entry.kind == .correction, evidence.hits == 0 {
                Tag(text: "Never fired", color: DS.Color.inkFaint)
            }

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

            MetaLabel(text: entry.kind == .correction ? "\(evidence.hits)" : "—", reserving: 4)
                .frame(width: 60, alignment: .trailing)
            MetaLabel(text: lastFired, reserving: 9)
                .frame(width: 90, alignment: .trailing)
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explanation(_ risk: DictionaryRisk) -> some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Text(risk.message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if risk.alsoMatches != nil {
                ActionButton(title: "Require phrase", kind: .primary, action: onRequirePhrase)
            }
            ActionButton(title: "Keep as is", kind: .quiet, action: onExplain)
        }
        .padding(DS.Space.base)
        .background(DS.Color.caution.opacity(0.10), in: .rect(cornerRadius: DS.Radius.control))
        .padding(.horizontal, DS.Space.wide)
        .padding(.bottom, DS.Space.base)
    }

    /// Time today, weekday this week, date beyond that — a timestamp is read at a glance or
    /// not at all.
    private var lastFired: String {
        guard let date = evidence.lastFired else { return "—" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if date > Date().addingTimeInterval(-7 * 24 * 60 * 60) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
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
    @State private var requiresPhrase: Bool

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
        _requiresPhrase = State(initialValue: entry?.requiresPhrase ?? false)
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true,
            requiresPhrase: kind == .correction && requiresPhrase
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

            // Only meaningful for a phrase: a single-word trigger has no gap to require.
            if kind == .correction, draft.hear.contains(where: { $0 == " " || $0 == "-" }) {
                Toggle(isOn: $requiresPhrase) {
                    Text("Only match the full phrase")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                }
                .toggleStyle(.switch)
                Text("Off, “\(draft.hear)” also matches it written as one word.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkMuted)
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

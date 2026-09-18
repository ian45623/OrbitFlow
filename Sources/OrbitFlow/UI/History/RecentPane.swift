import OrbitFlowHistory
import OrbitFlowHotkey
import SwiftUI

/// What used to be History: everything dictated, but arranged the way it happened — in
/// sessions, in the apps it landed in, filtered by what became of it.
///
/// Three panes rather than a list and a detail page. The middle pane is still the list, but
/// the rail on the left answers "where did that go" without a search, and the detail stays
/// on screen while you move through the rows next to it.
struct RecentPane: View {
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var route = MainRoute.shared
    @State private var filter: HistoryFilter = .everything
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            FilterRail(
                filter: $filter,
                counts: History.counts(for: items),
                destinations: History.destinations(in: items)
            )
            Hairline(vertical: true)
            SessionList(
                sessions: sessions,
                selection: $selection,
                query: $query,
                isSearchFocused: $isSearchFocused,
                isHistoryEmpty: store.runs.isEmpty,
                shortcutSummary: ShortcutKeys.displaySummary(settings.shortcutKeys)
            )
            .frame(width: 340)
            Hairline(vertical: true)
            detail
        }
        .background(DS.Color.canvas)
        .onChange(of: route.openRun) { _, opened in
            // "Open in Orbit Flow" from the Services menu selects the run it opened, which
            // is the same thing clicking it here does.
            if let opened { selection = opened }
        }
        .onAppear { if selection == nil { selection = sessions.first?.items.first?.id } }
        .background {
            // Shortcut hosts. Buttons rather than `.keyboardShortcut` on the views
            // themselves, because the rail advertises these three and they have to work
            // wherever focus happens to be inside this tab.
            Group {
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { copySelection() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { rewriteSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            .opacity(0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, store.runs.contains(where: { $0.id == selection }) {
            TranscriptionDetail(runID: selection) {
                // Closing the detail returns to a wider list rather than an empty pane.
                self.selection = nil
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyPanel(
                label: store.runs.isEmpty ? "Nothing dictated yet" : "Nothing selected",
                detail: store.runs.isEmpty
                    ? "Hold \(ShortcutKeys.displaySummary(settings.shortcutKeys)) and talk. What you say lands here."
                    : "Pick a dictation to read it, rewrite it, or hear it back."
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// Every run as the history target sees it: newest first, filtered, then searched.
    /// Search runs last so "everything matching 'migration' that landed in Cursor" works.
    private var items: [HistoryItem] {
        store.runs.map { run in
            HistoryItem(
                id: run.id,
                date: run.date,
                destination: run.destinationApp,
                words: run.text.split(whereSeparator: \.isWhitespace).count,
                isPinned: run.isPinned ?? false,
                wasRewritten: !(run.rewrites ?? []).isEmpty,
                corrections: run.corrections?.count ?? 0
            )
        }
    }

    private var sessions: [HistorySession] {
        let filtered = History.matching(filter, in: items)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return History.sessions(filtered) }
        let matching = filtered.filter { item in
            store.runs.first { $0.id == item.id }?.text.localizedStandardContains(trimmed) ?? false
        }
        return History.sessions(matching)
    }

    private func copySelection() {
        guard let selection, let run = store.runs.first(where: { $0.id == selection }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.text, forType: .string)
    }

    private func rewriteSelection() {
        guard let selection else { return }
        route.openRun = selection
        MainRoute.shared.rewriteRequest = selection
    }
}

/// The rail: what happened to a dictation, and where it went.
struct FilterRail: View {
    @Binding var filter: HistoryFilter
    let counts: [HistoryFilter: Int]
    let destinations: [(name: String, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("View")
            row(.everything, "Everything")
            row(.pinned, "Pinned")
            row(.rewritten, "Rewritten")
            row(.corrected, "Corrected")
            row(.longForm, "Long form")

            if !destinations.isEmpty {
                heading("Landed in")
                ForEach(destinations, id: \.name) { destination in
                    row(.destination(destination.name), destination.name, count: destination.count)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                MetaLabel(text: "⌘F  Search")
                MetaLabel(text: "⌘⏎  Copy")
                MetaLabel(text: "⌘⌥R  Rewrite")
            }
            .padding(DS.Space.roomy)
        }
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Color.surface)
    }

    private func heading(_ text: String) -> some View {
        MetaLabel(text: text)
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.roomy)
            .padding(.bottom, DS.Space.snug)
    }

    private func row(_ candidate: HistoryFilter, _ label: String, count: Int? = nil) -> some View {
        Button {
            filter = candidate
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(label)
                    .font(filter == candidate ? DS.Font.bodyEmphasis : DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.tight)
                MetaLabel(text: "\(count ?? counts[candidate] ?? 0)")
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(filter == candidate ? DS.Color.surfaceHover : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.snug)
    }
}

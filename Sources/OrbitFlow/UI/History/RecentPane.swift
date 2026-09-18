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
            FilterRail(filter: $filter, counts: History.counts(for: items))
                .layoutPriority(2)
            Hairline(vertical: true)
            SessionList(
                items: visibleItems,
                selection: $selection,
                query: $query,
                isSearchFocused: $isSearchFocused,
                isHistoryEmpty: store.runs.isEmpty,
                shortcutSummary: ShortcutKeys.displaySummary(settings.shortcutKeys)
            )
            .frame(width: 340)
            .layoutPriority(1)
            Hairline(vertical: true)
            detail
        }
        .background(DS.Color.canvas)
        .onChange(of: route.openRun) { _, opened in
            // "Open in Orbit Flow" from the Services menu selects the run it opened, which
            // is the same thing clicking it here does.
            if let opened { selection = opened }
        }
        .onAppear { if selection == nil { selection = visibleItems.first?.id } }
        .background {
            // Shortcut hosts. Buttons rather than `.keyboardShortcut` on the views
            // themselves, because the rail advertises these three and they have to work
            // wherever focus happens to be inside this tab.
            Group {
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { rewriteSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            .frame(width: 0, height: 0)
            // Invisible is not untouchable: `opacity(0)` alone leaves these buttons in the
            // hit-test path, where they sit behind the middle of the pane and swallow
            // clicks meant for the rows.
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, store.runs.contains(where: { $0.id == selection }) {
            TranscriptionDetail(runID: selection) {
                // Closing the detail returns to a wider list rather than an empty pane.
                self.selection = nil
            }
            // Identity follows the run. Without this the pane keeps one view — and one set
            // of editor state — across every selection, which is how an edit to one
            // transcript could land on another.
            .id(selection)
            .frame(minWidth: 360, maxWidth: .infinity)
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
        store.runs.map(\.historyItem)
    }

    /// Filtered, then searched, newest first. One flat list: dictations arrive one at a
    /// time and reading them in order is the whole job — grouping them into sessions put a
    /// header between rows that belong together.
    private var visibleItems: [HistoryItem] {
        let filtered = History.matching(filter, in: items)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = trimmed.isEmpty ? filtered : filtered.filter { item in
            store.runs.first { $0.id == item.id }?.text.localizedStandardContains(trimmed) ?? false
        }
        return matching.sorted { $0.date > $1.date }
    }

    private func rewriteSelection() {
        guard let selection else { return }
        route.openRun = selection
        MainRoute.shared.rewriteRequest = selection
    }
}

/// The rail: what happened to a dictation.
///
/// Collapses to a strip of icons rather than disappearing. A pane that can vanish entirely
/// leaves nothing to click to bring it back, and the filters are how you find anything in a
/// few hundred dictations — they should still be one click away when the rail is narrow.
struct FilterRail: View {
    @Binding var filter: HistoryFilter
    let counts: [HistoryFilter: Int]

    /// Collapsed state lives in defaults rather than in view state: a rail someone closed
    /// should stay closed after a relaunch, and this is a preference, not a mode.
    @AppStorage("recentFilterRailOpen") private var isOpen = true

    private struct Item {
        let filter: HistoryFilter
        let label: String
        let icon: String
    }

    private let items: [Item] = [
        Item(filter: .everything, label: "Everything", icon: "tray.full"),
        Item(filter: .pinned, label: "Pinned", icon: "pin"),
        Item(filter: .rewritten, label: "Rewritten", icon: "wand.and.sparkles"),
        Item(filter: .corrected, label: "Corrected", icon: "character.cursor.ibeam"),
        Item(filter: .longForm, label: "Long form", icon: "text.alignleft"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggle

            ForEach(items, id: \.label) { item in
                row(item)
            }

            Spacer()

            if isOpen {
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    MetaLabel(text: "⌘F  Search")
                    MetaLabel(text: "⌘C  Copy")
                    MetaLabel(text: "⌘⌥R  Rewrite")
                }
                .padding(DS.Space.roomy)
            }
        }
        .frame(width: isOpen ? 200 : 52, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Color.surface)
        // Fixed, and it means it: without this the transcript's ideal width won the layout
        // and the rail was pushed off the left edge of the window.
        .fixedSize(horizontal: true, vertical: false)
        .animation(DS.Motion.panel, value: isOpen)
    }

    private var toggle: some View {
        Button {
            withAnimation(DS.Motion.panel) { isOpen.toggle() }
        } label: {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: isOpen ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Color.inkMuted)
                    .frame(width: 16)
                if isOpen {
                    MetaLabel(text: "View")
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide the filters" : "Show the filters")
        .padding(.horizontal, DS.Space.snug)
        .padding(.top, DS.Space.base)
        .padding(.bottom, DS.Space.snug)
    }

    private func row(_ item: Item) -> some View {
        let isCurrent = filter == item.filter
        let count = counts[item.filter] ?? 0
        return Button {
            filter = item.filter
        } label: {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? DS.Color.ink : DS.Color.inkMuted)
                    .frame(width: 16)
                if isOpen {
                    Text(item.label)
                        .font(isCurrent ? DS.Font.bodyEmphasis : DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.tight)
                    MetaLabel(text: "\(count)")
                }
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(isCurrent ? DS.Color.surfaceHover : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The count goes in the tooltip when the labels are gone, so a collapsed rail still
        // answers "how many pinned?" without reopening it.
        .help(isOpen ? item.label : "\(item.label) — \(count)")
        .padding(.horizontal, DS.Space.snug)
    }
}

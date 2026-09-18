import OrbitFlowDictionary
import OrbitFlowHistory
import OrbitFlowHotkey
import Foundation

/// One rewrite of a transcription, kept so the detail page can stack them.
///
/// Persisted rather than held in the view: a rewrite costs a round-trip and sometimes
/// money, and losing every variant by clicking Back would make the page useless for
/// comparing them. `instruction` and `engine` are recorded because a stack of texts with
/// no note of what produced each one is unreadable a day later.
struct Rewrite: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    /// The mode's name, or the instruction the user typed.
    let instruction: String
    /// What produced it — "Anthropic · claude-sonnet-4-5", or "Apple on-device".
    let engine: String
    /// The text this ran on, which may be a corrected original rather than what was said.
    let source: String
    let text: String
}

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    var text: String
    /// Shared by every engine that processed the same recording, so the dashboard can
    /// present them as one side-by-side comparison instead of unrelated rows.
    var group: String?

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?

    /// Every rewrite run against this transcription, oldest first — including the one
    /// made at dictation time. Optional for the same backwards-compatibility reason as
    /// `corrections`.
    var rewrites: [Rewrite]?

    /// The app the text landed in, and its bundle identifier. Captured when the key goes
    /// down rather than at insertion: a cloud rewrite can take seconds, and by the time the
    /// text lands the user may have moved on to another window.
    ///
    /// Optional for backwards compatibility, like `corrections` — runs recorded before this
    /// existed group under "Unknown" rather than disappearing from a filter.
    var destinationApp: String?
    var destinationBundleID: String?

    /// Kept deliberately, so it survives a "delete all" prompt's twin: the filter rail.
    var isPinned: Bool?

    /// The transcript as the engine heard it, kept only when cleanup actually changed it,
    /// so history can show the rewrite next to what was really said. Optional for the same
    /// backwards-compatibility reason as `corrections`.
    var original: String?

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        group: String? = nil,
        corrections: [AppliedCorrection]? = nil,
        original: String? = nil,
        rewrites: [Rewrite]? = nil,
        destinationApp: String? = nil,
        destinationBundleID: String? = nil,
        isPinned: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.group = group
        self.corrections = corrections
        self.original = original
        self.rewrites = rewrites
        self.destinationApp = destinationApp
        self.destinationBundleID = destinationBundleID
        self.isPinned = isPinned
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
        original = try container.decodeIfPresent(String.self, forKey: .original)
        rewrites = try container.decodeIfPresent([Rewrite].self, forKey: .rewrites)
        // Absent in every line written before destinations and pinning existed. Decoded
        // leniently for the same reason `corrections` is: failing the line would throw away
        // the user's history to add a column.
        destinationApp = try container.decodeIfPresent(String.self, forKey: .destinationApp)
        destinationBundleID = try container.decodeIfPresent(String.self, forKey: .destinationBundleID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
    }
}

extension DictationRun {
    /// This run reduced to the facts history sorts, filters and expires by.
    var historyItem: HistoryItem {
        HistoryItem(
            id: id,
            date: date,
            destination: destinationApp,
            words: text.split(whereSeparator: \.isWhitespace).count,
            isPinned: isPinned ?? false,
            wasRewritten: !(rewrites ?? []).isEmpty,
            corrections: corrections?.count ?? 0
        )
    }
}

/// Appends every dictation to a JSONL file and regenerates a dashboard beside it.
///
/// The dashboard is a plain file with a meta-refresh rather than a served page: `file://`
/// can't fetch its own data directory without tripping CORS, so instead of the page pulling
/// data, the app pushes a freshly rendered page after each run and the browser just reloads.
@MainActor
enum RunLog {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbitFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var dashboardURL: URL { directory.appendingPathComponent("dashboard.html") }
    private static var runsURL: URL { directory.appendingPathComponent("runs.jsonl") }

    static func record(_ run: DictationRun) {
        append(run)
        published()
    }

    static func record(_ runs: [DictationRun]) {
        runs.forEach(append)
        published()
    }

    /// Everything a write owes the rest of the app: trim to the retention setting, then
    /// republish the dashboard and the Recent pane.
    ///
    /// The guard is not an optimisation for its own sake — `enforceRetention` deletes by
    /// rewriting the whole file, and doing that unconditionally would turn every
    /// dictation's append into a full rewrite plus a second dashboard render.
    private static func published() {
        guard !enforceRetention() else { return }
        regenerate()
        RunStore.shared.reload()
    }

    /// Deletes whatever has fallen past `Settings.retentionPolicy`.
    ///
    /// Returns whether anything went — and when it did, the file has already been
    /// rewritten, the dashboard regenerated and the store reloaded, so the caller owes
    /// nothing further.
    @discardableResult
    static func enforceRetention() -> Bool {
        let policy = Settings.shared.retentionPolicy
        guard policy.limit != nil else { return false }

        let runs = load()
        let expired = History.expired(from: runs.map(\.historyItem), policy: policy)
        guard !expired.isEmpty else { return false }

        rewrite(runs.filter { !expired.contains($0.id) })
        return true
    }

    private static func append(_ run: DictationRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(run) else { return }
        line.append(0x0A) // newline

        if let handle = try? FileHandle(forWritingTo: runsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: runsURL)
        }
    }

    static func load() -> [DictationRun] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DictationRun.self, from: Data(line))
        }
    }

    static func regenerate() {
        let runs = load()
        try? DashboardHTML.render(
            runs: runs,
            compareMode: Settings.shared.compareMode,
            key: ShortcutKeys.displaySummary(Settings.shared.shortcutKeys)
        ).write(to: dashboardURL, atomically: true, encoding: .utf8)
    }

    /// Changes one run in place, on the stored copy rather than on the caller's.
    ///
    /// Read-modify-write of the file, deliberately: a detail page holds a snapshot, and
    /// four rewrites finishing at four different times would each write back a copy that
    /// predates the other three.
    static func modify(_ id: UUID, _ change: (inout DictationRun) -> Void) {
        var runs = load()
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
        rewrite(runs)
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
    static func deleteGroup(_ group: String) {
        rewrite(load().filter { $0.group != group })
    }

    static func delete(ids: Set<UUID>) {
        rewrite(load().filter { !ids.contains($0.id) })
    }

    static func clear() {
        try? FileManager.default.removeItem(at: runsURL)
        regenerate()
        RunStore.shared.reload()
    }

    /// Replaces the whole file. Deleting can't be an append, and rewriting also persists the
    /// ids that older runs were assigned on load.
    private static func rewrite(_ runs: [DictationRun]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let body = runs.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic: a partial write here would lose history that the user didn't ask to delete.
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: runsURL, atomically: true, encoding: .utf8)

        regenerate()
        RunStore.shared.reload()
    }
}

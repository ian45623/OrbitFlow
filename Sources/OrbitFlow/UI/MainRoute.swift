import Foundation
import Observation

/// Which transcription the main window is showing, and which tab it's on, when
/// something outside the window needs to say so.
///
/// `TranscriptionList` held the run id as private `@State`, which is right until a
/// second caller appears — the Services menu now has to open a specific run. This is the
/// smallest thing that lets both reach the same destination. It is not a router and
/// should not grow into one: if a third caller shows up, that is the moment to think
/// about navigation properly, not now.
@MainActor
@Observable
final class MainRoute {
    static let shared = MainRoute()

    /// Non-nil while one transcription is open for editing and rewriting. Held by id,
    /// not by value: the detail page writes rewrites back as they land, and a snapshot
    /// here would go stale the moment it did.
    var openRun: UUID?

    /// Which tab `MainWindow` shows. `open(_:)` forces this to `.transcriptions` — without
    /// it, opening a run while the window sits on another tab files the run and raises the
    /// window, but the selection is nowhere on screen.
    var section: MainWindow.Section = .transcriptions {
        didSet {
            // `MainRoute` is a process-lifetime singleton, unlike the private `@State`
            // this replaced, which used to reset for free every time the view holding it
            // was torn down. Leaving the transcriptions tab has to do that job by hand
            // now, or the next visit reopens whatever run was last viewed instead of
            // landing on the list.
            if section != .transcriptions { openRun = nil }
        }
    }

    private init() {}

    func open(_ id: UUID) {
        section = .transcriptions
        openRun = id
    }
}

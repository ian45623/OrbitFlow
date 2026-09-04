import Foundation
import Observation

/// Which transcription the main window is showing, when something outside the window
/// needs to say so.
///
/// `TranscriptionList` held this as private `@State`, which is right until a second
/// caller appears — the Services menu now has to open a specific run. This is the
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

    private init() {}

    func open(_ id: UUID) { openRun = id }
}

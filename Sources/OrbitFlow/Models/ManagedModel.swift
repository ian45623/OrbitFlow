import Foundation
import Observation

/// What a downloadable model is doing.
///
/// Lifted verbatim out of `ParakeetDownload` so Kokoro reports the same four states. The
/// named `working` label matters: most of the wait is the download, but the CoreML
/// compile at the end is slow and silent, and a bar parked at 100% reads as a hang.
enum ModelPhase: Equatable {
    case missing
    case working(label: String, fraction: Double)
    case ready
    case failed(String)
    /// Can't be used on this machine, and no retry will change that today — e.g. Kokoro
    /// gated off macOS 26.4/26.5 for the BNNS crash. Distinct from `.failed`, which means
    /// something went wrong that trying again might fix: `ModelStateCard` gives `.failed`
    /// a "Try again" button, and offering that for a permanent condition would just
    /// re-run the same check and land back here, which is a lie dressed up as an action.
    case unavailable(String)
}

/// A model the user can download, select and delete.
///
/// One protocol so one card renders all of them. Each conformer owns its own storage
/// location and fetch, because those genuinely differ — Parakeet lives in Application
/// Support under FluidAudio's ASR layout, Kokoro under the TTS cache root — but the
/// states they move through are identical, and the UI only cares about the states.
@MainActor
protocol ManagedModel: AnyObject, Observable {
    /// Stable identity, for `ForEach` and for logs.
    var id: String { get }
    /// What the row calls it: "Parakeet", "Kokoro".
    var displayName: String { get }
    /// Measured once and written in, never guessed — see the plan's Task 6.
    var downloadSize: String { get }
    /// One line under the name, describing what it is rather than selling it.
    var summary: String { get }
    var phase: ModelPhase { get }
    /// Bytes on disk, or nil when it isn't installed. Walked rather than hardcoded:
    /// a size is this version's number, not every version's.
    var installedSize: Int64? { get }
    func start()
    func removeFromDisk()
}

extension ManagedModel {
    var isWorking: Bool { if case .working = phase { true } else { false } }
    var isReady: Bool { phase == .ready }
}

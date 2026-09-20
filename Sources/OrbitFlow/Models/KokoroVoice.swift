import FluidAudio
import Foundation
import Observation

/// Kokoro-82M as a 7-stage CoreML chain on the Neural Engine, via FluidAudio.
///
/// Process-wide cache for the same reason `ParakeetModels` is one: loading is expensive
/// and the models are immutable once loaded, so every utterance shares one instance
/// rather than paying that per phrase.
actor KokoroModels {
    static let shared = KokoroModels()

    /// Where FluidAudio puts the TTS models — the cache root, not the Application
    /// Support path the ASR models use. One definition, because the existence check, the
    /// size readout and the delete all have to mean the same directory.
    ///
    /// Verified against a real download (Task 6 Step 1): FluidAudio's `Repo.kokoroAne`
    /// resolves to folder name `kokoro-82m-coreml/ANE` under `~/.cache/fluidaudio/Models`,
    /// so this is exactly where the seven `.mlmodelc` bundles, `vocab.json` and the
    /// default voice pack land.
    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml/ANE")
    }

    /// Not a Kokoro-only directory, despite the name FluidAudio gives its folder:
    /// `Repo.kokoro`'s cache holds the shared BART G2P model and Misaki lexicon
    /// (~24 MB) that FluidAudio's StyleTTS2 and Inflect backends read from too, sitting
    /// in a user-level cache (`~/.cache/fluidaudio`) rather than anything app-scoped.
    /// OrbitFlow doesn't use those other backends today, so treating it as "Kokoro's"
    /// here is harmless — but `remove()` below deletes this whole directory, which is
    /// more than Kokoro's own assets, and would take a StyleTTS2/Inflect install down
    /// with it on a build that added one. `sizeOnDisk` and `remove()` fold it in anyway:
    /// a "Download 83 MB" button that silently pulls down 108 MB, or a "Remove" that
    /// leaves 24 MB of files behind, would both be lying about disk usage — exactly what
    /// Task 6's measurement rule exists to prevent.
    nonisolated static var g2pDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/kokoro")
    }

    /// Checked from the filesystem, not an in-memory flag: models fetched in a previous
    /// launch are still downloaded.
    ///
    /// Requires evidence from *both* directories `sizeOnDisk`/`remove()` account for.
    /// Checking only `directory` would let a cleaned or partially-removed `g2pDirectory`
    /// seed `phase` to `.ready` with `installedSize` under-reporting by ~24 MB — and the
    /// next synthesis would silently re-download it with progress suppressed, since
    /// `report(_:)` below no-ops once `phase == .ready`. To the user that reads as a hang.
    ///
    /// Checks for `KokoroVocoder.mlmodelc`, not `Vocoder.mlmodelc` — confirmed against an
    /// actual download (Task 6 Step 1) that FluidAudio names every stage with a `Kokoro`
    /// prefix (`KokoroAlbert.mlmodelc`, `KokoroVocoder.mlmodelc`, etc). `G2PEncoder.mlmodelc`
    /// is likewise confirmed present in `g2pDirectory` after that same download.
    nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("KokoroVocoder.mlmodelc").path)
        && FileManager.default.fileExists(
            atPath: g2pDirectory.appendingPathComponent("G2PEncoder.mlmodelc").path)
    }

    nonisolated static var sizeOnDisk: Int64? {
        guard isDownloaded else { return nil }
        return bytes(at: directory) + bytes(at: g2pDirectory)
    }

    private nonisolated static func bytes(at url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in files {
            total += Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// macOS 26.4 and 26.5 carry an Apple BNNS bug that can crash Kokoro synthesis
    /// outright, whatever compute units it is routed to; 26.6 fixes it
    /// (FluidInference/FluidAudio#844). Offering a download that can take the app down
    /// is worse than not offering it.
    nonisolated static var isSupportedOS: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard v.majorVersion == 26 else { return true }
        return !(v.minorVersion >= 4 && v.minorVersion <= 5)
    }

    nonisolated static let unsupportedOSReason =
        "Kokoro can crash on macOS 26.4 and 26.5 because of a bug in Apple's BNNS "
        + "framework. Update to macOS 26.6 or later to use it."

    private var loaded: KokoroAneManager?
    private var loadTask: Task<KokoroAneManager, Error>?

    /// Loads once; concurrent callers await the same task rather than racing to download.
    func manager() async throws -> KokoroAneManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<KokoroAneManager, Error> {
            do {
                try await KokoroAneResourceDownloader.ensureModels(
                    variant: .english,
                    progressHandler: { progress in
                        Task { @MainActor in KokoroDownload.shared.report(progress) }
                    }
                )
                let manager = KokoroAneManager(variant: .english)
                try await manager.initialize()
                await MainActor.run { KokoroDownload.shared.markReady() }
                return manager
            } catch {
                await MainActor.run { KokoroDownload.shared.markFailed(error) }
                throw error
            }
        }
        loadTask = task

        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            // Don't cache a failed load — a dropped network shouldn't wedge the voice
            // for the rest of the session.
            loadTask = nil
            throw error
        }
    }

    /// Drops the files *and* the loaded copy. Dropping only the files would leave the
    /// models in memory, so a reinstall would return them instantly and never touch the
    /// network — a test of the download path that tests nothing.
    ///
    /// Removes both `directory` and `g2pDirectory` — see the comment on `g2pDirectory`
    /// for why the shared G2P assets count as part of "Kokoro" for this purpose even
    /// though FluidAudio stores them elsewhere.
    func remove() throws {
        loaded = nil
        loadTask?.cancel()
        loadTask = nil
        if FileManager.default.fileExists(atPath: Self.directory.path) {
            try FileManager.default.removeItem(at: Self.directory)
        }
        if FileManager.default.fileExists(atPath: Self.g2pDirectory.path) {
            try FileManager.default.removeItem(at: Self.g2pDirectory)
        }
    }
}

/// Kokoro's download state, for anything that wants to show it.
@MainActor
@Observable
final class KokoroDownload: ManagedModel {
    static let shared = KokoroDownload()

    nonisolated let id = "kokoro"
    nonisolated let displayName = "Kokoro"
    /// MEASURED in Task 6 Step 1 against a real install: 83,816,448 bytes in the ANE
    /// directory plus 24,670,208 bytes of shared G2P assets in the sibling directory
    /// (see `KokoroModels.g2pDirectory`) — 108,486,656 bytes combined, rounded like
    /// Parakeet's figure.
    nonisolated let downloadSize = "108 MB"
    nonisolated let summary =
        "Warmer, more natural speech than the system voices, generated on the Neural "
        + "Engine. Nothing is sent anywhere."

    private(set) var phase: ModelPhase = KokoroDownload.currentPhase()
    /// Read once per state change rather than per redraw — it is a walk over the bundle.
    private(set) var installedSize: Int64? = KokoroModels.sizeOnDisk

    /// What `phase` should read given the current disk state and OS — shared by `init`
    /// and `removeFromDisk()` so both are honest about an unsupported OS. Without this,
    /// a gated OS would seed `.missing` at launch (or after a remove) and the card would
    /// offer "Download 108 MB" right up until the press that finds out it can't run here.
    private static func currentPhase() -> ModelPhase {
        guard KokoroModels.isSupportedOS else { return .unavailable(KokoroModels.unsupportedOSReason) }
        return KokoroModels.isDownloaded ? .ready : .missing
    }

    func start() {
        // Checked first: a model already downloaded and ready has nothing to gain from
        // re-running the OS check, and doing the check first would flip an already-usable
        // `.ready` state to `.unavailable` on a machine that simply can't *start* a new
        // download right now — which is a different fact than "this can't run".
        guard phase != .ready, !isWorking else { return }
        guard KokoroModels.isSupportedOS else {
            // `.unavailable`, not `.failed`: the OS gate isn't a hiccup a retry can clear,
            // and `.failed`'s "Try again" button would just re-run this same check and
            // land right back here — an action that can never do anything is worse than
            // no action at all.
            phase = .unavailable(KokoroModels.unsupportedOSReason)
            return
        }
        phase = .working(label: "Starting", fraction: 0)
        Task { _ = try? await KokoroModels.shared.manager() }
    }

    func removeFromDisk() {
        Task {
            do {
                try await KokoroModels.shared.remove()
            } catch {
                Log.speech.error("Kokoro: couldn't delete models — \(error.localizedDescription)")
            }
            phase = Self.currentPhase()
            installedSize = KokoroModels.sizeOnDisk
        }
    }

    fileprivate func report(_ progress: DownloadProgress) {
        // A warm load still emits compile progress. Once ready, stay ready — a bar
        // reappearing every launch would read as re-downloading.
        guard phase != .ready else { return }
        let label = switch progress.phase {
        case .listing: "Preparing"
        case .downloading: "Downloading"
        case .compiling: "Optimizing for the Neural Engine"
        }
        phase = .working(label: label, fraction: progress.fractionCompleted)
    }

    fileprivate func markReady() {
        phase = .ready
        installedSize = KokoroModels.sizeOnDisk
    }

    fileprivate func markFailed(_ error: Error) {
        guard phase != .ready else { return }
        phase = .failed(error.localizedDescription)
    }
}

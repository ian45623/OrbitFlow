import AVFoundation
import FluidAudio
import Foundation
import Observation

/// NVIDIA Parakeet TDT 0.6B, compiled to CoreML and run on the Neural Engine via FluidAudio.
///
/// **Batch, not streaming.** Audio is accumulated while the key is held and transcribed in
/// one pass on release. That's a deliberate trade: at ~100× realtime a 30-second utterance
/// resolves in roughly a third of a second, which is imperceptible for push-to-talk — but
/// it means no live text in the HUD while you speak, unlike Apple's engine.
/// FluidAudio's `SlidingWindowAsrManager` would restore live partials at the cost of a
/// more complex integration; see the note in `docs`.
actor ParakeetEngine: TranscriptionEngine {
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// Defaults to 16 kHz mono float32 — exactly what Parakeet is trained on.
    private let converter = AudioConverter()

    func preferredInputFormat() async -> AVAudioFormat? {
        // Parakeet is trained on 16 kHz mono; AudioCapture converts to whatever we ask for.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // Force the (possibly very slow) first load to happen here rather than on release,
        // so the user waits before speaking instead of losing an utterance to a timeout.
        _ = try await ParakeetModels.shared.manager()

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        // Delegated to FluidAudio's own converter rather than hand-rolled, for one reason
        // that matters more than tidiness: `AsrManager.transcribe(_ samples: [Float])`
        // performs **no resampling and no rate validation**. Feed it the wrong sample rate
        // and it doesn't throw — it silently transcribes garbage.
        //
        // That's a live risk here. In compare mode the capture format is dictated by
        // Apple's analyzer, and `bestAvailableAudioFormat` may legitimately return 8 kHz
        // as well as 16 kHz. `resampleBuffer` normalizes whatever arrives to the 16 kHz
        // mono float32 the model expects, and its Int16→Float path is bit-identical to
        // dividing by 32768, so nothing is lost versus doing it by hand.
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("Parakeet: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }

        // Parakeet's encoder needs a minimum window; a stray tap of the key isn't speech.
        // Logged rather than silent — an unexpected drop to zero here is how the
        // format bug above disguised itself as a fast, empty result.
        guard samples.count >= 1_600 else {
            Log.speech.info("Parakeet: skipped — only \(self.samples.count) samples captured")
            return
        }

        do {
            let manager = try await ParakeetModels.shared.manager()
            var decoderState = try TdtDecoderState()
            let started = Date()
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            let elapsed = Date().timeIntervalSince(started)
            let audioSeconds = Double(samples.count) / 16_000

            Log.speech.info("""
                Parakeet: \(audioSeconds, format: .fixed(precision: 1))s audio in \
                \(elapsed, format: .fixed(precision: 2))s (\(audioSeconds / max(elapsed, 0.0001), format: .fixed(precision: 0))× realtime)
                """)

            continuation?.yield(
                TranscriptionChunk(
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("Parakeet failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

}

/// Process-wide model cache.
///
/// Loading is expensive — ~470 MB downloaded on first ever run, then a few seconds from
/// disk per process — and the models are immutable once loaded, so every dictation shares
/// one instance rather than paying that per utterance. Its own actor because `static var`
/// on `ParakeetEngine` would be unprotected global mutable state under Swift 6.
actor ParakeetModels {
    static let shared = ParakeetModels()

    /// Where FluidAudio puts the models. One definition, because the check, the size
    /// readout, and the delete all have to agree about which directory they mean.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
    }

    /// Whether the models are already on disk, checked without loading them.
    ///
    /// `nonisolated` and filesystem-based on purpose: the menu needs this synchronously
    /// while drawing, and an in-memory "have I loaded yet" flag would wrongly report
    /// "not downloaded" on every fresh launch.
    nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Encoder.mlmodelc").path)
    }

    /// Bytes the models occupy, or nil if they aren't installed. Walked rather than
    /// hardcoded — "470 MB" is this version's number, not every version's.
    nonisolated static var sizeOnDisk: Int64? {
        guard isDownloaded else { return nil }
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes the models and forgets the loaded copy.
    ///
    /// Both halves matter. Dropping only the files would leave `loaded` holding the
    /// models in memory, so a "reinstall" would return them instantly and never touch
    /// the network — a test of the download path that silently tests nothing.
    func remove() throws {
        loaded = nil
        loadTask?.cancel()
        loadTask = nil
        if FileManager.default.fileExists(atPath: Self.directory.path) {
            try FileManager.default.removeItem(at: Self.directory)
        }
    }

    private var loaded: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    var isLoaded: Bool { loaded != nil }

    /// Loads once; concurrent callers await the same task rather than racing to download.
    func manager() async throws -> AsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> {
            // Built as a value first: os.Logger requires a literal interpolation, so a
            // ternary can't be passed directly as the argument.
            let stage = Self.isDownloaded
                ? "loading models from disk"
                : "downloading models (~470 MB, one time)"
            Log.speech.info("Parakeet: \(stage, privacy: .public)")
            let started = Date()
            do {
                let models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    // Reported wherever the user happens to be looking — Settings, the menu
                    // bar — including when it's a first dictation that started the download.
                    progressHandler: { progress in
                        Task { @MainActor in ParakeetDownload.shared.report(progress) }
                    }
                )
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                Log.speech.info("Parakeet: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
                await MainActor.run { ParakeetDownload.shared.markReady() }
                return manager
            } catch {
                await MainActor.run { ParakeetDownload.shared.markFailed(error) }
                throw error
            }
        }
        loadTask = task

        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            // Don't cache a failed load — a transient download error shouldn't wedge the
            // engine for the rest of the session.
            loadTask = nil
            throw error
        }
    }
}

/// What the download is doing, for anything that wants to show it.
///
/// One observable rather than per-view state: the download can be started from Settings,
/// from the menu bar, or by a dictation that just needs the models, and all three have to
/// read the same truth. Previously each surface tracked its own flag and none of them
/// could see a download the other had started.
@MainActor
@Observable
final class ParakeetDownload {
    static let shared = ParakeetDownload()

    enum Phase: Equatable {
        case missing
        case working(label: String, fraction: Double)
        case ready
        case failed(String)
    }

    /// Seeded from disk, not from an in-memory flag — models downloaded in a previous
    /// launch are still downloaded.
    private(set) var phase: Phase = ParakeetModels.isDownloaded ? .ready : .missing

    /// Read once per state change rather than per redraw — it's a walk over ~600 files.
    private(set) var installedSize: Int64? = ParakeetModels.sizeOnDisk

    var isWorking: Bool { if case .working = phase { true } else { false } }

    /// Idempotent: `ParakeetModels` coalesces concurrent loads, so a second press just
    /// joins the download already running.
    func start() {
        guard phase != .ready, !isWorking else { return }
        phase = .working(label: "Starting", fraction: 0)
        Task { _ = try? await ParakeetModels.shared.manager() }
    }

    fileprivate func report(_ progress: DownloadProgress) {
        // A warm load from disk still emits compile progress. Once ready, stay ready —
        // a progress bar reappearing on every launch would read as re-downloading.
        guard phase != .ready else { return }
        let label = switch progress.phase {
        case .listing: "Preparing"
        case .downloading: "Downloading"
        case .compiling: "Optimizing for the Neural Engine"
        }
        phase = .working(label: label, fraction: progress.fractionCompleted)
    }

    /// Deletes the models so the download can be run again. Failure isn't given its own
    /// error state — re-reading the disk keeps the card honest either way, and a delete
    /// that failed leaves it saying "installed", which is exactly what's true.
    func removeFromDisk() {
        Task {
            do {
                try await ParakeetModels.shared.remove()
            } catch {
                Log.speech.error("Parakeet: couldn't delete models — \(error.localizedDescription)")
            }
            phase = ParakeetModels.isDownloaded ? .ready : .missing
            installedSize = ParakeetModels.sizeOnDisk
        }
    }

    fileprivate func markReady() {
        phase = .ready
        installedSize = ParakeetModels.sizeOnDisk
    }

    fileprivate func markFailed(_ error: Error) {
        guard phase != .ready else { return }
        phase = .failed(error.localizedDescription)
    }
}

import AVFoundation
import Foundation
import Observation
import OrbitFlowAIRewrite

/// Reads text aloud, either with a system voice or an ElevenLabs one.
///
/// One shared instance, because there is one speaker on the Mac: the pill, the History
/// detail page and the Settings preview all speak through this, so starting any of them
/// stops whatever else was talking, and a single ■ anywhere stops it all.
///
/// Engine, voice and speed are read from `Settings` at the moment `speak` is called, so a
/// change in Settings applies to the next thing read without anything having to observe it.
///
/// The two backends never substitute for each other. A failed ElevenLabs call surfaces as
/// an error rather than quietly becoming a system voice: switching voice, speed and
/// character mid-passage with no explanation is more confusing than being told the key is
/// wrong.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()

    private(set) var isSpeaking = false
    /// True while ElevenLabs renders the audio — after ▶, before the first word. The
    /// system backend is never in this state; it starts talking immediately.
    private(set) var isPreparing = false
    /// Why the last attempt produced no sound. Shown in the capsule; cleared by the next
    /// `speak` or `stop`.
    private(set) var failure: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var fetch: Task<Void, Never>?

    /// The last MP3 ElevenLabs rendered, and the voice, model, speed and text that produced
    /// it. Cycling modes and coming back to one you already heard is the case this exists
    /// for: the transform is already cached, and re-rendering the identical audio would be
    /// a second charge for a file we are still holding. One entry — that covers "switch
    /// mode and switch back" and needs no eviction policy. The settings are part of the key
    /// rather than an invalidation step, so picking a new voice cannot replay the old one.
    @ObservationIgnored private var rendered: (key: String, data: Data)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()

        switch Settings.shared.readAloudEngine {
        case .system:
            let utterance = AVSpeechUtterance(string: text)
            let settings = Settings.shared
            utterance.voice = settings.readAloudVoice
                .flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            utterance.rate = settings.readAloudRate
            isSpeaking = true
            synthesizer.speak(utterance)

        case .elevenLabs:
            speakWithElevenLabs(text)
        }
    }

    /// Drops a failure left over from the last attempt, without touching speech in flight.
    ///
    /// `stop()` would do this too, but it also silences whatever is playing — and a new
    /// highlight is deliberately offered while the previous passage is still being read.
    /// Without this, the pill for the new selection would open showing the old error.
    func clearFailure() {
        failure = nil
    }

    func stop() {
        fetch?.cancel()
        fetch = nil
        player?.stop()
        player = nil
        failure = nil
        isPreparing = false
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - ElevenLabs

    private func speakWithElevenLabs(_ text: String) {
        let settings = Settings.shared
        let voiceID = settings.elevenLabsVoiceID
        guard !voiceID.isEmpty else {
            return fail("Pick an ElevenLabs voice in Settings.")
        }
        guard let apiKey = KeyStore.read(account: Self.keyAccount), !apiKey.isEmpty else {
            return fail("Add your ElevenLabs key in Settings.")
        }

        let key = "\(voiceID)\u{1}\(settings.elevenLabsModel)\u{1}\(settings.elevenLabsSpeed)\u{1}\(text)"
        if let rendered, rendered.key == key {
            return playRendered(rendered.data)
        }

        let request = ElevenLabs.speechRequest(
            voiceID: voiceID,
            key: apiKey,
            model: settings.elevenLabsModel,
            text: text,
            speed: settings.elevenLabsSpeed
        )

        isPreparing = true
        fetch = Task { @MainActor in
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard !Task.isCancelled else { return }

                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    return fail(Self.message(for: http.statusCode, body: data))
                }

                rendered = (key, data)
                playRendered(data)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as URLError where error.code == .timedOut {
                fail("ElevenLabs timed out.")
            } catch is URLError {
                fail("Couldn't reach ElevenLabs.")
            } catch {
                fail("Couldn't reach ElevenLabs.")
            }
        }
    }

    /// Plays audio ElevenLabs has already sent us, whether that was a moment ago or the
    /// last time this text was read.
    private func playRendered(_ data: Data) {
        guard let player = try? AVAudioPlayer(data: data) else {
            // `AVAudioPlayer(data:)` throws when the body isn't decodable audio — which is
            // what an HTML error page from a proxy looks like.
            return fail("ElevenLabs returned audio we couldn't play.")
        }
        player.delegate = self
        player.enableRate = false
        guard player.play() else {
            return fail("ElevenLabs returned audio we couldn't play.")
        }
        self.player = player
        isPreparing = false
        isSpeaking = true
    }

    /// The account name under which the ElevenLabs key is stored, alongside the rewrite
    /// providers' keys. Not an `AIProvider` case — that enum is the rewrite tier's list of
    /// chat providers, and ElevenLabs does not belong in a model picker.
    static let keyAccount = "elevenlabs"

    /// 30 s: rendering a summary is a few seconds, and nothing is waiting to be typed.
    /// Ephemeral, so no cache or cookie store follows a keyed API call around. Settings'
    /// Test button borrows it rather than reaching for `URLSession.shared`.
    @ObservationIgnored static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// A bad key and an exhausted quota are both 401; only the body tells them apart, so
    /// the provider's own message wins whenever it sent one.
    private static func message(for status: Int, body: Data) -> String {
        if let detail = ElevenLabs.failureMessage(from: body) {
            return "ElevenLabs: \(detail)"
        }
        switch status {
        case 401, 403: return "ElevenLabs rejected the key — check it in Settings."
        case 429: return "ElevenLabs is rate-limiting — try again in a moment."
        default: return "ElevenLabs: HTTP \(status)"
        }
    }

    private func fail(_ message: String) {
        player = nil
        isPreparing = false
        isSpeaking = false
        failure = message
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // Both callbacks ask the synthesizer rather than trusting which utterance ended.
    // `speak` cancels the previous utterance before queueing the next, and that cancel is
    // delivered *after* the new one is already queued — so reacting to it would mark the
    // new speech as finished the moment it started. `isSpeaking` on the synthesizer counts
    // queued utterances, so it is only false when nothing at all is left to say.

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.settle() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.settle() }
    }

    private func settle() {
        // An ElevenLabs `speak()` calls `stop()` first, which cancels a queued system
        // utterance and fires `didCancel` — but queues no utterance of its own, so without
        // the extra checks this would race the ElevenLabs path and mark its passage
        // finished before a sound is ever made.
        guard !synthesizer.isSpeaking, !isPreparing, player == nil else { return }
        isSpeaking = false
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        // `AVAudioPlayer` isn't `Sendable`, so only its identity — not the instance
        // itself — crosses into the MainActor closure below.
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            // A newer passage may already be playing through a different player. `isPlaying`
            // guards against a recycled address aliasing `finished`: a freed player's memory
            // could be reused for a new one, but a reused address can only alias a player
            // that is currently playing, never one that has already finished.
            guard let current = self.player, ObjectIdentifier(current) == finished,
                  !current.isPlaying
            else { return }
            self.player = nil
            self.isSpeaking = false
        }
    }
}

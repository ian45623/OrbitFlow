import AVFoundation
import Observation

/// Reads text aloud with a system voice.
///
/// One shared instance, because there is one speaker on the Mac: the pill, the History
/// detail page and the Settings preview all speak through this, so starting any of them
/// stops whatever else was talking, and a single ■ anywhere stops it all.
///
/// Voice and speed are read from `Settings` at the moment `speak` is called, so a change in
/// Settings applies to the next thing read without anything having to observe it.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private(set) var isSpeaking = false
    /// What is being spoken, so the pill can show it next to the ■.
    private(set) var text: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        let settings = Settings.shared
        utterance.voice = settings.readAloudVoice.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        utterance.rate = settings.readAloudRate

        self.text = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        text = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
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
        guard !synthesizer.isSpeaking else { return }
        text = nil
        isSpeaking = false
    }
}

import Foundation
import Testing

@testable import OrbitFlowAIRewrite

struct ElevenLabsTests {
    let key = "xi-secret-key-value"

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    @Test("A speech request posts to the voice's endpoint with the key in a header")
    func speechRequest() {
        let request = ElevenLabs.speechRequest(
            voiceID: "voice123", key: key, model: "eleven_flash_v2_5",
            text: "Hello there", speed: 1.1
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
            == "https://api.elevenlabs.io/v1/text-to-speech/voice123")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == key)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sent = body(request)
        #expect(sent["text"] as? String == "Hello there")
        #expect(sent["model_id"] as? String == "eleven_flash_v2_5")
        let settings = sent["voice_settings"] as? [String: Any]
        #expect(settings?["speed"] as? Double == 1.1)
    }

    /// A key in a URL ends up in logs, crash reports and proxy access logs. It belongs in
    /// a header and nowhere else — this is the test that keeps it there.
    @Test("The key never appears in a URL or a request body")
    func keyStaysInTheHeader() {
        let requests = [
            ElevenLabs.speechRequest(
                voiceID: "v", key: key, model: "m", text: "t", speed: 1.0),
            ElevenLabs.voicesRequest(key: key),
            ElevenLabs.modelsRequest(key: key),
        ]
        for request in requests {
            #expect(request.url?.absoluteString.contains(key) == false)
            let raw = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(raw.contains(key) == false)
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == key)
        }
    }

    /// There is no /v1/voices. Getting this wrong is a 404 that reads as a bad key.
    @Test("Voices come from v2 and models from v1")
    func listEndpoints() {
        #expect(ElevenLabs.voicesRequest(key: key).url?.absoluteString
            == "https://api.elevenlabs.io/v2/voices")
        #expect(ElevenLabs.voicesRequest(key: key).httpMethod == "GET")
        #expect(ElevenLabs.modelsRequest(key: key).url?.absoluteString
            == "https://api.elevenlabs.io/v1/models")
        #expect(ElevenLabs.modelsRequest(key: key).httpMethod == "GET")
    }

    @Test("A voices page parses into id, name and category")
    func parseVoices() {
        let json = Data("""
            {"voices":[
              {"voice_id":"abc","name":"Rachel","category":"premade"},
              {"voice_id":"def","name":"Custom One","category":"cloned"}
            ],"has_more":false}
            """.utf8)
        let voices = ElevenLabs.voices(from: json)
        #expect(voices.count == 2)
        #expect(voices.first?.id == "abc")
        #expect(voices.first?.name == "Rachel")
        #expect(voices.first?.category == "premade")
    }

    /// A voice with no name is unpickable in a menu, so it is dropped rather than shown
    /// as a blank row.
    @Test("Voices without an id or a name are dropped, junk yields an empty list")
    func parseVoicesJunk() {
        let partial = Data(#"{"voices":[{"voice_id":"abc"},{"name":"No id"}]}"#.utf8)
        #expect(ElevenLabs.voices(from: partial).isEmpty)
        #expect(ElevenLabs.voices(from: Data("not json".utf8)).isEmpty)
    }

    @Test("A models page parses into model IDs")
    func parseModels() {
        let json = Data("""
            {"models":[{"model_id":"eleven_flash_v2_5"},{"model_id":"eleven_v3"}]}
            """.utf8)
        #expect(ElevenLabs.models(from: json) == ["eleven_flash_v2_5", "eleven_v3"])
        #expect(ElevenLabs.models(from: Data("not json".utf8)).isEmpty)
    }

    /// ElevenLabs distinguishes a bad key from an exhausted quota only in this string.
    /// Both are 401, so without it the user is told to check a key that is fine.
    @Test("An error body yields the provider's own message")
    func parseFailure() {
        let quota = Data("""
            {"detail":{"status":"quota_exceeded","message":"You have 0 credits remaining."}}
            """.utf8)
        #expect(ElevenLabs.failureMessage(from: quota) == "You have 0 credits remaining.")
    }

    @Test("A string-shaped detail is also read, and junk yields nil")
    func parseFailureVariants() {
        let plain = Data(#"{"detail":"Invalid API key"}"#.utf8)
        #expect(ElevenLabs.failureMessage(from: plain) == "Invalid API key")
        #expect(ElevenLabs.failureMessage(from: Data("not json".utf8)) == nil)
        #expect(ElevenLabs.failureMessage(from: Data("{}".utf8)) == nil)
    }
}

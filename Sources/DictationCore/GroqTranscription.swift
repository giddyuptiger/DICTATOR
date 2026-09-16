import Foundation

/// Whisper large v3 turbo on Groq. This is what the iPhone keyboard uses, because
/// 48 MB will not hold a real model but it will hold an audio buffer.
///
/// Two things make this better than a naive upload:
///
///  1. `prompt` biases the decoder toward your proper nouns BEFORE decoding, so
///     "Egoscue" comes back right rather than being patched up afterwards. This is
///     the highest-leverage line in the file.
///  2. Silence is trimmed client side, which cuts upload time and stops Whisper
///     inventing words out of room tone.
/// ONE persistent URLSession for every Groq call, for the whole app lifetime.
///
/// Before this, GroqTranscription and GroqCleanup each built a fresh
/// URLSession on every dictation and never invalidated it. Un-invalidated
/// sessions retain themselves (plus their connection pool and worker threads),
/// so they PILED UP over a session and the whole pipeline got slower and
/// slower — "something's getting worse." A single shared session fixes the leak
/// AND keeps the TLS connection to api.groq.com warm between the transcribe and
/// cleanup calls (both hit the same host), which is a real latency win on a weak
/// connection where a fresh handshake costs a second or more. Per-request
/// timeouts still apply, so this does not change how long any one call waits.
enum GroqHTTP {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
}

public struct GroqTranscription: SpeechProvider {

    public enum GroqError: Error, LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case unparseable
        case emptyAudio

        public var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No Groq API key. Add one in the Dictator app settings."
            case .http(let status, let body):
                return "Groq returned \(status): \(body)"
            case .unparseable:
                return "Could not read Groq's response."
            case .emptyAudio:
                return "Nothing was recorded."
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let biasTerms: [String]
    private let session: URLSession

    public var approximateMemoryFootprintMB: Int { 2 }

    public init(
        apiKey: String,
        model: String = "whisper-large-v3-turbo",
        biasTerms: [String] = []
    ) {
        self.apiKey = apiKey
        self.model = model
        self.biasTerms = biasTerms
        self.session = GroqHTTP.shared
    }

    /// Cheap check that a key works, for onboarding. One GET to the models
    /// endpoint: 200 means the key is good, 401/403 means it was rejected, and a
    /// thrown error means we could not reach Groq at all (offline, timeout).
    /// Returns true only on a 2xx.
    public static func validateKey(_ key: String) async throws -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingKey }

        let trimmed = AudioUtil.trimSilence(samples)
        guard trimmed.count > 1_600 else { throw GroqError.emptyAudio }  // < 0.1 s

        let wav = WAVEncoder.encode(samples: trimmed)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Scale the timeout with the recording. The session's flat 20 s is fine
        // for a sentence, but a five-minute clip is a ~10 MB upload plus longer
        // Whisper time, and on a slow connection the flat timeout fires mid-flight
        // and turns a good recording into a spurious "couldn't reach Groq". Give
        // roughly 20 s of headroom plus 0.4 s per second of audio, capped so a
        // truly stuck request still fails in bounded time.
        let duration = Double(trimmed.count) / 16_000
        request.timeoutInterval = min(150, max(30, 20 + duration * 0.4))

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)

        field("model", model)
        field("response_format", "json")
        field("temperature", "0")
        field("language", "en")

        // Decoder biasing. Whisper treats this as prior context, so listing your
        // vocabulary here materially improves proper nouns.
        if !biasTerms.isEmpty {
            let hint = biasTerms.prefix(80).joined(separator: ", ")
            field("prompt", "Vocabulary: \(hint)")
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroqError.unparseable }
        guard (200..<300).contains(http.statusCode) else {
            throw GroqError.http(status: http.statusCode,
                                 body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw GroqError.unparseable }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

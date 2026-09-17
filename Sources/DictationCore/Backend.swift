import Foundation

/// The Dictator backend — a Cloudflare Worker that holds the Groq key server-side,
/// so the key never ships in the app. The app talks to this for cloud transcription
/// and cleanup UNLESS the user supplied their own Groq key (BYOK), in which case it
/// goes straight to Groq and never touches this.
public enum Backend {
    /// Deployed Worker base URL. Change here if the Worker is re-homed on a custom
    /// domain (e.g. https://api.irons.la).
    public static let baseURL = "https://dictator-backend.jeremydirons.workers.dev"

    /// A stable per-install id so the backend can rate-limit per device (not just
    /// per IP). Not personally identifying — a random UUID created once.
    public static var deviceID: String {
        if let id = SharedStore.deviceID, !id.isEmpty { return id }
        let id = UUID().uuidString
        SharedStore.deviceID = id
        return id
    }
}

/// Cloud transcription via the backend proxy (no key in the app).
public struct BackendTranscription: SpeechProvider {
    private let biasTerms: [String]
    private let session: URLSession

    public var approximateMemoryFootprintMB: Int { 2 }

    public init(biasTerms: [String] = []) {
        self.biasTerms = biasTerms
        self.session = GroqHTTP.shared
    }

    public func transcribe(samples: [Float]) async throws -> String {
        let trimmed = AudioUtil.trimSilence(samples)
        guard trimmed.count > 1_600 else { throw BackendError.emptyAudio }

        let wav = WAVEncoder.encode(samples: trimmed)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: "\(Backend.baseURL)/v1/transcribe")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(Backend.deviceID, forHTTPHeaderField: "X-Device-Id")

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
        field("model", "whisper-large-v3-turbo")
        field("language", "en")
        if !biasTerms.isEmpty {
            field("prompt", "Vocabulary: \(biasTerms.prefix(80).joined(separator: ", "))")
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.unparseable }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw BackendError.unparseable }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Cleanup via the backend proxy (no key in the app).
public struct BackendCleanup: CleanupProvider {
    private let session: URLSession
    public init() { self.session = GroqHTTP.shared }

    public func clean(_ raw: String, system: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Backend.baseURL)/v1/cleanup")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Backend.deviceID, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": raw, "system": system])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.unparseable }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else { throw BackendError.unparseable }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum BackendError: Error, LocalizedError {
    case emptyAudio
    case unparseable
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio: return "Nothing was recorded."
        case .unparseable: return "Couldn't read the server's response."
        case .http(let status, _): return "Server returned \(status)."
        }
    }
}

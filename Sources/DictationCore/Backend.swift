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

    /// Open (and pool) a TLS connection to the backend ahead of time, so the
    /// transcription / cleanup request that follows reuses a warm connection
    /// instead of paying for a fresh TLS handshake on the critical path. Called
    /// when a capture starts: the user is still speaking, so this happens in the
    /// dead time before there is anything to send. Fire-and-forget — the result
    /// is ignored, and a failure here never affects the dictation.
    ///
    /// GroqHTTP.shared is the same URLSession used for the real requests, and
    /// URLSession keeps HTTP connections alive for reuse, so warming /healthz
    /// warms the exact connection the POST will ride on.
    public static func warmConnection() {
        guard let url = URL(string: "\(baseURL)/healthz") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        Task.detached { _ = try? await GroqHTTP.shared.data(for: req) }
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

/// The combined result of one round trip to `/v1/dictate`: the raw transcript and
/// the server-cleaned text. The app still runs its own safety guards on the pair
/// (see `Cleaner.reconcile`), so a bad server-side cleanup can never overwrite the
/// user's words.
public struct DictateResult: Sendable {
    public let raw: String
    public let cleaned: String
    public let didClean: Bool
}

/// Cloud transcription + cleanup in a SINGLE round trip (the premium fast path).
/// Instead of the phone making two trips — upload audio, get transcript, then send
/// text, get cleaned — the backend does both Groq calls server-side (where the hop
/// to Groq is cheap) and returns both strings at once. On mobile that removes a
/// whole request/response cycle from the critical path.
public struct BackendDictate {
    private let biasTerms: [String]
    private let session: URLSession
    public init(biasTerms: [String] = []) {
        self.biasTerms = biasTerms
        self.session = GroqHTTP.shared
    }

    public func dictate(samples: [Float], system: String) async throws -> DictateResult {
        let trimmed = AudioUtil.trimSilence(samples)
        guard trimmed.count > 1_600 else { throw BackendError.emptyAudio }

        let wav = WAVEncoder.encode(samples: trimmed)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: "\(Backend.baseURL)/v1/dictate")!)
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
        field("system", system)
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.unparseable
        }
        let raw = (json["raw"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let didClean = (json["cleaned"] as? Bool) ?? false
        // `text` is the cleaned string; `raw` is the transcript. If the server
        // couldn't clean, it returns text == raw with cleaned=false.
        return DictateResult(raw: raw.isEmpty ? text : raw,
                             cleaned: text.isEmpty ? raw : text,
                             didClean: didClean)
    }
}

/// Cleanup via the backend proxy (no key in the app).
public struct BackendCleanup: CleanupProvider {
    private let session: URLSession
    public init() { self.session = GroqHTTP.shared }

    public func clean(_ raw: String, system: String) async throws -> String {
        try await clean(raw, system: system, preferredModel: nil)
    }

    public func clean(_ raw: String, system: String, preferredModel: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Backend.baseURL)/v1/cleanup")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Backend.deviceID, forHTTPHeaderField: "X-Device-Id")
        var body: [String: Any] = ["text": raw, "system": system]
        if let preferredModel { body["model"] = preferredModel }   // the Worker tries it first
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

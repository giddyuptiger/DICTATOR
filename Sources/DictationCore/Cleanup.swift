import Foundation

/// Turns raw transcript into text you would have typed: filler words gone,
/// punctuation right, your vocabulary spelled correctly, tone matched to wherever
/// the cursor is.
///
/// Providers are pluggable on purpose. Start on Groq because it is fast enough that
/// the cleanup pass disappears into the transcription latency, then swap to a local
/// model when you want the whole pipeline offline.
public protocol CleanupProvider: Sendable {
    func clean(_ raw: String, system: String) async throws -> String
}

public struct CleanupResult: Sendable {
    public let text: String
    public let usedProvider: Bool
    /// Round trip in seconds, so you can watch the latency budget.
    public let latency: TimeInterval
}

public struct Cleaner: Sendable {

    public let provider: CleanupProvider?
    private let dictionary: PersonalDictionary

    public init(provider: CleanupProvider?, dictionary: PersonalDictionary) {
        self.provider = provider
        self.dictionary = dictionary
    }

    public func process(_ raw: String, profile: ToneProfile) async -> CleanupResult {
        let start = Date()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CleanupResult(text: "", usedProvider: false, latency: 0)
        }

        guard let provider else {
            // No LLM configured: still apply the deterministic dictionary pass.
            let text = dictionary.apply(to: trimmed)
            return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start))
        }

        let system = profile.systemPrompt(dictionaryHint: dictionary.promptHint())

        do {
            let cleaned = try await provider.clean(trimmed, system: system)
            // Dictionary runs after the model, so it wins any disagreement.
            let final = dictionary.apply(to: cleaned)
            return CleanupResult(text: final, usedProvider: true, latency: Date().timeIntervalSince(start))
        } catch {
            // Never lose the user's words to a network failure. Degrade to raw.
            let text = dictionary.apply(to: trimmed)
            return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start))
        }
    }
}

// MARK: - Groq

/// Fast and cheap. A cleanup pass on a paragraph costs a fraction of a cent and
/// returns in roughly 200 ms, which matters more than the money.
public struct GroqCleanup: CleanupProvider {

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "llama-3.3-70b-versatile") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: config)
    }

    public func clean(_ raw: String, system: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "max_tokens": 1500,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": raw]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CleanupError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw CleanupError.unparseable
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum CleanupError: Error {
        case badResponse(String)
        case unparseable
    }
}

// MARK: - Apple on-device

/// On iOS 26 / macOS 26 and later, Apple's on-device Foundation Model can do the
/// cleanup with no network and no cost. Slower than Groq but fully private.
/// Left as a stub because the import is OS-gated; fill in when you target 26+.
public struct AppleOnDeviceCleanup: CleanupProvider {
    public init() {}

    public func clean(_ raw: String, system: String) async throws -> String {
        // import FoundationModels
        // let session = LanguageModelSession(instructions: system)
        // return try await session.respond(to: raw).content
        return raw
    }
}

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
    /// A short diagnostic when the model pass did not apply (no provider, or an
    /// error we degraded past). nil on a clean provider pass. Logged so "why is
    /// my mode/emoji not applying" is answerable from the Activity log.
    public let note: String?

    public init(text: String, usedProvider: Bool, latency: TimeInterval, note: String? = nil) {
        self.text = text
        self.usedProvider = usedProvider
        self.latency = latency
        self.note = note
    }
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
            return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start), note: "no cleanup provider")
        }

        let system = profile.systemPrompt(dictionaryHint: dictionary.promptHint())

        do {
            let cleaned = try await provider.clean(trimmed, system: system)
            let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

            // The safety net. A cleanup model can return an empty string, or treat
            // the transcript as a request and refuse it ("I'm sorry, but I can't
            // help with that") — both seen on device, and both used to be typed
            // verbatim, destroying the user's words. Never let the model's failure
            // replace what the user actually said: fall back to the raw transcript
            // (dictionary-corrected). This matters most on longer dictations, which
            // are exactly where refusals and empties show up.
            if cleanedTrimmed.isEmpty {
                let text = dictionary.apply(to: trimmed)
                return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start), note: "cleanup returned empty; used raw transcript")
            }
            if Self.looksLikeRefusal(cleanedTrimmed), !Self.looksLikeRefusal(trimmed) {
                let text = dictionary.apply(to: trimmed)
                return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start), note: "cleanup refused; used raw transcript")
            }

            // Dictionary runs after the model, so it wins any disagreement.
            let final = dictionary.apply(to: cleaned)
            return CleanupResult(text: final, usedProvider: true, latency: Date().timeIntervalSince(start))
        } catch {
            // Never lose the user's words to a network failure. Degrade to raw,
            // but record why: this is what makes "my mode/emoji did nothing"
            // diagnosable instead of silent.
            let text = dictionary.apply(to: trimmed)
            let reason = String(describing: error).prefix(160)
            return CleanupResult(text: text, usedProvider: false, latency: Date().timeIntervalSince(start), note: "cleanup skipped: \(reason)")
        }
    }

    /// Whether a cleanup result reads as the model refusing or apologising rather
    /// than reformatting. Checked against the model's OUTPUT; the caller also
    /// confirms the raw transcript does not itself start this way, so a user who
    /// genuinely dictates "I'm sorry..." is not mistaken for a refusal.
    private static func looksLikeRefusal(_ text: String) -> Bool {
        let t = text.lowercased()
        let openers = [
            "i'm sorry", "i am sorry", "sorry, ", "i cannot", "i can't", "i can not",
            "i'm not able", "i am not able", "i'm unable", "i am unable",
            "i won't", "i will not", "i'm just an", "i am just an", "as an ai",
            "i can't help", "i cannot help", "i can't assist", "i cannot assist",
            "i can't provide", "i cannot provide", "i'm not going to", "unfortunately, i"
        ]
        return openers.contains { t.hasPrefix($0) }
    }
}

// MARK: - Groq

/// Fast and cheap. A cleanup pass on a paragraph costs a fraction of a cent and
/// returns in roughly 200 ms, which matters more than the money.
public struct GroqCleanup: CleanupProvider {

    private let apiKey: String
    private let models: [String]
    private let session: URLSession

    /// Groq rotates and decommissions models, and it did: on 2026-09-14 the
    /// hard-coded `llama-3.3-70b-versatile` started returning "does not exist",
    /// so every cleanup failed and modes/emoji silently did nothing. So try a
    /// spread across families and cache the first that works; if Groq kills one,
    /// the next covers it. Ordered fast-and-cheap first, which is plenty for a
    /// rewrite-this-text task.
    public static let defaultModels = [
        "llama-3.1-8b-instant",
        "openai/gpt-oss-20b",
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "gemma2-9b-it",
        "moonshotai/kimi-k2-instruct",
        "openai/gpt-oss-120b",
        "llama-3.3-70b-versatile"
    ]

    public init(apiKey: String, models: [String] = GroqCleanup.defaultModels) {
        self.apiKey = apiKey
        self.models = models
        // Reuse the one persistent Groq session (see GroqHTTP): no per-dictation
        // session leak, and the connection stays warm from the transcription call
        // that just happened. The 15 s cleanup bound is applied per-request below.
        self.session = GroqHTTP.shared
    }

    public func clean(_ raw: String, system: String) async throws -> String {
        // Try the last-known-good model first, then the rest. A model that is
        // gone (HTTP 4xx naming the model) means try the next; any other failure
        // (network, auth) is not helped by trying more models, so surface it.
        var order = models
        if let cached = SharedStore.cleanupModel, let i = order.firstIndex(of: cached) {
            order.remove(at: i)
            order.insert(cached, at: 0)
        }

        var lastModelError: Error = CleanupError.unparseable
        for model in order {
            do {
                let text = try await request(model: model, raw: raw, system: system)
                SharedStore.cleanupModel = model   // remember the winner
                return text
            } catch CleanupError.modelUnavailable {
                lastModelError = CleanupError.modelUnavailable
                continue
            }
            // Any other thrown error (network, 401, parse) propagates: retrying
            // other models would not fix it and just burns time.
        }
        throw lastModelError
    }

    private func request(model: String, raw: String, system: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15   // per-request bound (the shared session's default is longer)
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
        guard let http = response as? HTTPURLResponse else { throw CleanupError.unparseable }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            // A 4xx that names the model (decommissioned / no access) means: try
            // another model. Everything else is a real error to surface.
            if (400..<500).contains(http.statusCode), bodyText.contains("model") {
                throw CleanupError.modelUnavailable
            }
            throw CleanupError.badResponse(bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw CleanupError.unparseable
        }

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty completion is a failure for THIS model (some models empty out
        // instead of answering on longer or awkward input). Treat it like an
        // unavailable model so clean() moves on to the next one; if they all empty,
        // clean() throws and Cleaner falls back to the raw transcript.
        if text.isEmpty { throw CleanupError.modelUnavailable }
        return text
    }

    public enum CleanupError: Error {
        case badResponse(String)
        case unparseable
        case modelUnavailable
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

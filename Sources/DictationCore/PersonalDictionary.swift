import Foundation

/// Your vocabulary: names, jargon, product names, the things a general model will
/// always get wrong. This is the single biggest quality lever over stock Whisper,
/// and it is where a homebrew tool can beat a commercial one, because your corpus
/// of proper nouns is small, personal, and known to you.
///
/// Applied in two passes:
///   1. As a bias hint in the cleanup prompt (soft, handles inflection).
///   2. As a deterministic phonetic replacement afterwards (hard, handles the
///      cases the LLM shrugs at).
///
/// Synced between Mac and iPhone through the shared App Group container, and
/// optionally through iCloud key-value store so a term you add on one shows up
/// on the other.
/// Well-known app/brand/product names that speech models routinely mangle into
/// homophones ("WhatsApp" -> "what's up", "iOS" -> "I OS"). Passed as transcription
/// bias so the cloud model is nudged toward the right spelling; the cleanup pass
/// (see ToneProfile PROPER NOUNS) also restores them from context, which is what
/// covers the on-device engine, whose model takes no bias hint.
public enum BuiltinVocabulary {
    /// Brand / product names that speech models mangle into homophones.
    static let products = [
        "WhatsApp", "iPhone", "iPad", "iOS", "macOS", "iMessage", "FaceTime",
        "AirPods", "Instagram", "TikTok", "YouTube", "Gmail", "Google", "Spotify",
        "Slack", "Zoom", "PayPal", "Venmo", "Uber", "Netflix", "Dictator",
    ]

    /// Finance, mortgage, real-estate and startup terms a general model splits
    /// ("buy down" -> "buydown"), mis-cases, or under-formats. Seeded so the
    /// recognizer is nudged toward the right spelling for everyone; the NUMBERS
    /// section of the cleanup prompt handles the digit forms ("3-2-1 buydown").
    static let finance = [
        "buydown", "3-2-1 buydown", "2-1 buydown", "escrow", "amortization",
        "refinance", "HELOC", "APR", "APY", "FICO", "underwriting", "PMI",
        "closing costs", "earnest money", "1031 exchange", "401(k)", "1099",
        "W-2", "Roth IRA", "EBITDA", "ARR", "MRR", "cap table", "SAFE note",
        "term sheet", "runway",
    ]

    public static let terms = products + finance
}

public struct PersonalDictionary: Codable, Sendable {

    public struct Entry: Codable, Sendable, Hashable {
        /// The correct spelling, e.g. "Egoscue".
        public let canonical: String
        /// Things the recognizer tends to hear instead, e.g. ["ego skew", "ego q"].
        public var misheard: [String]

        public init(canonical: String, misheard: [String] = []) {
            self.canonical = canonical
            self.misheard = misheard
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: - Editing

    public mutating func add(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.canonical.caseInsensitiveCompare(entry.canonical) == .orderedSame }) {
            var merged = entries[idx]
            for m in entry.misheard where !merged.misheard.contains(m) {
                merged.misheard.append(m)
            }
            entries[idx] = merged
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(canonical: String) {
        entries.removeAll { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame }
    }

    /// Learn from a correction: the user changed `from` to `to` in the inserted
    /// text, so record that mishearing. Call this from an "edit last dictation" flow.
    public mutating func learn(misheard from: String, corrected to: String) {
        guard !from.isEmpty, !to.isEmpty, from.caseInsensitiveCompare(to) != .orderedSame else { return }
        add(Entry(canonical: to, misheard: [from]))
    }

    // MARK: - Prompt hint

    /// A compact bias list for the cleanup prompt. Capped so it never dominates
    /// the token budget on a long dictionary.
    public func promptHint(limit: Int = 60) -> String {
        guard !entries.isEmpty else { return "" }
        let terms = entries.prefix(limit).map(\.canonical)
        return "Known proper nouns and terms (spell these exactly): " + terms.joined(separator: ", ")
    }

    // MARK: - Deterministic pass

    /// Replace known mishearings with their canonical spelling. Case-insensitive,
    /// whole-phrase, and preserves the capitalization style of the replacement.
    public func apply(to text: String) -> String {
        var result = text
        for entry in entries {
            for wrong in entry.misheard where !wrong.isEmpty {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.canonical)
                )
            }
        }
        return result
    }

    // MARK: - Persistence

    /// Shared between the Mac app, the iOS app, and the keyboard extension.
    /// Replace with your own App Group identifier.
    public static let appGroup = "group.design.irons.dictator"
    private static let storageKey = "personalDictionary"

    public static func load() -> PersonalDictionary {
        // `?? .standard`: the Mac target carries no App Group entitlement (a
        // Developer ID build cannot embed the profile it would need), so the
        // suite is unavailable there; standard defaults persist the same for the
        // single Mac process. iOS still resolves the shared group suite.
        let defaults = UserDefaults(suiteName: appGroup) ?? .standard
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersonalDictionary.self, from: data)
        else {
            return PersonalDictionary()
        }
        return decoded
    }

    public func save() {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)

        // Cross-device sync. Cheap, no CloudKit schema to manage, and a dictionary
        // is far below the 1 MB key-value ceiling.
        NSUbiquitousKeyValueStore.default.set(data, forKey: Self.storageKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Pull anything another device added.
    ///
    /// Writes ONLY when the merge actually changed something. This used to save
    /// unconditionally, and `transcribe` calls it once per dictation — so every
    /// single dictation re-encoded the dictionary, wrote it to the App Group AND
    /// pushed it to the iCloud key-value store, on the latency path, for no
    /// change at all. iCloud throttles writes per-app, so the busiest user got
    /// throttled hardest.
    public static func mergeFromCloud() -> PersonalDictionary {
        var local = load()
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: storageKey),
              let remote = try? JSONDecoder().decode(PersonalDictionary.self, from: data)
        else { return local }

        let before = local.entries
        for entry in remote.entries { local.add(entry) }
        if local.entries != before { local.save() }
        return local
    }
}

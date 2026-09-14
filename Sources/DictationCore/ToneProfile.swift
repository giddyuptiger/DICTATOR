import Foundation

/// Where the cursor is should change how the text comes out. Dictating into
/// Terminal should not produce "Hi there! I hope this finds you well."
///
/// Wispr does this invisibly. Doing it as explicit, editable profiles is the part
/// worth stealing and improving: you can read the prompt, change it, and add your
/// own app without waiting on anyone.
public struct ToneProfile: Codable, Sendable, Identifiable {

    public var id: String { name }

    public let name: String
    /// Bundle identifiers this profile applies to, e.g. "com.apple.Terminal".
    public var bundleIDs: [String]
    /// Instructions appended to the base cleanup prompt.
    public var instructions: String

    public init(name: String, bundleIDs: [String], instructions: String) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.instructions = instructions
    }

    // MARK: - Prompt assembly

    private static let base = """
    You clean up dictated speech into written text. Rules:
    - Return ONLY the cleaned text. No preamble, no quotes, no commentary.
    - Remove filler: um, uh, like, you know, I mean, sort of, kind of.
    - Remove false starts and self-corrections. If the speaker restates something, \
    keep only the final version.
    - Add correct punctuation, capitalization, and paragraph breaks.
    - Obey spoken commands about formatting: "new paragraph", "bullet point", \
    "period", "quote unquote", "all caps". Execute them, do not transcribe them.
    - Do NOT add information, do NOT answer questions, do NOT continue the thought. \
    If the speaker asks a question, write the question down.
    - Preserve the speaker's voice and word choice. You are a typist, not an editor.

    STRUCTURE. Speech carries structure that punctuation alone loses. Recover it, \
    but only when the speaker's own words put it there:
    - Enumerated items become a bulleted list. Signals: "first, second, third", \
    "a few things", "one, two, three", or three or more parallel items in a row.
    - Ordered steps become a numbered list. Signals: "first you, then you", \
    "step one", "after that", a sequence that must happen in order.
    - A label followed by a value on several items becomes "Label: value" lines.
    - Everything else stays prose. A story, an opinion, a message to a person, \
    two items, or anything you are unsure about: leave it as sentences.

    The test is whether the speaker was listing or narrating. Narration that \
    merely contains the word "first" is still narration. When it is a close call, \
    prose is the safer error: a stray paragraph reads as normal writing, while \
    stray bullets read as a machine got hold of it.
    """

    public func systemPrompt(dictionaryHint: String) -> String {
        systemPrompt(dictionaryHint: dictionaryHint, mode: DictationMode.current)
    }

    /// The mode goes last on purpose: where it disagrees with the field's own
    /// profile, the register the speaker chose by hand should win.
    public func systemPrompt(dictionaryHint: String, mode: DictationMode) -> String {
        var parts = [Self.base, instructions]
        if !dictionaryHint.isEmpty { parts.append(dictionaryHint) }
        parts.append(mode.instructions)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Defaults

    public static let messaging = ToneProfile(
        name: "Messaging",
        bundleIDs: [
            "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
            "net.whatsapp.WhatsApp", "com.apple.iChat"
        ],
        instructions: """
        Casual register. Short sentences. Contractions. No greeting or sign-off \
        unless spoken. Keep it under-punctuated rather than formal: it is a chat message.
        Almost never use lists here. A chat message with bullet points reads as a \
        memo; only use them if the speaker explicitly asks for a list.
        """
    )

    public static let email = ToneProfile(
        name: "Email",
        bundleIDs: ["com.apple.mail", "com.google.Chrome", "com.superhuman.mail"],
        instructions: """
        Professional but warm. Complete sentences and real paragraphs. Do not invent \
        a greeting or sign-off, but if one is spoken, format it on its own line.
        """
    )

    public static let code = ToneProfile(
        name: "Code and terminal",
        bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"
        ],
        instructions: """
        Technical register. Keep identifiers, flags, paths and commands verbatim and \
        do not "correct" them into English. No trailing period on a command. \
        Interpret spoken punctuation literally: "dash dash verbose" is --verbose, \
        "dot slash" is ./, "underscore" is _.
        """
    )

    public static let longform = ToneProfile(
        name: "Longform writing",
        bundleIDs: ["com.apple.Notes", "com.literatureandlatte.scrivener3", "md.obsidian"],
        instructions: """
        Prose register. Real paragraphs, varied sentence length. Preserve the \
        speaker's rhythm and idiom rather than smoothing it into corporate English. \
        Never use em dashes: use commas, periods, parentheses, or colons instead.
        This is the one place where lists are welcome when the speaker is genuinely \
        listing: notes and drafts are where structure earns its keep.
        """
    )

    public static let neutral = ToneProfile(
        name: "Neutral",
        bundleIDs: [],
        instructions: "Neutral register. Match the formality of the speaker's own words."
    )

    public static let defaults: [ToneProfile] = [messaging, email, code, longform, neutral]

    /// Pick a profile for the frontmost app. Falls back to neutral.
    public static func forBundleID(_ id: String?, in profiles: [ToneProfile] = defaults) -> ToneProfile {
        guard let id else { return neutral }
        return profiles.first { $0.bundleIDs.contains(id) } ?? neutral
    }
}

// MARK: - User-selectable modes

/// The register the speaker picks by hand, as opposed to ToneProfile, which is
/// inferred from where the cursor is.
///
/// Both are applied: the profile decides what kind of text field this is, the
/// mode decides how formal the speaker wants to sound in it. The mode is stored
/// in the App Group so the keyboard can change it and the app can read it.
public enum DictationMode: String, CaseIterable, Sendable {
    case superCasual
    case casual
    case formal
    case emoji

    public var displayName: String {
        switch self {
        case .superCasual: return "super casual"
        case .casual:      return "casual"
        case .formal:      return "formal"
        case .emoji:       return "emoji"
        }
    }

    public var instructions: String {
        switch self {
        case .superCasual:
            return """
            SUPER CASUAL. Write how people actually text. Lowercase unless a word \
            needs the capital. Contractions everywhere. Drop sentence-initial \
            subjects where speech did ("gonna head out" not "I am going to head \
            out"). Minimal punctuation: no semicolons, few commas, and no period \
            on a final short line. Never formalize a word the speaker said \
            casually.
            """
        case .casual:
            return """
            CASUAL. Normal everyday writing. Sentence case, contractions, ordinary \
            punctuation. Friendly but not sloppy. This is the default register for \
            talking to someone you know.
            """
        case .formal:
            return """
            FORMAL. Complete sentences, no contractions, precise punctuation. \
            Replace casual connectives with their written equivalents ("so" becomes \
            "therefore" only where the logic genuinely warrants it, never as \
            decoration). Do not add flourish, length, or business vocabulary the \
            speaker did not use. Formal means disciplined, not inflated.
            """
        case .emoji:
            return """
            CASUAL, plus EXACTLY ONE emoji per message. One. Not one per sentence, \
            not one per paragraph: one for the whole message, placed where it lands \
            naturally, which is usually the end. Pick it from what the message is \
            actually about rather than its mood, and never use it to replace a word \
            the speaker said. If nothing fits, use no emoji rather than a generic \
            one.
            """
        }
    }

    // MARK: Persistence

    private static let key = "dictationMode"

    /// The App Group on iOS, where the keyboard and the app both need to see it.
    /// Falls back to standard defaults on the Mac, which has no extension to
    /// share with and may not carry the group entitlement at all.
    private static var store: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroup) ?? .standard
    }

    public static var current: DictationMode {
        get { DictationMode(rawValue: store.string(forKey: key) ?? "") ?? .casual }
        set { store.set(newValue.rawValue, forKey: key) }
    }

    /// Cycles to the next mode. The keyboard has one button and no room for a
    /// picker, and four modes is few enough that cycling beats a menu.
    @discardableResult
    public static func advance() -> DictationMode {
        let all = DictationMode.allCases
        let i = all.firstIndex(of: current) ?? 0
        let next = all[(i + 1) % all.count]
        current = next
        return next
    }
}

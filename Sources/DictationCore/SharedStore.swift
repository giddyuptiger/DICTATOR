import Foundation

/// The App Group container. Darwin notifications are the doorbell; this is the
/// parcel left on the step. Both the keyboard extension and the container app
/// read and write it.
public enum SharedStore {

    public static let appGroup = "group.design.irons.dictator"

    /// Deliberately rebuilt per access rather than cached.
    ///
    /// A cached suite is the obvious optimisation and it is NOT taken here: the
    /// keyboard's whole liveness test is reading a value the OTHER process just
    /// wrote, and a cached App Group suite in an extension is exactly where
    /// stale-cache reports cluster. A fresh instance re-reads through cfprefsd
    /// every time, which is what makes the handshake reliable. The cost is a
    /// container lookup; the handshake is worth more.
    private static var defaults: UserDefaults? {
        // On iOS the App Group is the shared channel between the keyboard and the
        // app. The Mac target carries no group entitlement (it would need a
        // provisioning profile the Developer ID build has no way to supply) and
        // has no extension to share with, so fall back to standard defaults,
        // which persist just the same for a single non-sandboxed process. Matches
        // ToneProfile.store.
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    private enum Key {
        static let transcript   = "transcript"
        static let resultToken  = "resultToken"   // changes on every new result
        static let error        = "lastError"
        static let errorRetry   = "lastErrorRetryable"
        static let engineWarm   = "engineWarm"
        static let warmAt       = "warmAt"
        static let groqKey      = "groqAPIKey"
        static let lastLatency  = "lastLatencyMS"
        static let liveState    = "liveState"
        static let liveAt       = "liveAt"
    }

    // MARK: - Live state

    /// The app stamps what it is doing, with a timestamp, on every transition.
    ///
    /// This exists because a Darwin round trip is a poor liveness test: the
    /// notification is a doorbell with no acknowledgement, and a backgrounded app
    /// is scheduled at the system's convenience, so "no pong in 400 ms" says
    /// nothing reliable about whether anyone is home. The App Group is the
    /// channel we know works, so liveness travels on it too.
    public static func setLiveState(_ s: String) {
        defaults?.set(s, forKey: Key.liveState)
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.liveAt)
    }

    public static var liveState: String? { defaults?.string(forKey: Key.liveState) }

    // MARK: - Durable log

    /// The app's activity log lives in the App Group, not in memory.
    ///
    /// An in-memory log vanishes when iOS jettisons the app, which is precisely
    /// the moment its contents matter most: you come back, the log looks like
    /// nothing happened, and the absence of evidence gets mistaken for evidence
    /// of absence. Sixty lines is plenty and costs nothing.
    public static func appendLog(_ line: String) {
        var lines = defaults?.stringArray(forKey: "logLines") ?? []
        lines.insert(line, at: 0)
        if lines.count > 60 { lines.removeLast(lines.count - 60) }
        defaults?.set(lines, forKey: "logLines")
    }

    public static var logLines: [String] { defaults?.stringArray(forKey: "logLines") ?? [] }

    public static func clearLog() { defaults?.removeObject(forKey: "logLines") }

    /// Swipe-typing diagnostics, kept apart from the activity log: a dictation
    /// writes about five activity lines, so a few of them pushed every swipe
    /// out of the 60-line log before it could be reported. 150 entries.
    public static func appendSwipeLog(_ line: String) {
        var lines = defaults?.stringArray(forKey: "swipeLogLines") ?? []
        lines.insert(line, at: 0)
        if lines.count > 150 { lines.removeLast(lines.count - 150) }
        defaults?.set(lines, forKey: "swipeLogLines")
    }

    public static var swipeLogLines: [String] { defaults?.stringArray(forKey: "swipeLogLines") ?? [] }

    /// Seconds since the app last stamped its state. Large means it is gone.
    public static var secondsSinceLive: TimeInterval {
        let at = defaults?.double(forKey: Key.liveAt) ?? 0
        guard at > 0 else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince1970 - at
    }

    // MARK: - Transcript handoff

    /// Written by the app, read by the keyboard. The token changes every time so
    /// the keyboard can tell a fresh result from a stale one.
    public static func publish(transcript: String, latencyMS: Int) {
        defaults?.set(transcript, forKey: Key.transcript)
        defaults?.set(latencyMS, forKey: Key.lastLatency)
        defaults?.set(UUID().uuidString, forKey: Key.resultToken)
        defaults?.removeObject(forKey: Key.error)
        defaults?.removeObject(forKey: Key.errorRetry)
    }

    /// `retryable` tells the keyboard whether tapping again should ask the app to
    /// retry on the kept audio (a network blip) or is a dead end (a bad key).
    public static func publish(error: String, retryable: Bool = false) {
        defaults?.set(error, forKey: Key.error)
        defaults?.set(retryable, forKey: Key.errorRetry)
        defaults?.set(UUID().uuidString, forKey: Key.resultToken)
        defaults?.removeObject(forKey: Key.transcript)
    }

    public static var transcript: String? { defaults?.string(forKey: Key.transcript) }
    public static var lastError: String?  { defaults?.string(forKey: Key.error) }
    public static var lastErrorRetryable: Bool { defaults?.bool(forKey: Key.errorRetry) ?? false }
    public static var resultToken: String? { defaults?.string(forKey: Key.resultToken) }
    public static var lastLatencyMS: Int { defaults?.integer(forKey: Key.lastLatency) ?? 0 }

    // MARK: - Liveness

    /// The app marks itself warm once its engine is running. The keyboard reads
    /// this to decide whether it needs a cold start.
    public static func setEngineWarm(_ warm: Bool) {
        defaults?.set(warm, forKey: Key.engineWarm)
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.warmAt)
    }

    /// Warm, and recently enough that we believe it. iOS can kill a backgrounded
    /// app without it getting a chance to clear the flag, so the timestamp is the
    /// real check.
    public static var isEngineWarm: Bool {
        guard defaults?.bool(forKey: Key.engineWarm) == true else { return false }
        let at = defaults?.double(forKey: Key.warmAt) ?? 0
        return Date().timeIntervalSince1970 - at < 60 * 60 * 6
    }

    // MARK: - Setup checklist

    /// The keyboard calls this when it appears. A keyboard extension can only
    /// reach the App Group when Full Access is on, so a successful write is proof
    /// the user granted it. The container app reads it back for the checklist.
    public static func markKeyboardFullAccess() {
        defaults?.set(Date().timeIntervalSince1970, forKey: "kbFullAccessAt")
    }

    public static var keyboardEverSeen: Bool {
        (defaults?.double(forKey: "kbFullAccessAt") ?? 0) > 0
    }

    /// Whether the first-run onboarding has been finished or skipped.
    public static var onboardingDone: Bool {
        get { defaults?.bool(forKey: "onboardingDone") ?? false }
        set { defaults?.set(newValue, forKey: "onboardingDone") }
    }

    // MARK: - Settings

    /// The app seeds this on launch (see DictatorApp) and the keyboard reads it
    /// back out of the App Group, so the key only has to exist in one place.
    public static var groqAPIKey: String? {
        get { defaults?.string(forKey: Key.groqKey) }
        set { defaults?.set(newValue, forKey: Key.groqKey) }
    }

    /// How long the mic may sit idle before Dictator releases it, in minutes.
    /// 0 means never release.
    ///
    /// How long the mic may sit idle before Dictator releases it, in minutes; 0
    /// means never. This now trades ONLY battery / the orange mic indicator against
    /// trips back to the app: Dictator no longer ducks or otherwise touches other
    /// apps' audio (it records over the music), so a shorter window no longer buys
    /// the user anything on the music front. Thirty minutes covers a normal
    /// conversation without the mic release landing in the middle of active use;
    /// the mic cannot be reopened from the background, so once released, a lull
    /// longer than the window costs a trip to the app and a swipe back.
    public static var idleReleaseMinutes: Int {
        get {
            guard let d = defaults, d.object(forKey: "idleReleaseMinutes") != nil else { return 30 }
            return d.integer(forKey: "idleReleaseMinutes")
        }
        set { defaults?.set(newValue, forKey: "idleReleaseMinutes") }
    }

    /// The last Groq cleanup model that worked, so we skip re-probing dead ones
    /// every time (Groq rotates models). Set by GroqCleanup on a successful call.
    public static var cleanupModel: String? {
        get { defaults?.string(forKey: "cleanupModel") }
        set { defaults?.set(newValue, forKey: "cleanupModel") }
    }

    /// Which transcription engine to use. `.onDevice` runs Parakeet locally (free,
    /// private, offline); `.cloud` sends audio to Groq (needs a key, best accuracy
    /// on hard audio). Defaults to `.cloud` for now — the on-device path is new and
    /// stays opt-in until it is proven on real devices, at which point this default
    /// flips. The keyboard reads nothing here; transcription runs in the container app.
    public static var transcriptionEngine: TranscriptionEngine {
        get { TranscriptionEngine(rawValue: defaults?.string(forKey: "transcriptionEngine") ?? "") ?? .onDevice }
        set { defaults?.set(newValue.rawValue, forKey: "transcriptionEngine") }
    }

    /// A stable per-install id sent to the backend so it can rate-limit per device.
    /// Random, not personally identifying; created once by Backend.deviceID.
    public static var deviceID: String? {
        get { defaults?.string(forKey: "deviceID") }
        set { defaults?.set(newValue, forKey: "deviceID") }
    }

    /// Opt-out product-analytics switch (see `Analytics`). Defaults to false:
    /// nothing is sent until analytics is deliberately enabled AND disclosed in
    /// the privacy policy / App Store label.
    public static var analyticsEnabled: Bool {
        get { defaults?.bool(forKey: "analyticsEnabled") ?? false }
        set { defaults?.set(newValue, forKey: "analyticsEnabled") }
    }

    /// Tiny generic one-time-flag helpers (e.g. the first_dictation marker used by
    /// `Analytics.trackOnce`).
    /// Swipe (glide) typing on the keyboard. On by default; stored inverted so a
    /// fresh install, with no value written yet, reads as enabled. Read by the
    /// keyboard on plane changes, written by the app's Settings.
    public static var swipeTypingEnabled: Bool {
        get { !(defaults?.bool(forKey: "swipeTypingDisabled") ?? false) }
        set { defaults?.set(!newValue, forKey: "swipeTypingDisabled") }
    }

    static func boolFlag(_ key: String) -> Bool { defaults?.bool(forKey: key) ?? false }
    static func setBoolFlag(_ key: String, _ value: Bool) { defaults?.set(value, forKey: key) }

    // MARK: - Emoji recents

    /// Most-recently-used emoji for the keyboard's Recents row, newest first.
    public static var recentEmoji: [String] {
        get { defaults?.stringArray(forKey: "recentEmoji") ?? [] }
        set { defaults?.set(Array(newValue.prefix(40)), forKey: "recentEmoji") }
    }

    /// Record an emoji as just used: move it to the front, de-duplicated, capped.
    public static func pushRecentEmoji(_ emoji: String) {
        var list = recentEmoji.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentEmoji = list
    }

    /// One-time flag: whether the previously-seeded embedded Groq key has been
    /// cleared so the install routes through the backend proxy instead.
    public static var keySeedClearedV1: Bool {
        get { defaults?.bool(forKey: "keySeedClearedV1") ?? false }
        set { defaults?.set(newValue, forKey: "keySeedClearedV1") }
    }

    /// The app used to seed its build-time Groq key into this store, so every user
    /// transcribed on the developer's key. That key now lives ONLY on the backend.
    /// Clear the old seeded value once so existing installs move to the proxy. A
    /// user who deliberately sets their own key (BYOK) later is unaffected — this
    /// runs a single time. Safe to call on every launch.
    public static func migrateKeyToBackendIfNeeded() {
        guard !keySeedClearedV1 else { return }
        groqAPIKey = nil
        keySeedClearedV1 = true
    }

    /// Set by the (now-reverted) 0.1.60 migration that forced the idle window to 1
    /// minute to get the user's music back sooner. 0.1.61 stopped touching music
    /// entirely, so that forced short window is no longer wanted; V2 below undoes it.
    public static var musicHoldMigratedV1: Bool {
        get { defaults?.bool(forKey: "musicHoldMigratedV1") ?? false }
        set { defaults?.set(newValue, forKey: "musicHoldMigratedV1") }
    }

    /// Corrective one-time migration. 0.1.60 auto-set some installs to a 1-minute
    /// idle window for a music reason that no longer applies (Dictator no longer
    /// ducks). If that forced value is still in place, put it back to the 30-minute
    /// default. Only touches the exact value 0.1.60 forced, so a window the user
    /// picked themselves is left alone. Runs once.
    public static var micHoldMigratedV2: Bool {
        get { defaults?.bool(forKey: "micHoldMigratedV2") ?? false }
        set { defaults?.set(newValue, forKey: "micHoldMigratedV2") }
    }

    /// Safe to call on every launch. Undoes the 0.1.60 forced 1-minute window once.
    public static func migrateMusicHoldIfNeeded() {
        guard !micHoldMigratedV2 else { return }
        // Only correct the value 0.1.60's migration forced; respect a deliberate choice.
        if musicHoldMigratedV1, idleReleaseMinutes == 1 {
            idleReleaseMinutes = 30
        }
        micHoldMigratedV2 = true
    }
}

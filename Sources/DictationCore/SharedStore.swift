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
        UserDefaults(suiteName: appGroup)
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
    /// This was a hard-coded five minutes, and it is the one setting that trades
    /// the two complaints against each other. A short window means the orange dot
    /// goes away sooner AND — the reason this now defaults short — the user's music
    /// comes back to full volume sooner: iOS holds other apps' audio at reduced
    /// volume the entire time the mic is hot, and there is no flag that stops that.
    /// The cost of a short window is that a lull longer than it costs a trip to the
    /// app and a swipe back (the mic cannot be reopened from the background). One
    /// minute keeps back-to-back dictation instant while giving the music straight
    /// back once the user stops; someone who dictates constantly and doesn't mind
    /// quieter music can pick a longer window or "Never".
    public static var idleReleaseMinutes: Int {
        get {
            guard let d = defaults, d.object(forKey: "idleReleaseMinutes") != nil else { return 1 }
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

    /// One-time migration flag for the music-friendly mic-hold default. The idle
    /// window used to default to 30 minutes, which meant iOS held the user's music
    /// at reduced volume for up to half an hour after a single dictation. We now
    /// default to 1 minute, but an existing install already has a stored value, so
    /// this flag lets us reset it once (and only once, so a later manual choice
    /// sticks). See migrateMusicHoldIfNeeded().
    public static var musicHoldMigratedV1: Bool {
        get { defaults?.bool(forKey: "musicHoldMigratedV1") ?? false }
        set { defaults?.set(newValue, forKey: "musicHoldMigratedV1") }
    }

    /// Reset the idle window to the new music-friendly default exactly once on an
    /// install that predates it, then never touch it again so the user's own later
    /// choice is respected. Safe to call on every launch.
    public static func migrateMusicHoldIfNeeded() {
        guard !musicHoldMigratedV1 else { return }
        idleReleaseMinutes = 1
        musicHoldMigratedV1 = true
    }
}

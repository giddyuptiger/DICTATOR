import Foundation

/// The App Group container. Darwin notifications are the doorbell; this is the
/// parcel left on the step. Both the keyboard extension and the container app
/// read and write it.
public enum SharedStore {

    public static let appGroup = "group.design.irons.dictator"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    private enum Key {
        static let transcript   = "transcript"
        static let resultToken  = "resultToken"   // changes on every new result
        static let error        = "lastError"
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
    }

    public static func publish(error: String) {
        defaults?.set(error, forKey: Key.error)
        defaults?.set(UUID().uuidString, forKey: Key.resultToken)
    }

    public static var transcript: String? { defaults?.string(forKey: Key.transcript) }
    public static var lastError: String?  { defaults?.string(forKey: Key.error) }
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

    // MARK: - Settings

    /// The app seeds this on launch (see DictatorApp) and the keyboard reads it
    /// back out of the App Group, so the key only has to exist in one place.
    public static var groqAPIKey: String? {
        get { defaults?.string(forKey: Key.groqKey) }
        set { defaults?.set(newValue, forKey: Key.groqKey) }
    }
}

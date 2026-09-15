import Foundation
@preconcurrency import AVFoundation

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// The warm app: one input engine, started in the foreground, never stopped.
///
/// THE ONE RULE: the microphone input engine is started once while the app is
/// foregrounded (warm-up) and then runs for the whole session. That is the only
/// thing that works. iOS refuses to START microphone input from the background
/// (kAUStartIO 2003329396), so the keyboard cannot ask a backgrounded app to
/// open the mic on demand. Instead the mic is already open, and a capture just
/// starts keeping the samples the running tap already produces.
///
/// The honest cost: the microphone, and the orange indicator, are on the whole
/// time Dictator is on, not only while you are dictating. Willow and Wispr have
/// the same property for the same reason. Surface it, do not hide it, and never
/// claim the mic is closed between dictations.


/// AVAudioConverter's input block can be invoked more than once per convert()
/// call. A captured `var` flag is a data race; this makes the one-shot contract
/// explicit and gives the closure a reference instead of a copy.
///
/// @unchecked Sendable: a OneShot is created and consumed entirely within one
/// synchronous convert() call on a single thread, never shared. The annotation
/// lets it be captured in the @Sendable converter block without a data-race
/// error under Swift 6 on Xcode 27 (which broke the CI archive).
private final class OneShot: @unchecked Sendable {
    private var used = false
    func take() -> Bool {
        if used { return false }
        used = true
        return true
    }
}

/// Owns the entire audio stack, and is deliberately NOT main-actor isolated.
///
/// Two separate failures came from getting this wrong, and they looked nothing
/// alike from the outside:
///
///  1. A tap block written inside a `@MainActor` method inherits main-actor
///     isolation, and Swift 6 honours that by emitting a `dispatch_assert_queue`
///     at the top of the block. CoreAudio calls taps from
///     `AURemoteIO::IOThread`, so the assertion fired on the first buffer and
///     the process trapped with "BUG IN CLIENT OF LIBDISPATCH".
///
///  2. `setCategory`, `setActive` and `engine.start()` are synchronous and can
///     each block for a long time while `mediaserverd` does its work. Run on the
///     main actor they hold it, so the UI paints once and then ignores every
///     touch. Indistinguishable from a crash on the device; obvious the moment
///     you notice the button still highlights.
///
/// Everything in here therefore runs off the main thread, and the only things
/// that cross back are plain values.
final class AudioEngineHost: @unchecked Sendable {

    enum StartError: Error {
        case session(Error)
        case noInputRoute
        case engine(Error)
        case badFormat
    }

    /// 16 kHz mono, which is what every speech model wants.
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Two engines, both started in the foreground and never stopped.
    ///
    /// Hard-won shape. Starting mic input from the BACKGROUND is refused
    /// (kAUStartIO 2003329396), so the input engine must start in the foreground
    /// during warm-up and stay running: a capture then starts no IO, it only
    /// flips a flag. The microphone (and the orange dot) is therefore on the
    /// whole session.
    ///
    /// The input engine is kept PURE input, with no player and no output
    /// connection. An earlier version ran a silent player through the SAME engine
    /// for background residency, which made it full-duplex and quietly gutted the
    /// captured audio: it recorded nine seconds and Whisper heard "Bye." So the
    /// silent keep-alive lives on a SEPARATE output-only engine. Playback is what
    /// keeps the backgrounded app resident (input alone gets suspended after a
    /// dictation), and keeping it off the input engine keeps the mic clean.
    private let inputEngine = AVAudioEngine()
    private let silenceEngine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var capturing = false
    private var latestLevel: Float = 0
    private var running = false
    private var silenceRunning = false
    private let lock = NSLock()

    // MARK: - Warm-up (foreground only)

    /// Claims the session, starts the input engine (required) and the silent
    /// keep-alive engine (best effort). MUST run foregrounded.
    func startWarm() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw StartError.session(error)
        }

        // Input engine: pure input, no output. This is what keeps the mic clean.
        let input = inputEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw StartError.noInputRoute }

        lock.lock()
        converter = AVAudioConverter(from: format, to: targetFormat)
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.handle(buf)
        }

        do {
            inputEngine.prepare()
            try inputEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw StartError.engine(error)
        }
        running = true

        // Silent keep-alive on its own engine, for background residency. This is
        // THE thing that keeps the backgrounded app resident so the keyboard can
        // reach it, so it is worth a retry: two concurrent engines can lose a
        // start race. If it still will not start, the mic works cleanly and the
        // app just risks being suspended (and then "Couldn't open Dictator")
        // sooner.
        do { try startSilence() }
        catch {
            silenceRunning = false
            do { try startSilence() } catch { silenceRunning = false }
        }
    }

    /// (Re)start ONLY the silent keep-alive. Safe to call from the BACKGROUND:
    /// starting playback from the background is allowed (only starting mic INPUT
    /// is refused). This regains residency after an interruption or a media reset
    /// stopped the player while we were backgrounded, WITHOUT touching the mic
    /// (which cannot restart until the app is foregrounded again). Losing the
    /// keep-alive is exactly what lets iOS suspend the app, after which the
    /// keyboard can no longer wake it — so keeping this playing is the whole game.
    func ensureSilenceAlive() {
        guard running else { return }                 // no session to keep alive
        if silenceEngine.isRunning, silence.isPlaying { return }
        silenceRunning = false                        // clear any stale flag
        do { try startSilence() } catch { silenceRunning = false }
    }

    private func startSilence() throws {
        guard !silenceRunning else { return }
        let rate = AVAudioSession.sharedInstance().sampleRate
        guard let outFormat = AVAudioFormat(
            standardFormatWithSampleRate: rate > 0 ? rate : 48_000,
            channels: 2
        ) else { throw StartError.badFormat }

        if silence.engine == nil { silenceEngine.attach(silence) }
        silenceEngine.connect(silence, to: silenceEngine.mainMixerNode, format: outFormat)

        do {
            silenceEngine.prepare()
            try silenceEngine.start()
        } catch {
            throw StartError.engine(error)
        }

        let frames = AVAudioFrameCount(outFormat.sampleRate * 0.5)
        guard frames > 0, let quiet = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) else {
            throw StartError.badFormat
        }
        quiet.frameLength = frames
        // CRITICAL: a freshly allocated AVAudioPCMBuffer holds UNINITIALISED
        // memory. Looping it as-is plays garbage through the speaker — the pops
        // and cracks — and that noise bleeds into the microphone, so a dictation
        // is captured over noise and Whisper returns "thank you". Zero every
        // channel so the keep-alive is genuinely silent.
        if let channels = quiet.floatChannelData {
            let bytes = Int(quiet.frameCapacity) * MemoryLayout<Float>.size
            for ch in 0..<Int(outFormat.channelCount) {
                memset(channels[ch], 0, bytes)
            }
        }
        silence.scheduleBuffer(quiet, at: nil, options: .loops)
        silence.play()
        silenceRunning = true
    }

    /// The mic engine is live.
    var isRunning: Bool { running && inputEngine.isRunning }
    /// The silent keep-alive is playing (background residency is protected).
    var isSilenceRunning: Bool { silenceRunning && silenceEngine.isRunning }

    /// Full teardown, user-initiated only.
    func stopEverything() {
        if silenceRunning {
            if silence.isPlaying { silence.stop() }
            silenceEngine.stop()
        }
        silenceRunning = false
        if running {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        }
        running = false
        lock.lock()
        converter = nil
        capturing = false
        samples.removeAll(keepingCapacity: false)
        latestLevel = 0
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Capture control (no IO start; the mic is already running)

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        capturing = true
        latestLevel = 0
        lock.unlock()
    }

    /// Returns everything captured and stops collecting. The engine keeps
    /// running; only the flag flips.
    func end() -> [Float] {
        lock.lock()
        capturing = false
        let out = samples
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        lock.unlock()
        return out
    }

    /// A non-destructive copy of what has been captured so far. Used to flush a
    /// long, still-running capture to disk periodically, so a crash mid-recording
    /// recovers the audio up to the last flush instead of losing all of it.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return latestLevel
    }

    // MARK: - Realtime thread

    private func handle(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        let active = capturing
        let conv = converter
        lock.unlock()

        guard active, let conv else { return }

        let ratio = targetFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let gate = OneShot()
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            guard gate.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let new = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))

        var sum: Float = 0
        for s in new { sum += s * s }
        let rms = (sum / Float(max(new.count, 1))).squareRoot()

        lock.lock()
        if capturing {
            samples.append(contentsOf: new)
            latestLevel = rms
        }
        lock.unlock()
    }
}

@MainActor
public final class BackgroundRecorder: ObservableObject {

    public enum State: Equatable {
        case cold
        case warm
        case capturing
        case transcribing
        case failed(String)

        /// What the keyboard sees in the App Group.
        var shortName: String {
            switch self {
            case .cold:         return "cold"
            case .warm:         return "warm"
            case .capturing:    return "capturing"
            case .transcribing: return "transcribing"
            case .failed:       return "failed"
            }
        }
    }

    @Published public private(set) var state: State = .cold {
        didSet { SharedStore.setLiveState(state.shortName) }
    }
    @Published public private(set) var level: Float = 0
    @Published public private(set) var lastTranscript: String = ""
    /// True when `lastTranscript` was recovered from a recording that a previous,
    /// crashed session had captured but not finished transcribing. The app labels
    /// the "Last dictation" card differently so the user understands where it came
    /// from.
    @Published public private(set) var lastWasRecovered = false
    @Published public private(set) var eventLog: [String] = []

    private let audio = AudioEngineHost()
    private var captureStartedAt: Date?
    private var levelTimer: Timer?
    private var isWarming = false
    private var heartbeat: Timer?
    private var captureCap: Timer?
    private var flushTimer: Timer?
    private var lifecycleObserved = false
    /// Whether the app is foregrounded. A dead engine can only be rebuilt while
    /// foregrounded (iOS refuses to start mic input from the background), so the
    /// health check and the interruption handlers only rebuild when this is true;
    /// otherwise recovery waits for the next foreground. Set by the app's scene.
    public var isForeground = true

    /// The last captured audio, kept after a failed transcription so the words
    /// are not lost to a network blip. The keyboard offers "Tap to try again",
    /// which posts .retry and lands in retryLastTranscription.
    private var lastSamples: [Float] = []

    public init() {
        eventLog = SharedStore.logLines
    }

    // MARK: - Crash-durable audio

    /// The captured audio is held in memory, so a crash or a jettison while a
    /// long transcription is in flight would lose the whole recording. Before we
    /// start transcribing we spill the raw samples to a file in the App Group
    /// container; on the next warm-up we transcribe whatever is left over. The
    /// file is deleted the moment an attempt reaches a terminal outcome, so it
    /// only ever holds audio that genuinely never got a result.
    ///
    /// Format is bare little-endian Float32 at 16 kHz mono — the same array the
    /// rest of the pipeline speaks — so persist and restore are a straight
    /// memory copy with no encode/decode to get wrong.
    private static var pendingURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroup)?
            .appendingPathComponent("pending.pcmf32")
    }

    private func persistPending(_ samples: [Float]) {
        guard let url = Self.pendingURL, !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!, count: raw.count)
        }
        do { try data.write(to: url, options: .atomic) }
        catch { log("persist failed: \(String(describing: error).prefix(80))") }
    }

    private func readPending() -> [Float]? {
        guard let url = Self.pendingURL,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return nil }
        // Copy the bytes into a properly-aligned Float buffer. Binding Data's raw
        // buffer directly to Float assumes 4-byte alignment that Data does not
        // guarantee — reading through it is undefined and can crash on launch,
        // which is exactly when this runs (recovering a file left by an earlier
        // crash). copyBytes is alignment-safe.
        var floats = [Float](repeating: 0, count: count)
        let copied = floats.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, count: count * MemoryLayout<Float>.stride)
        }
        guard copied == count * MemoryLayout<Float>.stride else { return nil }
        return floats
    }

    private func clearPending() {
        guard let url = Self.pendingURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Lifecycle

    /// Must be called while the app is FOREGROUNDED. That is when iOS grants the
    /// audio IO that the background mode then preserves.
    public func warmUp() async {
        guard state == .cold else {
            log("warmUp ignored, already \(state)")
            return
        }
        guard !isWarming else {
            log("warmUp ignored, one already in flight")
            return
        }
        isWarming = true
        defer { isWarming = false }

        log("warmUp begin")

        // Asking again when the answer is already on file is not free: with a
        // request already outstanding the system can simply never call back, and
        // an await that never resumes looks exactly like a dead button.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            log("mic: already granted")
        case .denied:
            state = .failed("Microphone denied in Settings")
            return
        default:
            log("mic: asking")
            let granted = await AVAudioApplication.requestRecordPermission()
            log("mic: \(granted ? "granted" : "refused")")
            guard granted else {
                state = .failed("Microphone permission denied")
                return
            }
        }

        log("warm: starting mic engine (foreground)")
        let host = audio

        // Warm-up gets refused when another app is holding the microphone
        // non-mixably: setActive returns 560557684, CannotInterruptOthers. That
        // is transient, the other app finishes, so retry a few times before
        // giving up. Each try is bounded so a blocked setActive can never hang
        // the warm-up: on iOS these calls can wedge for a minute or more, and
        // the earlier code just sat there.
        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            do {
                try await withWarmUpTimeout(seconds: 5) {
                    try host.startWarm()
                }
                if host.isRunning {
                    log(host.isSilenceRunning
                        ? "warm: mic live, keep-alive on"
                        : "warm: mic live, keep-alive OFF (residency at risk)")
                } else {
                    log("warm: engine NOT running, app will be suspended")
                }
                state = .warm
                SharedStore.setEngineWarm(true)
                startHeartbeat()
                listen()
                observeAudioLifecycle()
                recoverPendingIfAny()
                return
            } catch {
                let (message, retryable) = warmUpFailure(error)
                log("keep-alive attempt \(attempt)/\(maxAttempts) failed: \(message)")
                if retryable, attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                state = .failed(message)
                return
            }
        }
    }

    /// Re-run warm-up after a failure. warmUp itself only fires from .cold, so a
    /// failed state has to be cleared first. This is what the Try again button
    /// calls, and it is the difference between a recoverable hiccup and an app
    /// that looks dead.
    /// Convenience for the view: is the recorder sitting in a failed state.
    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    public func retryWarmUp() async {
        guard case .failed = state else { return }
        state = .cold
        await warmUp()
    }

    /// Bring the engine back to life if it died while we were away.
    ///
    /// This is the fix for the worst bug: use it a few times, leave the app or
    /// wait, and it says "wake" and is impossible to wake even by returning — only
    /// a force-quit fixes it. Cause: iOS suspends or kills the audio engine while
    /// backgrounded (or an interruption stops it), but `state` stays `.warm`, so
    /// `warmUp()` no-ops (`guard state == .cold`) and nothing ever restarts the
    /// engine. Returning to the app did nothing because nothing checked whether
    /// the engine was actually alive. Now the app calls this on every foreground:
    /// if we are nominally warm but the engine is not running, tear down fully and
    /// warm again from scratch.
    private var lastRebuildAt: Date?

    public func resync() async {
        guard !isWarming else { return }           // a warm-up is already running
        switch state {
        case .warm:
            if audio.isRunning { return }          // genuinely alive, nothing to do
            // Cooldown: never rebuild more than once every few seconds. This is a
            // hard stop against a feedback loop — a rebuild that itself briefly
            // reports "not running", or an event that fires repeatedly, must not
            // be able to churn the engine (which pops the speaker and wrecks
            // capture). If it is still dead after the cooldown, the next trigger
            // handles it.
            if let last = lastRebuildAt, Date().timeIntervalSince(last) < 8 { return }
            log("resync: engine died while away; rebuilding")
            lastRebuildAt = Date()
            teardownForRewarm()
            state = .cold
        case .failed:
            state = .cold                           // clear so warmUp can run
        case .cold:
            break                                   // just warm below
        case .capturing, .transcribing:
            return                                  // mid-flight, leave it
        }
        await warmUp()
    }

    /// Full teardown so `warmUp` can start clean: stop the timers, drop the Darwin
    /// observers (re-adding without removing would double-fire every signal), and
    /// stop the audio host so its `running` flag is cleared and `startWarm` will
    /// actually rebuild instead of early-returning.
    private func teardownForRewarm() {
        stopLevelTimer()
        heartbeat?.invalidate(); heartbeat = nil
        captureCap?.invalidate(); captureCap = nil
        flushTimer?.invalidate(); flushTimer = nil
        DarwinBridge.shared.stopObserving()
        audio.stopEverything()
    }

    /// One-time observers for the two events that stop the engine and DO NOT
    /// re-fire as a result of our own rebuild: an audio-session interruption
    /// ending (a phone call finishing), and a mediaserverd reset. Both are safe to
    /// react to. We deliberately do NOT observe AVAudioEngineConfigurationChange —
    /// rebuilding the engine itself posts that notification, so reacting to it
    /// creates a rebuild loop that churns the audio session (speaker pops, wrecked
    /// capture). Silent deaths are caught on the next foreground by `resync`,
    /// which is also rate-limited as a backstop.
    private func observeAudioLifecycle() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        let nc = NotificationCenter.default

        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended {
                    self.log("audio interruption ended; rebuilding")
                    // Regain residency immediately — playback can restart from the
                    // background, so this works even when we are not foregrounded.
                    self.audio.ensureSilenceAlive()
                    // The mic can only restart in the foreground; do the full
                    // rebuild there.
                    if self.isForeground { Task { await self.resync() } }
                } else {
                    self.log("audio interrupted")
                }
            }
        }

        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("media services reset; rebuilding")
                self.audio.ensureSilenceAlive()   // best-effort residency from bg
                if self.isForeground { Task { await self.resync() } }
            }
        }
    }

    private enum WarmUpError: Error { case timedOut }

    /// Runs a blocking audio call off the main thread and gives up waiting after
    /// `seconds`. If it times out the UI recovers and offers a retry; the call
    /// itself cannot be cancelled once CoreAudio is inside it, so the orphaned
    /// worker is left to unwind on its own.
    private func withWarmUpTimeout(
        seconds: Double,
        _ work: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(priority: .userInitiated) { try work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WarmUpError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Maps a warm-up error to a reader-facing line and whether retrying is
    /// worth it. CannotInterruptOthers and a timeout are transient; a denied
    /// microphone or a bad format is not.
    private func warmUpFailure(_ error: Error) -> (message: String, retryable: Bool) {
        if error is WarmUpError {
            return ("Audio was busy, trying again", true)
        }
        if case AudioEngineHost.StartError.session(let underlying) = error {
            let code = (underlying as NSError).code
            if code == 560557684 {   // '!int', CannotInterruptOthers
                return ("Another app is using the microphone", true)
            }
            return ("Audio session couldn't start (\(code))", true)
        }
        if case AudioEngineHost.StartError.noInputRoute = error {
            return ("No microphone input available", false)
        }
        if case AudioEngineHost.StartError.engine(let underlying) = error {
            return ("Audio engine couldn't start (\((underlying as NSError).code))", true)
        }
        if case AudioEngineHost.StartError.badFormat = error {
            return ("Unexpected audio format", false)
        }
        return (error.localizedDescription, true)
    }

    /// A stamp every two seconds. The keyboard treats a stale stamp as "the app
    /// is gone" and only then pays for a bounce.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .cold else { return }
                // Health check: if we think we are warm but the engine has died,
                // rebuild — but only while foregrounded, and `resync` is rate-
                // limited so a flapping engine can never turn this 2 s tick into a
                // rebuild loop (which pops the speaker and wrecks capture).
                if self.state == .warm, !self.audio.isRunning, self.isForeground {
                    self.log("heartbeat: engine not running; rebuilding")
                    Task { await self.resync() }
                    return
                }
                SharedStore.setLiveState(self.state.shortName)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    /// Deliberate teardown, user-initiated only.
    public func shutDown() {
        stopLevelTimer()
        heartbeat?.invalidate()
        heartbeat = nil
        captureCap?.invalidate()
        captureCap = nil
        flushTimer?.invalidate()
        flushTimer = nil
        let host = audio
        Task.detached(priority: .userInitiated) { host.stopEverything() }
        SharedStore.setEngineWarm(false)
        state = .cold
        log("engine stopped by user")
    }

    // MARK: - Darwin signals from the keyboard

    private func listen() {
        let bridge = DarwinBridge.shared

        bridge.observe(.ping) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state != .cold else { return }
                bridge.post(.pong)
            }
        }

        bridge.observe(.startRecording) { [weak self] in
            MainActor.assumeIsolated { self?.beginCapture() }
        }

        bridge.observe(.stopRecording) { [weak self] in
            MainActor.assumeIsolated { self?.endCapture() }
        }

        bridge.observe(.retry) { [weak self] in
            MainActor.assumeIsolated { self?.retryLastTranscription() }
        }

        // Safety net. If the keyboard is dismissed mid-capture the stop tap will
        // never come, and a microphone held open by an abandoned capture is
        // exactly the thing we are trying to avoid.
        bridge.observe(.keyboardHidden) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing else { return }
                self.log("keyboard dismissed mid-capture")
                self.endCapture()
            }
        }

        log("listening for keyboard")
    }

    // MARK: - Capture

    /// Warm the engine if needed, then begin capturing. This is what the
    /// keyboard's cold-start URL (dictator://dictate) drives: the app may have
    /// just launched from cold, so we cannot assume the engine is warm. Warm (or
    /// resync a dead one), wait for it to actually reach `.warm`, then capture —
    /// so waking from the keyboard genuinely starts a recording.
    public func warmAndCapture() async {
        if state != .warm { await resync() }
        // resync() runs warmUp(); give it a brief window to land on .warm before
        // we begin, since the audio start is off the main thread.
        if state != .warm {
            for _ in 0..<20 {   // up to ~2s
                try? await Task.sleep(nanoseconds: 100_000_000)
                if state == .warm || isFailed { break }
            }
        }
        guard state == .warm else {
            log("warmAndCapture: engine not warm (\(state)); not capturing")
            return
        }
        beginCapture()
    }

    public func beginCapture() {
        guard state == .warm else {
            log("start ignored, state \(state)")
            return
        }
        // The mic is already running from warm-up. Capture starts no IO; it
        // just tells the running tap to start keeping samples. This is why it
        // works from the background: nothing is being started here.
        state = .capturing
        audio.begin()
        captureStartedAt = Date()
        startLevelTimer()
        startCaptureCap()
        startFlush()
        log("capturing")
    }

    /// While a capture is running, spill what we have to disk every so often. A
    /// crash or jettison mid-recording then recovers everything up to the last
    /// flush on next launch, instead of losing the whole in-progress dictation.
    /// This is the crash protection for a long recording that has not been
    /// stopped yet; the flush on endCapture then supersedes it with the complete
    /// audio. Twenty seconds keeps the write rare (each is a few hundred KB to a
    /// couple of MB) while bounding the worst-case loss to the last 20 seconds.
    private func startFlush() {
        flushTimer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing else { return }
                let snap = self.audio.snapshot()
                guard snap.count > 3_200 else { return }
                self.persistPending(snap)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    /// A capture with no stop signal must not run forever, but it must be long
    /// enough for a real long-form dictation. Five minutes covers that and is
    /// still a hard backstop against a lost stop signal holding the mic open.
    /// (Five minutes of 16 kHz mono Float32 is ~19 MB in memory — fine.)
    private func startCaptureCap() {
        captureCap?.invalidate()
        let t = Timer(timeInterval: 300, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing else { return }
                self.log("capture hit the 5 minute cap")
                self.endCapture()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        captureCap = t
    }

    public func endCapture() {
        guard state == .capturing else { return }
        let samples = audio.end()
        stopLevelTimer()
        captureCap?.invalidate()
        captureCap = nil
        flushTimer?.invalidate()
        flushTimer = nil

        // The mic keeps running (it has to, to stay startable); we only stop
        // collecting. The audio is already in memory by this point.
        state = .transcribing
        level = 0
        let seconds = Double(samples.count) / 16_000
        log(String(format: "captured %.1fs", seconds))

        guard samples.count > 3_200 else {   // under 0.2 s
            // Tell the keyboard, otherwise it waits at "Transcribing" for a
            // result that never comes.
            log("too short, discarded")
            finish(error: "Didn't catch that", retryable: false)
            return
        }

        // SILENCE GATE. Whisper (which Groq runs) was trained on mountains of
        // YouTube captions, so on silent or near-silent audio it confidently
        // hallucinates "Thank you", "Thanks for watching", "Bye" etc. If the user
        // tapped talk, said nothing, and tapped stop, sending that to Groq types
        // "thank you" into their text field. Catch it here: if the clip carries no
        // real speech energy, never send it. This is a different bug from the
        // unzeroed-buffer noise fixed in 0.1.24 — this is genuine quiet input.
        if Self.isLikelySilence(samples) {
            log(String(format: "silent clip (%.1fs), discarded", seconds))
            finish(error: "Didn't catch that", retryable: false)
            return
        }

        // Spill to disk before the network round trip, so a crash mid-transcribe
        // recovers the recording on next launch instead of losing it.
        persistPending(samples)
        Task { await transcribe(samples) }
    }

    /// The meter is polled rather than pushed. Pushing meant spawning a Task per
    /// audio buffer, roughly twenty a second, purely to move one Float.
    private func startLevelTimer() {
        stopLevelTimer()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.audio.level
            }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Transcription

    /// Re-runs transcription on the audio kept from a failed attempt. Wired to
    /// the keyboard's "Tap to try again" through the .retry Darwin signal.
    public func retryLastTranscription() {
        guard state == .warm, !lastSamples.isEmpty else { return }
        let samples = lastSamples
        state = .transcribing
        log("retrying \(String(format: "%.1fs", Double(samples.count) / 16_000))")
        Task { await transcribe(samples) }
    }

    /// Called once after warm-up. If a previous session captured a recording but
    /// crashed or was killed before it produced a result, the raw audio is still
    /// on disk; transcribe it now and surface it in the app so the words are not
    /// lost. Deliberately does NOT touch the keyboard result channel or the state
    /// machine: it runs quietly in the background while the app stays ready to
    /// dictate, and only fills the "Last dictation" card if the user has not
    /// already dictated since launch.
    private func recoverPendingIfAny() {
        guard let samples = readPending() else { return }
        guard samples.count > 3_200 else { clearPending(); return }   // too short to matter
        guard let key = SharedStore.groqAPIKey, !key.isEmpty else { return }  // no key yet; keep the file
        log(String(format: "recovering %.1fs from a previous session", Double(samples.count) / 16_000))
        Task { await recover(samples) }
    }

    private func recover(_ samples: [Float]) async {
        guard let key = SharedStore.groqAPIKey, !key.isEmpty else { return }
        let dictionary = PersonalDictionary.mergeFromCloud()
        let speech = GroqTranscription(apiKey: key, biasTerms: dictionary.entries.map(\.canonical))
        let cleaner = Cleaner(provider: GroqCleanup(apiKey: key), dictionary: dictionary)
        do {
            let raw = try await speech.transcribe(samples: samples)
            guard !raw.isEmpty else { clearPending(); return }
            let cleaned = await cleaner.process(raw, profile: ToneProfile.neutral)
            clearPending()
            // Never clobber a fresh result: only fill the card if it is still empty.
            if lastTranscript.isEmpty {
                lastTranscript = cleaned.text
                lastWasRecovered = true
            }
            log("recovered: \(cleaned.text.prefix(40))")
        } catch {
            // Leave the file in place; a later launch, or a better connection,
            // can recover it. Recovery is best effort and must never throw away
            // the only copy of the audio because one attempt failed.
            log("recovery deferred: \(String(describing: error).prefix(80))")
        }
    }

    // MARK: - Silence / hallucination detection

    /// Peak amplitude and overall RMS of a clip, plus the fraction of 30 ms
    /// frames that carry real energy. Speech clears these easily; silence and
    /// room tone do not.
    private static func energy(_ samples: [Float]) -> (rms: Float, peak: Float, voicedRatio: Float) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        var sum: Float = 0, peak: Float = 0
        for s in samples {
            let a = abs(s)
            sum += s * s
            if a > peak { peak = a }
        }
        let rms = (sum / Float(samples.count)).squareRoot()

        let frame = 480   // 30 ms at 16 kHz
        var voiced = 0, total = 0, i = 0
        while i + frame <= samples.count {
            var fs: Float = 0
            for j in i..<(i + frame) { fs += samples[j] * samples[j] }
            if (fs / Float(frame)).squareRoot() > 0.01 { voiced += 1 }
            total += 1
            i += frame
        }
        let voicedRatio = total > 0 ? Float(voiced) / Float(total) : 0
        return (rms, peak, voicedRatio)
    }

    /// Genuine silence / room tone: quiet on ALL three measures. Conservative on
    /// purpose — real speech (even quiet speech) clears at least one of these — so
    /// we almost never reject a real dictation.
    static func isLikelySilence(_ samples: [Float]) -> Bool {
        let e = energy(samples)
        return e.rms < 0.012 && e.peak < 0.08 && e.voicedRatio < 0.05
    }

    /// Looser than isLikelySilence: near-silence that squeaked past the primary
    /// gate. Used only together with a known hallucination phrase.
    static func isLowEnergy(_ samples: [Float]) -> Bool {
        let e = energy(samples)
        return e.rms < 0.02 && e.voicedRatio < 0.1
    }

    /// Whisper's notorious outputs on silence/near-silence — the ones it emits
    /// with no matching speech, from being trained on caption tracks.
    private static let hallucinationPhrases: Set<String> = [
        "thank you", "thank you.", "thank you very much", "thank you very much.",
        "thanks for watching", "thanks for watching!", "thanks for watching.",
        "thank you for watching", "thank you for watching.",
        "bye", "bye.", "bye bye", "bye-bye.", "you", "you.",
        "please subscribe", "please subscribe.",
    ]

    /// True when the transcript is only a known silence-hallucination phrase.
    static func isHallucinationPhrase(_ raw: String) -> Bool {
        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hallucinationPhrases.contains(norm)
    }

    private func transcribe(_ samples: [Float]) async {
        // Hold onto the audio until we know the attempt succeeded, so a network
        // failure offers a retry instead of losing the words.
        lastSamples = samples

        let started = Date()
        guard let key = SharedStore.groqAPIKey, !key.isEmpty else {
            finish(error: "Add your Groq key in Dictator", retryable: false)
            return
        }

        let dictionary = PersonalDictionary.mergeFromCloud()
        let speech = GroqTranscription(apiKey: key, biasTerms: dictionary.entries.map(\.canonical))
        let cleaner = Cleaner(provider: GroqCleanup(apiKey: key), dictionary: dictionary)

        do {
            let raw = try await speech.transcribe(samples: samples)
            guard !raw.isEmpty else {
                lastSamples = []
                finish(error: "Nothing heard", retryable: false)
                return
            }
            // Backstop for the Whisper silence-hallucination: if the clip was
            // low energy AND the model returned one of its notorious silence
            // phrases ("thank you", "thanks for watching", …), it did not hear
            // speech — discard rather than type it. Gated on low energy so a real
            // dictation of "thank you" into a text still goes through.
            if Self.isLowEnergy(samples), Self.isHallucinationPhrase(raw) {
                lastSamples = []
                log("dropped silence hallucination: \(raw.prefix(30))")
                finish(error: "Didn't catch that", retryable: false)
                return
            }
            // The host app is unknowable to a keyboard on iOS 26.4+, so we
            // cannot pick a per-app tone profile. Use neutral and let the mode
            // the user chose on the keyboard be the sole register control.
            let cleaned = await cleaner.process(raw, profile: ToneProfile.neutral)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("mode: \(DictationMode.current.displayName)")
            log(cleaned.usedProvider ? "cleanup: applied" : "cleanup: NOT applied (\(cleaned.note ?? "unknown"))")
            finish(text: cleaned.text, ms: ms)
        } catch {
            let (message, retryable) = Self.classify(error)
            finish(error: message, retryable: retryable)
        }
    }

    /// Turn a transcription error into a short, honest pill message and whether
    /// tapping again should retry. A rejected key is not retryable; a network
    /// blip is.
    private static func classify(_ error: Error) -> (String, Bool) {
        if let groq = error as? GroqTranscription.GroqError {
            switch groq {
            case .http(let status, _):
                if status == 401 || status == 403 {
                    return ("Groq rejected the key. Check it in Dictator.", false)
                }
                return ("Groq had a problem. Tap to try again.", true)
            case .missingKey:
                return ("Add your Groq key in Dictator", false)
            case .emptyAudio:
                return ("Nothing heard", false)
            case .unparseable:
                return ("Couldn't read Groq's reply. Tap to try again.", true)
            }
        }
        // URLSession errors (offline, timeout, cancelled) are all retryable.
        return ("Couldn't reach Groq. Tap to try again.", true)
    }

    private func finish(text: String, ms: Int) {
        lastSamples = []
        clearPending()               // succeeded: the recording is safely typed out
        lastWasRecovered = false
        lastTranscript = text
        SharedStore.publish(transcript: text, latencyMS: ms)
        DarwinBridge.shared.post(.resultReady)
        state = .warm
        log("\(ms) ms: \(text.prefix(40))")
    }

    private func finish(error: String, retryable: Bool) {
        // A dead-end failure discards the audio (memory and disk); a retryable one
        // keeps both, so "Tap to try again" works and a crash before the retry
        // still recovers on next launch.
        if !retryable { lastSamples = []; clearPending() }
        SharedStore.publish(error: error, retryable: retryable)
        DarwinBridge.shared.post(.failed)
        state = .warm
        log("error: \(error)")
    }

    /// Lets the UI write into the same log, so "the button did nothing" and
    /// "the button ran and then stalled" stop looking identical.
    public func note(_ s: String) { log(s) }

    private func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(t)  \(s)"
        SharedStore.appendLog(line)
        eventLog = SharedStore.logLines
    }

    public func reloadLog() { eventLog = SharedStore.logLines }
    public func clearLog() { SharedStore.clearLog(); eventLog = [] }
}

import Foundation
@preconcurrency import AVFoundation

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// The warm engine.
///
/// THE ONE RULE: once started, the engine is NEVER stopped. Stopping audio IO is
/// what forfeits the right to restart it from the background. So the engine runs
/// continuously and the tap simply discards samples when we are not capturing.
///
/// That is the entire reason a keyboard can trigger a recording without bouncing
/// to this app: the app is already holding live audio IO, granted while it was
/// foregrounded and kept by the `audio` background mode.
///
/// The honest cost: the orange microphone indicator stays lit for the whole
/// session, because the microphone genuinely is open. Willow and Wispr have the
/// same property. Do not try to hide it; surface it and give the user a stop.


/// AVAudioConverter's input block can be invoked more than once per convert()
/// call. A captured `var` flag is a data race; this makes the one-shot contract
/// explicit and gives the closure a reference instead of a copy.
private final class OneShot {
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

    /// Two engines, deliberately.
    ///
    /// `keepAlive` only ever plays silence. It never touches an input node, so
    /// the session can sit in .playback and no microphone is open: no orange
    /// indicator, nothing recording, and the process still stays resident
    /// because the system sees continuous audio playback.
    ///
    /// `recorder` is built when the microphone is actually wanted and torn down
    /// the moment it is not. It has to be a separate instance: once an
    /// AVAudioEngine has instantiated its inputNode, that node stays in its
    /// graph, and starting that engine under a playback-only session fails.
    ///
    /// The cost of the split is a session category change and a brief engine
    /// restart when the keyboard appears, which is once per keyboard, not once
    /// per sentence.
    private let keepAlive = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    private var recorder: AVAudioEngine?

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var capturing = false
    private var latestLevel: Float = 0
    private let lock = NSLock()

    // MARK: - Keep-alive (no microphone)

    /// Called once, while foregrounded, and never again.
    ///
    /// The category is .playAndRecord from the very start even though no
    /// microphone is opened yet, and that is the important part. A backgrounded
    /// app is NOT allowed to activate a session that would interrupt other
    /// apps: setActive fails with OSStatus 560557684, which is '!int',
    /// AVAudioSessionErrorCodeCannotInterruptOthers. So the session has to be
    /// claimed here, in the foreground, where interrupting others is permitted,
    /// and then left completely alone.
    ///
    /// Nothing after this point touches setCategory or setActive. Opening the
    /// microphone only builds an engine and installs a tap on a session that is
    /// already ours.
    ///
    /// The category alone does not light the orange indicator: that tracks
    /// actual input, which only runs while the recorder engine does.
    func startKeepAlive() throws {
        try setSession(record: true)
        try runKeepAlive()
    }

    private func setSession(record: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            if record {
                // No .mixWithOthers: that marks the app's audio secondary and
                // iOS suspends secondary audio apps in the background.
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw StartError.session(error)
        }
    }

    /// (Re)starts the silent player. Called again after any category change,
    /// because the hardware format can move underneath it.
    private func runKeepAlive() throws {
        if keepAlive.isRunning { keepAlive.stop() }
        if silence.isPlaying { silence.stop() }

        let rate = AVAudioSession.sharedInstance().sampleRate
        guard let out = AVAudioFormat(
            standardFormatWithSampleRate: rate > 0 ? rate : 48_000,
            channels: 2
        ) else { throw StartError.badFormat }

        if silence.engine == nil { keepAlive.attach(silence) }
        keepAlive.connect(silence, to: keepAlive.mainMixerNode, format: out)

        do {
            keepAlive.prepare()
            try keepAlive.start()
        } catch {
            throw StartError.engine(error)
        }

        let frames = AVAudioFrameCount(out.sampleRate * 0.5)
        guard frames > 0, let quiet = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: frames) else {
            throw StartError.badFormat
        }
        // AVAudioPCMBuffer allocates cleared memory, so frameLength is all it
        // takes to make half a second of silence.
        quiet.frameLength = frames
        silence.scheduleBuffer(quiet, at: nil, options: .loops)
        silence.play()
    }

    var isKeepAliveRunning: Bool { keepAlive.isRunning && silence.isPlaying }

    // MARK: - Microphone, held only while wanted

    /// Returns the input sample rate.
    ///
    /// Deliberately does not touch the audio session. See startKeepAlive: any
    /// session change from the background is refused, and this is called from
    /// the background every single time.
    func openMic() throws -> Double {
        if recorder != nil { return AVAudioSession.sharedInstance().sampleRate }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw StartError.noInputRoute }

        lock.lock()
        converter = AVAudioConverter(from: format, to: targetFormat)
        lock.unlock()

        // Formed in a nonisolated method so no actor isolation is inherited. A
        // tap block that inherits @MainActor gets a dispatch_assert_queue
        // compiled into it, and CoreAudio calls taps from its realtime thread,
        // which traps the process on the first buffer.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.handle(buf)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw StartError.engine(error)
        }

        recorder = engine
        return format.sampleRate
    }

    /// Releases the microphone by destroying the engine that owns it. The
    /// session is left exactly as it is, because handing it back would mean
    /// asking for it again later from the background, which is not allowed.
    func closeMic() {
        if let engine = recorder {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recorder = nil
        lock.lock()
        converter = nil
        capturing = false
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    var isMicOpen: Bool { recorder != nil }

    /// Full teardown, user-initiated.
    func stopEverything() {
        closeMic()
        if silence.isPlaying { silence.stop() }
        if keepAlive.isRunning { keepAlive.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Capture control

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        capturing = true
        latestLevel = 0
        lock.unlock()
    }

    /// Returns everything captured and stops.
    func end() -> [Float] {
        lock.lock()
        capturing = false
        let out = samples
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        lock.unlock()
        return out
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
    @Published public private(set) var eventLog: [String] = []

    private let audio = AudioEngineHost()
    private var captureStartedAt: Date?
    private var levelTimer: Timer?
    private var isWarming = false
    private var heartbeat: Timer?
    private var captureCap: Timer?

    public init() {
        eventLog = SharedStore.logLines
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

        log("keep-alive: starting (no microphone)")
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
                    try host.startKeepAlive()
                }
                log(host.isKeepAliveRunning
                    ? "keep-alive: silence playing, mic CLOSED"
                    : "keep-alive: NOT PLAYING, app will be suspended")
                state = .warm
                SharedStore.setEngineWarm(true)
                startHeartbeat()
                listen()
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

    public func beginCapture() {
        guard state == .warm else {
            log("start ignored, state \(state)")
            return
        }
        state = .capturing          // claim it now so a second tap cannot double-start
        Task { await openMicAndCapture() }
    }

    /// The microphone is opened here and nowhere else. It is not held while the
    /// keyboard is merely on screen, and not held between dictations: you tap to
    /// talk, and that tap is what opens it.
    private func openMicAndCapture() async {
        let host = audio
        do {
            let rate = try await Task.detached(priority: .userInitiated) {
                try host.openMic()
            }.value
            audio.begin()
            captureStartedAt = Date()
            startLevelTimer()
            startCaptureCap()
            log("mic OPEN, capturing at \(Int(rate)) Hz")
        } catch {
            log("mic failed: \(error)")
            state = .warm
        }
    }

    /// A capture with no stop signal must not run forever. Two minutes is longer
    /// than any sensible utterance and short enough to be a bug, not a bill.
    private func startCaptureCap() {
        captureCap?.invalidate()
        let t = Timer(timeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing else { return }
                self.log("capture hit the 2 minute cap")
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

        // Microphone goes straight back. Nothing downstream needs it: the audio
        // is already in memory by this point.
        let host = audio
        Task.detached(priority: .userInitiated) { host.closeMic() }
        log("mic CLOSED")

        state = .transcribing
        level = 0
        let seconds = Double(samples.count) / 16_000
        log(String(format: "captured %.1fs", seconds))

        guard samples.count > 3_200 else {   // under 0.2 s
            state = .warm
            log("too short, discarded")
            return
        }

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

    private func transcribe(_ samples: [Float]) async {
        let started = Date()
        guard let key = SharedStore.groqAPIKey, !key.isEmpty else {
            finish(error: "No Groq API key set")
            return
        }

        let dictionary = PersonalDictionary.mergeFromCloud()
        let speech = GroqTranscription(apiKey: key, biasTerms: dictionary.entries.map(\.canonical))
        let cleaner = Cleaner(provider: GroqCleanup(apiKey: key), dictionary: dictionary)

        do {
            let raw = try await speech.transcribe(samples: samples)
            guard !raw.isEmpty else { finish(error: "Nothing heard"); return }
            let cleaned = await cleaner.process(raw, profile: .messaging)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("mode: \(DictationMode.current.displayName)")
            finish(text: cleaned.text, ms: ms)
        } catch {
            finish(error: error.localizedDescription)
        }
    }

    private func finish(text: String, ms: Int) {
        lastTranscript = text
        SharedStore.publish(transcript: text, latencyMS: ms)
        DarwinBridge.shared.post(.resultReady)
        state = .warm
        log("\(ms) ms: \(text.prefix(40))")
    }

    private func finish(error: String) {
        SharedStore.publish(error: error)
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

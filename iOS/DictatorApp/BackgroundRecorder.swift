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

    /// One engine, started once in the foreground and never stopped.
    ///
    /// This is the hard-won shape of the thing. Starting a microphone input from
    /// the BACKGROUND is refused by iOS: PerformCommand(ioNode, kAUStartIO)
    /// returns 2003329396, kAudioUnitErr_CannotDoInCurrentContext ('what'),
    /// whether it is a second engine or the only one. Verified on device
    /// 2026-09-14: with the keyboard in another app, every background attempt to
    /// open the mic failed with exactly that code.
    ///
    /// So the input engine is started here in the foreground, during warm-up,
    /// and kept running for the whole session. A capture starts no IO; it only
    /// flips a flag that decides whether the already-running tap keeps its
    /// samples. The honest cost is that the microphone, and the orange
    /// indicator, are on the whole time Dictator is on. Willow and Wispr carry
    /// the same cost for the same reason. Do not try to close the mic between
    /// dictations: reopening it in the background is exactly what fails.
    private let engine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var capturing = false
    private var latestLevel: Float = 0
    private var running = false
    private let lock = NSLock()

    // MARK: - Warm-up (foreground only)

    /// Claims the audio session and starts the input engine. MUST run while the
    /// app is foregrounded, because that is the only place iOS lets input IO
    /// start. Idempotent: a second call while already running is a no-op.
    func startWarm() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord, claimed in the foreground. No .mixWithOthers: that
            // marks our audio secondary, which iOS suspends in the background.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw StartError.session(error)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw StartError.noInputRoute }

        lock.lock()
        converter = AVAudioConverter(from: format, to: targetFormat)
        lock.unlock()

        // Defensive: a prior half-started attempt may have left a tap behind.
        input.removeTap(onBus: 0)

        // Formed in a nonisolated method so no actor isolation is inherited. A
        // tap block that inherits @MainActor gets a dispatch_assert_queue
        // compiled into it, and CoreAudio calls taps from its realtime thread,
        // which would trap the process on the first buffer.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.handle(buf)
        }

        // A silent player runs alongside the input for the whole session. The
        // running microphone alone does NOT keep the backgrounded app resident:
        // after the first dictation iOS suspended it, the engine stopped, and
        // the next capture came back empty. Continuous playback is what iOS
        // treats as active background audio, so the app, and the running mic,
        // stay alive between dictations.
        let rate = session.sampleRate
        guard let outFormat = AVAudioFormat(
            standardFormatWithSampleRate: rate > 0 ? rate : 48_000,
            channels: 2
        ) else { throw StartError.badFormat }
        if silence.engine == nil { engine.attach(silence) }
        engine.connect(silence, to: engine.mainMixerNode, format: outFormat)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw StartError.engine(error)
        }

        let frames = AVAudioFrameCount(outFormat.sampleRate * 0.5)
        guard frames > 0, let quiet = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) else {
            throw StartError.badFormat
        }
        // AVAudioPCMBuffer allocates cleared memory, so frameLength alone makes
        // half a second of silence to loop.
        quiet.frameLength = frames
        silence.scheduleBuffer(quiet, at: nil, options: .loops)
        silence.play()

        running = true
    }

    /// The engine, and therefore the microphone, is live.
    var isRunning: Bool { running && engine.isRunning }

    /// Full teardown, user-initiated only. Closes the microphone and hands the
    /// audio route back.
    func stopEverything() {
        if running {
            if silence.isPlaying { silence.stop() }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
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

    /// The last captured audio, kept after a failed transcription so the words
    /// are not lost to a network blip. The keyboard offers "Tap to try again",
    /// which posts .retry and lands in retryLastTranscription.
    private var lastSamples: [Float] = []

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
                log(host.isRunning
                    ? "warm: mic live and listening"
                    : "warm: engine NOT running, app will be suspended")
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
        log("capturing")
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

        // The mic keeps running (it has to, to stay startable); we only stop
        // collecting. The audio is already in memory by this point.
        state = .transcribing
        level = 0
        let seconds = Double(samples.count) / 16_000
        log(String(format: "captured %.1fs", seconds))

        guard samples.count > 3_200 else {   // under 0.2 s
            // Tell the keyboard, otherwise it waits 25s at "Transcribing" for a
            // result that never comes.
            log("too short, discarded")
            finish(error: "Didn't catch that", retryable: false)
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

    /// Re-runs transcription on the audio kept from a failed attempt. Wired to
    /// the keyboard's "Tap to try again" through the .retry Darwin signal.
    public func retryLastTranscription() {
        guard state == .warm, !lastSamples.isEmpty else { return }
        let samples = lastSamples
        state = .transcribing
        log("retrying \(String(format: "%.1fs", Double(samples.count) / 16_000))")
        Task { await transcribe(samples) }
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
            // The host app is unknowable to a keyboard on iOS 26.4+, so we
            // cannot pick a per-app tone profile. Use neutral and let the mode
            // the user chose on the keyboard be the sole register control.
            let cleaned = await cleaner.process(raw, profile: ToneProfile.neutral)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("mode: \(DictationMode.current.displayName)")
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
        lastTranscript = text
        SharedStore.publish(transcript: text, latencyMS: ms)
        DarwinBridge.shared.post(.resultReady)
        state = .warm
        log("\(ms) ms: \(text.prefix(40))")
    }

    private func finish(error: String, retryable: Bool) {
        if !retryable { lastSamples = [] }
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

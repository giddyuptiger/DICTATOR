import Foundation

/// Where captured samples land, straight off the audio thread.
///
/// Audio arrives on CoreAudio's realtime thread about fifty times a second. The
/// tap used to hop every single buffer onto the actor with
/// `Task { await append(samples) }` — one Task allocation and one actor
/// scheduling round trip per 20 ms of speech, purely to append to an array. The
/// iOS recorder hit the same wall and stopped doing it; this is the same fix for
/// the Mac path. Samples go into a lock-guarded box with no allocation and no
/// scheduling, and the actor reads it once, when the utterance ends.
///
/// `@unchecked Sendable` is accurate: every access to both stored properties is
/// inside `lock`, and the level handler is invoked outside it so a slow UI
/// handler can never block the audio thread.
private final class SampleBox: @unchecked Sendable {
    private var samples: [Float] = []
    private var level: (@Sendable (Float) -> Void)?
    private let lock = NSLock()

    func setLevel(_ handler: (@Sendable (Float) -> Void)?) {
        lock.lock(); level = handler; lock.unlock()
    }

    func append(_ new: [Float]) {
        lock.lock()
        samples.append(contentsOf: new)
        let handler = level
        lock.unlock()
        handler?(AudioUtil.rms(new))
    }

    /// Everything captured so far, and reset. Copy-on-write means the returned
    /// array is unaffected by the reset that follows it.
    func drain() -> [Float] {
        lock.lock()
        defer { samples.removeAll(keepingCapacity: true); lock.unlock() }
        return samples
    }

    func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
    }
}

/// One utterance, start to finish, shared by the Mac app and the iOS keyboard.
///
/// Everything platform-specific is injected: where audio comes from is the same
/// on both, where text goes is not, and which speech provider runs depends on how
/// much memory the process is allowed.
public actor DictationSession {

    public enum State: Sendable, Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    public struct Output: Sendable {
        public let text: String
        public let raw: String
        public let transcribeTime: TimeInterval
        public let cleanupTime: TimeInterval
        public var totalTime: TimeInterval { transcribeTime + cleanupTime }
    }

    private let recorder: AudioRecorder
    private let speech: SpeechProvider
    private var cleaner: Cleaner
    private var dictionary: PersonalDictionary

    private let box = SampleBox()
    private var state: State = .idle

    private var onStateChange: (@Sendable (State) -> Void)?

    /// Actor state cannot be assigned from outside, so these are the way in.
    ///
    /// NOTE: the level handler is called on the AUDIO thread, not the main
    /// thread, and roughly fifty times a second. Hop to the main queue yourself
    /// before touching any UI, and keep the handler cheap.
    public func setOnLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        box.setLevel(handler)
    }

    public func setOnStateChange(_ handler: @escaping @Sendable (State) -> Void) {
        onStateChange = handler
    }

    public init(
        recorder: AudioRecorder = AudioRecorder(),
        speech: SpeechProvider,
        cleanupProvider: CleanupProvider?,
        dictionary: PersonalDictionary
    ) {
        self.recorder = recorder
        self.speech = speech
        self.dictionary = dictionary
        self.cleaner = Cleaner(provider: cleanupProvider, dictionary: dictionary)
    }

    public func prepare() async throws {
        try await speech.prepare()
    }

    public var currentState: State { state }

    // MARK: - Recording

    public func start() async throws {
        // Self-heal from any wedged state. A prior transcription error used to
        // leave state at .failed, and .transcribing can linger if a call hung —
        // and because start() only ran from .idle, one hiccup wedged the whole
        // session forever (every later dictation silently no-oped while the UI
        // still said "Listening"). Only a genuine in-progress capture should block
        // a new start; anything else resets so the next dictation always works.
        if state == .listening { return }
        recorder.stop()                       // defensive; no-op if not running
        box.reset()

        let box = self.box
        try recorder.start { samples in
            box.append(samples)
        }

        setState(.listening)
    }

    /// Stop, transcribe, clean, return. Returns nil for a mis-tap.
    public func finish(profile: ToneProfile) async -> Output? {
        guard state == .listening else { return nil }
        recorder.stop()

        let samples = box.drain()

        // Under a quarter second is a brushed key, not speech.
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.25) else {
            setState(.idle)
            return nil
        }

        setState(.transcribing)

        let t0 = Date()
        let raw: String
        do {
            raw = try await speech.transcribe(samples: samples)
        } catch {
            // Return to .idle, NOT .failed: a failed state used to wedge the
            // session so no further dictation could start. The error surfaces to
            // the caller as a nil result; the session stays usable.
            setState(.idle)
            return nil
        }
        let transcribeTime = Date().timeIntervalSince(t0)

        guard !raw.isEmpty else {
            setState(.idle)
            return nil
        }

        let t1 = Date()
        let cleaned = await cleaner.process(raw, profile: profile)
        let cleanupTime = Date().timeIntervalSince(t1)

        setState(.idle)

        return Output(
            text: cleaned.text,
            raw: raw,
            transcribeTime: transcribeTime,
            cleanupTime: cleanupTime
        )
    }

    /// Throw away the current recording without transcribing. Wire this to Escape.
    public func cancel() {
        guard state == .listening else { return }
        recorder.stop()
        box.reset()
        setState(.idle)
    }

    // MARK: - Dictionary

    /// Record a correction the user made, so the same mishearing self-heals.
    public func learn(misheard: String, corrected: String) {
        dictionary.learn(misheard: misheard, corrected: corrected)
        dictionary.save()
        cleaner = Cleaner(provider: cleaner.provider, dictionary: dictionary)
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }
}

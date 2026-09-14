import Foundation

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

    private var buffer: [Float] = []
    private var state: State = .idle

    /// Live microphone level, 0...1, for a waveform or pulsing button.
    private var onLevel: (@Sendable (Float) -> Void)?
    private var onStateChange: (@Sendable (State) -> Void)?

    /// Actor state cannot be assigned from outside, so these are the way in.
    public func setOnLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        onLevel = handler
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
        guard state == .idle else { return }
        buffer.removeAll(keepingCapacity: true)

        try recorder.start { [weak self] samples in
            guard let self else { return }
            Task { await self.append(samples) }
        }

        setState(.listening)
    }

    private func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        onLevel?(AudioUtil.rms(samples))
    }

    /// Stop, transcribe, clean, return. Returns nil for a mis-tap.
    public func finish(profile: ToneProfile) async -> Output? {
        guard state == .listening else { return nil }
        recorder.stop()

        let samples = buffer
        buffer.removeAll(keepingCapacity: true)

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
            setState(.failed(error.localizedDescription))
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
        buffer.removeAll(keepingCapacity: true)
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

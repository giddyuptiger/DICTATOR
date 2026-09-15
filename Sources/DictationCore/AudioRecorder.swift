@preconcurrency import AVFoundation
import Foundation

/// Captures microphone audio and emits 16 kHz mono Float32 buffers, which is what
/// every Parakeet and Whisper variant expects. Works on macOS and iOS.
///
/// iOS note: inside a keyboard extension this only succeeds when the extension sets
/// `RequestsOpenAccess = true` AND the view controller overrides `hasDictationKey`
/// to return true. Without both, `setActive` fails with OSStatus 561145187.

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

public final class AudioRecorder: @unchecked Sendable {

    public enum RecorderError: Error, LocalizedError {
        case micPermissionDenied
        case sessionActivationFailed(underlying: Error)
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .micPermissionDenied:
                return "Microphone permission was not granted."
            case .sessionActivationFailed(let underlying):
                let ns = underlying as NSError
                if ns.code == 561145187 {
                    return """
                    Audio session refused (561145187). In a keyboard extension this \
                    almost always means RequestsOpenAccess is missing from Info.plist, \
                    or hasDictationKey is not overridden to return true.
                    """
                }
                return "Audio session activation failed: \(underlying.localizedDescription)"
            case .converterUnavailable:
                return "Could not build a converter to 16 kHz mono."
            }
        }
    }

    /// Target format for the ASR models.
    public static let targetSampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var isRunning = false
    private let lock = NSLock()

    /// Called on an arbitrary thread with each converted chunk.
    private var onBuffer: (@Sendable ([Float]) -> Void)?

    public init() {
        // Non-interleaved mono Float32 at 16 kHz.
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Permission

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #endif
    }

    // MARK: - Lifecycle

    /// Starts capture. `onBuffer` receives 16 kHz mono float samples as they arrive,
    /// suitable for feeding a streaming recognizer.
    public func start(onBuffer: @escaping @Sendable ([Float]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        self.onBuffer = onBuffer

        // Fresh engine every session. Reusing one AVAudioEngine across many
        // start/stop cycles wedges after a device or sample-rate change: it stops
        // delivering buffers, so the app looks like it is "listening" but captures
        // nothing (and only relaunching fixed it). A new instance each time avoids
        // that entire failure mode; the old one was already stopped in stop().
        engine.stop()
        engine = AVAudioEngine()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // .record rather than .playAndRecord keeps latency down and avoids
            // ducking whatever the user is listening to more than necessary.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setPreferredSampleRate(Self.targetSampleRate)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw RecorderError.sessionActivationFailed(underlying: error)
        }
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        // 20 ms of input audio per tap keeps the streaming recognizer responsive.
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.02)

        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let samples = self.convert(buffer, using: converter) {
                self.onBuffer?(samples)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        onBuffer = nil
        isRunning = false

        #if os(iOS)
        // Hand the audio route back promptly so music resumes.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Conversion

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let gate = OneShot()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard gate.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

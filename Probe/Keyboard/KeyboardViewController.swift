import UIKit
import AVFoundation

// ============================================================================
// PROBE v2 — configuration matrix.
//
// v1 established the important thing: a keyboard extension on iOS 26.6.2 CAN
// get microphone permission and CAN activate an AVAudioSession. We saw
// "session ACTIVE" and a real 48 kHz input format. The documented blocker
// (OSStatus 561145187) did not occur.
//
// What failed was AVAudioEngine.start() with 2003329396, which is the FourCC
// 'what' — CoreAudio's generic "not in this configuration" refusal.
//
// So this version stops guessing and sweeps the plausible configurations,
// reporting which one actually starts. It tries, in order:
//
//   A  .record / .measurement        + tap at input format   (v1, known fail)
//   B  .record / .default            + tap at nil format
//   C  .playAndRecord / .default     + tap nil, speaker+BT
//   D  .playAndRecord / .measurement + tap nil, mixWithOthers
//   E  .playAndRecord / .default     + input wired to mainMixer at volume 0
//   F  AVAudioRecorder to a file     (different API entirely, no engine)
//
// F is the fallback that almost always works when the engine will not start.
// If F is the only green, the real app records with AVAudioRecorder and reads
// the file back, which is fine for our push-to-talk design.
// ============================================================================

final class KeyboardViewController: UIInputViewController {

    override var hasDictationKey: Bool {
        get { true }
        set { }
    }

    private let engine = AVAudioEngine()
    private var recorder: AVAudioRecorder?
    private let log = UITextView()
    private let runButton = UIButton(type: .system)
    private var results: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        write("hasFullAccess: \(hasFullAccess)")
        write("iOS: \(UIDevice.current.systemVersion)")
        write("Tap RUN MATRIX. Takes ~10 s.")
        write("")
    }

    @objc private func runMatrix() {
        runButton.isEnabled = false
        results.removeAll()
        log.text = ""
        write("running…\n")

        Task { @MainActor in
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = await AVAudioApplication.requestRecordPermission()
            } else {
                granted = await withCheckedContinuation { c in
                    AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
                }
            }
            write("permission: \(granted)")
            guard granted else { write("STOP: denied"); runButton.isEnabled = true; return }

            await self.tryEngine("A", .record, .measurement, [], useNilFormat: false, wireMixer: false)
            await self.tryEngine("B", .record, .default, [], useNilFormat: true, wireMixer: false)
            await self.tryEngine("C", .playAndRecord, .default, [.defaultToSpeaker, .allowBluetooth], useNilFormat: true, wireMixer: false)
            await self.tryEngine("D", .playAndRecord, .measurement, [.mixWithOthers], useNilFormat: true, wireMixer: false)
            await self.tryEngine("E", .playAndRecord, .default, [.defaultToSpeaker], useNilFormat: true, wireMixer: true)
            await self.tryRecorder("F")

            write("")
            write("======== SUMMARY ========")
            for r in self.results { write(r) }
            self.runButton.isEnabled = true
        }
    }

    // MARK: - Engine attempts

    private func tryEngine(_ tag: String,
                           _ cat: AVAudioSession.Category,
                           _ mode: AVAudioSession.Mode,
                           _ opts: AVAudioSession.CategoryOptions,
                           useNilFormat: Bool,
                           wireMixer: Bool) async {
        let session = AVAudioSession.sharedInstance()
        engine.stop()
        engine.reset()
        engine.inputNode.removeTap(onBus: 0)
        try? session.setActive(false)

        do {
            try session.setCategory(cat, mode: mode, options: opts)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            record(tag, false, "session: \((error as NSError).code)")
            return
        }

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            record(tag, false, "route dead (0 Hz)")
            return
        }

        if wireMixer {
            // Some configurations refuse to start with no rendering graph at all.
            let mixer = engine.mainMixerNode
            mixer.outputVolume = 0
            engine.connect(input, to: mixer, format: fmt)
        }

        var got = false
        input.installTap(onBus: 0, bufferSize: 1024, format: useNilFormat ? nil : fmt) { buf, _ in
            if buf.frameLength > 0 { got = true }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            record(tag, false, "start: \((error as NSError).code)")
            input.removeTap(onBus: 0)
            return
        }

        try? await Task.sleep(nanoseconds: 900_000_000)
        engine.stop()
        input.removeTap(onBus: 0)
        record(tag, true, "started, buffers: \(got ? "YES" : "none")  \(Int(fmt.sampleRate)) Hz")
    }

    // MARK: - AVAudioRecorder fallback

    private func tryRecorder(_ tag: String) async {
        let session = AVAudioSession.sharedInstance()
        engine.stop()
        try? session.setActive(false)

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            record(tag, false, "session: \((error as NSError).code)")
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { record(tag, false, "record() returned false"); return }
            recorder = r
            try? await Task.sleep(nanoseconds: 900_000_000)
            r.updateMeters()
            let power = r.averagePower(forChannel: 0)
            r.stop()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            record(tag, true, "recorded \(size) bytes, level \(String(format: "%.1f", power)) dB")
        } catch {
            record(tag, false, "\((error as NSError).code)")
        }
    }

    // MARK: - Reporting

    private func record(_ tag: String, _ ok: Bool, _ detail: String) {
        let line = "\(ok ? "PASS" : "fail")  \(tag)  \(detail)"
        results.append(line)
        write(line)
    }

    private func write(_ s: String) {
        log.text += s + "\n"
        log.scrollRangeToVisible(NSRange(location: max(0, log.text.count - 1), length: 1))
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground
        runButton.setTitle("RUN MATRIX", for: .normal)
        runButton.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        runButton.backgroundColor = .systemBlue
        runButton.tintColor = .white
        runButton.layer.cornerRadius = 10
        runButton.addTarget(self, action: #selector(runMatrix), for: .touchUpInside)

        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.backgroundColor = .clear

        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        [runButton, log, globe].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 330),
            runButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            runButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            runButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            runButton.heightAnchor.constraint(equalToConstant: 44),
            log.topAnchor.constraint(equalTo: runButton.bottomAnchor, constant: 8),
            log.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            log.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            log.bottomAnchor.constraint(equalTo: globe.topAnchor, constant: -4),
            globe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            globe.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
    }
}

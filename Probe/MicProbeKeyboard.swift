import UIKit
import AVFoundation

// ============================================================================
// DAY ONE PROBE. Run this before writing anything else.
//
// It answers one question: can a keyboard extension on YOUR phone, on YOUR iOS
// version, open the microphone? Everything else in this project depends on the
// answer, and nobody on the internet agrees about it.
//
// HOW TO RUN (about 20 minutes):
//   1. New Xcode project, iOS App, name it MicProbe.
//   2. File › New › Target › Custom Keyboard Extension, name it ProbeKeyboard.
//   3. Replace the generated KeyboardViewController.swift with this file.
//   4. In ProbeKeyboard's Info.plist, inside NSExtension › NSExtensionAttributes,
//      add:  RequestsOpenAccess  (Boolean)  YES
//   5. In the CONTAINER APP's Info.plist add:
//      NSMicrophoneUsageDescription = "Dictation"
//   6. Run on a real device. Simulator lies about audio.
//   7. Settings › General › Keyboard › Keyboards › Add New Keyboard › MicProbe
//      then tap it and turn ON Allow Full Access.
//   8. Open Notes, switch to the MicProbe keyboard, press the button.
//
// READING THE RESULT:
//   GREEN  "engine running"     → the mic works in-process. Build the real thing.
//   RED    "561145187"          → the documented unlock is not enough on your OS.
//                                 Fall back to the App Group handoff (the same
//                                 approach that makes Wispr bounce you to its app).
//   RED    "no full access"     → step 7 was not completed.
//
// The test deliberately toggles hasDictationKey so you can see whether it is
// actually load-bearing on your OS version, rather than taking a forum's word.
// ============================================================================

final class KeyboardViewController: UIInputViewController {

    /// Flip this to false and re-run to see whether it actually matters.
    private static let claimDictationKey = true

    override var hasDictationKey: Bool {
        get { Self.claimDictationKey }
        set { }
    }

    private let engine = AVAudioEngine()
    private let log = UITextView()
    private let button = UIButton(type: .system)
    private var running = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()

        write("hasFullAccess: \(hasFullAccess)")
        write("hasDictationKey: \(hasDictationKey)")
        write("iOS: \(UIDevice.current.systemVersion)")
        write("---")

        if !hasFullAccess {
            write("STOP: no full access. Settings > General > Keyboard > Keyboards > MicProbe > Allow Full Access")
        }
    }

    @objc private func toggle() {
        running ? stop() : start()
    }

    private func start() {
        write("requesting permission…")

        let proceed: (Bool) -> Void = { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                self.write("permission granted: \(granted)")
                guard granted else {
                    self.write("FAIL: permission denied. Check Settings > Privacy > Microphone.")
                    return
                }
                self.activate()
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: proceed)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(proceed)
        }
    }

    private func activate() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            write("category set")
        } catch {
            report("setCategory", error)
            return
        }

        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            write("session ACTIVE")
        } catch {
            report("setActive", error)
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        write("input format: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")

        guard format.sampleRate > 0 else {
            write("FAIL: sample rate 0, the route is dead even though the session activated.")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            DispatchQueue.main.async {
                self?.button.setTitle(String(format: "LEVEL %.3f  (tap to stop)", rms), for: .normal)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            running = true
            write("SUCCESS: engine running. Speak and watch the level move.")
            log.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
        } catch {
            report("engine.start", error)
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        running = false
        button.setTitle("Start microphone", for: .normal)
        write("stopped")
    }

    private func report(_ stage: String, _ error: Error) {
        let ns = error as NSError
        write("FAIL at \(stage): code \(ns.code)")
        write(ns.localizedDescription)
        if ns.code == 561145187 {
            write("")
            write("561145187 is the keyboard-extension audio block.")
            write("If RequestsOpenAccess is YES and hasDictationKey is true and you")
            write("still see this, in-process recording is not available here.")
            write("Use the App Group handoff instead.")
        }
        log.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
    }

    private func write(_ line: String) {
        log.text += line + "\n"
        log.scrollRangeToVisible(NSRange(location: log.text.count - 1, length: 1))
    }

    private func buildUI() {
        view.backgroundColor = .secondarySystemBackground

        button.setTitle("Start microphone", for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        button.backgroundColor = .systemBlue
        button.tintColor = .white
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.backgroundColor = .clear

        let globe = UIButton(type: .system)
        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        [button, log, globe].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 300),

            button.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            button.heightAnchor.constraint(equalToConstant: 46),

            log.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            log.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            log.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            log.bottomAnchor.constraint(equalTo: globe.topAnchor, constant: -4),

            globe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            globe.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
    }
}

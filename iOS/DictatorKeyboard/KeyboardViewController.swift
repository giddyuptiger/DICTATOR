import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// The Dictator keyboard.
///
/// This extension NEVER touches the microphone. It cannot: Apple has forbidden
/// audio capture in app extensions since iOS 8 (QA1872), the block is enforced in
/// mediaserverd on process class, and it applies to every audio API. We verified
/// all of that on device before writing a line of this file.
///
/// What it does instead:
///
///   tap mic  ──Darwin(.startRecording)──▶  container app (warm, backgrounded)
///                                          records with its live engine
///   tap stop ──Darwin(.stopRecording)──▶   app transcribes
///            ◀──Darwin(.resultReady)────   writes transcript to App Group
///   insertText()
///
/// No app switch, because the app is already alive holding audio IO. The only
/// time we bounce is a cold start, when nothing answers the ping.
final class KeyboardViewController: UIInputViewController {

    private enum Mode {
        case needsFullAccess
        case needsKey
        case needsSession      // app not running: cold start required
        case ready
        case recording
        case working
    }

    private var mode: Mode = .ready {
        didSet { render() }
    }

    private var lastSeenToken: String?
    private var coldStartTimer: Timer?
    private var modeWatch: Timer?
    private var resultWatch: Timer?

    private lazy var micButton   = makeMic()
    private lazy var statusLabel = makeStatus()
    private lazy var globeButton = makeGlobe()
    private lazy var undoButton  = makeUndo()
    private lazy var modeButton  = makeMode()
    private var lastInserted: String?

    // MARK: - Lifecycle

    override func loadView() {
        view = KeyboardRootView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout()
        wireSignals()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastSeenToken = SharedStore.resultToken
        refreshMode()
        startModeWatch()
    }

    /// Re-checks the App Group once a second. Without this the status line is a
    /// single snapshot taken when the keyboard appeared, which reads as a frozen
    /// counter and is easy to misdiagnose. It also means the button turns blue on
    /// its own the moment a session comes up, with no need to dismiss and return.
    private func startModeWatch() {
        modeWatch?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.mode {
                case .recording, .working:
                    return          // mid-flight, leave it alone
                default:
                    self.refreshMode()
                    self.render()   // refresh the diagnostic text in place
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        modeWatch = t
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if mode == .recording { stopRecording() }
        // Tell the app the keyboard is gone, so an abandoned capture cannot
        // leave the microphone open.
        DarwinBridge.shared.post(.keyboardHidden)
        coldStartTimer?.invalidate()
        modeWatch?.invalidate()
        modeWatch = nil
        cancelResultWatch()
    }

    deinit { DarwinBridge.shared.stopObserving() }

    private func wireSignals() {
        let bridge = DarwinBridge.shared
        // DarwinBridge dispatches every handler onto the main queue before
        // calling it, so this IS main-actor work. assumeIsolated states that
        // fact instead of adding a second hop, which would let the cold-start
        // timer race ahead of a pong that already arrived.
        bridge.observe(.resultReady) { [weak self] in
            MainActor.assumeIsolated { self?.consumeResult() }
        }
        bridge.observe(.failed) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mode = .ready
                self.statusLabel.text = SharedStore.lastError ?? "Failed"
            }
        }
    }

    /// The app is considered alive if it stamped the App Group recently. The
    /// heartbeat runs every two seconds, so six seconds of silence means gone.
    /// Alive means the process is resident and can open the microphone on
    /// demand. It does not mean the microphone is open: it is not, until you tap.
    private var appIsAlive: Bool {
        let s = SharedStore.liveState
        return s != nil && s != "cold" && SharedStore.secondsSinceLive < 6
    }

    private func refreshMode() {
        guard hasFullAccess else { mode = .needsFullAccess; return }
        guard let k = SharedStore.groqAPIKey, !k.isEmpty else { mode = .needsKey; return }
        mode = appIsAlive ? .ready : .needsSession
    }

    // MARK: - Actions

    @objc private func micTapped() {
        switch mode {
        case .needsFullAccess, .needsKey:
            return
        case .needsSession:
            coldStart()
        case .ready:
            startRecording()
        case .recording:
            stopRecording()
        case .working:
            return
        }
    }

    private func startRecording() {
        DarwinBridge.shared.post(.startRecording)
        statusLabel.text = "starting…"

        // Confirmation comes from the App Group, not from a Darwin reply. A
        // backgrounded app is scheduled when the system feels like it, so a
        // short deadline on a round trip produces false negatives and an
        // unnecessary app bounce. Poll for the state the app actually writes.
        waitForCapture(deadline: Date().addingTimeInterval(2.0))
    }

    private func waitForCapture(deadline: Date) {
        coldStartTimer?.invalidate()
        // Note: the Timer handed to this block is not Sendable, so it must not
        // cross into the main-actor closure. Cancel through the stored
        // reference instead.
        coldStartTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Freshness matters: an app killed mid-capture leaves
                // "capturing" behind forever, and without the age check the
                // keyboard would go red instantly and then hang.
                if SharedStore.liveState == "capturing", SharedStore.secondsSinceLive < 6 {
                    self.cancelWait()
                    self.mode = .recording
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else if Date() >= deadline {
                    self.cancelWait()
                    // Nobody picked up. The app really is gone.
                    self.coldStart()
                }
            }
        }
    }

    private func cancelWait() {
        coldStartTimer?.invalidate()
        coldStartTimer = nil
    }

    private func stopRecording() {
        DarwinBridge.shared.post(.stopRecording)
        mode = .working
        waitForResult(deadline: Date().addingTimeInterval(25))
    }

    /// Polls the App Group for a new result token.
    ///
    /// The .resultReady Darwin notification still fires and is still handled,
    /// but it cannot be depended on: a keyboard extension is recycled freely by
    /// the system, and an extension that was torn down and rebuilt between the
    /// stop tap and the transcript has no observer left to receive it. The
    /// shared container survives that; a notification does not.
    private func waitForResult(deadline: Date) {
        resultWatch?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if SharedStore.resultToken != self.lastSeenToken {
                    self.cancelResultWatch()
                    self.consumeResult()
                } else if Date() >= deadline {
                    self.cancelResultWatch()
                    self.statusLabel.text = "No answer from Dictator. Open the app."
                    self.mode = .ready
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        resultWatch = t
    }

    private func cancelResultWatch() {
        resultWatch?.invalidate()
        resultWatch = nil
    }

    /// The one bounce. Only when the app is not running.
    private func coldStart() {
        statusLabel.text = "waking Dictator…"
        guard let url = URL(string: "dictator://dictate") else { return }

        // extensionContext.open() is documented for a handful of extension
        // types and a keyboard is not one of them: it calls back with false and
        // launches nothing. Walking the responder chain for openURL: is the
        // long-standing workaround. It is a grey area for App Store review, and
        // this build is not going to the App Store.
        if openViaResponderChain(url) {
            statusLabel.text = "Dictator is starting. Come back and tap the mic."
        } else {
            statusLabel.text = "Open the Dictator app once to start a session."
        }
        mode = .needsSession
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return true
            }
            responder = r.next
        }
        return false
    }

    private func consumeResult() {
        let token = SharedStore.resultToken
        guard token != lastSeenToken else { return }
        lastSeenToken = token
        cancelResultWatch()

        if let err = SharedStore.lastError {
            statusLabel.text = err
            mode = .ready
            return
        }
        guard let text = SharedStore.transcript, !text.isEmpty else {
            mode = .ready
            return
        }
        insert(text)
        lastInserted = text
        undoButton.isHidden = false
        statusLabel.text = "\(SharedStore.lastLatencyMS) ms"
        mode = .ready
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func insert(_ text: String) {
        let proxy = textDocumentProxy
        if let before = proxy.documentContextBeforeInput,
           let last = before.last, !last.isWhitespace,
           let first = text.first, !first.isPunctuation {
            proxy.insertText(" ")
        }
        proxy.insertText(text)
    }

    @objc private func undoTapped() {
        guard let t = lastInserted else { return }
        for _ in 0..<t.count { textDocumentProxy.deleteBackward() }
        lastInserted = nil
        undoButton.isHidden = true
    }

    // MARK: - Rendering
    private func render() {
        modeButton.setTitle(DictationMode.current.displayName, for: .normal)

        switch mode {
        case .needsFullAccess:
            micButton.isEnabled = false; micButton.alpha = 0.5
            micButton.backgroundColor = .systemGray3
            statusLabel.text = "Allow Full Access in Settings › Keyboards"
        case .needsKey:
            micButton.isEnabled = false; micButton.alpha = 0.5
            micButton.backgroundColor = .systemGray3
            statusLabel.text = "Add a Groq key in the Dictator app"
        case .needsSession:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemOrange
            statusLabel.text = "Tap to wake Dictator"
        case .ready:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemBlue
            if statusLabel.text?.hasSuffix("ms") != true { statusLabel.text = "Tap to talk" }
        case .recording:
            micButton.backgroundColor = .systemRed
            statusLabel.text = "Listening, tap to stop"
        case .working:
            micButton.backgroundColor = .systemGray
            statusLabel.text = "Transcribing…"
        }
    }

    // MARK: - Mode

    @objc private func modeTapped() {
        DictationMode.advance()
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // ========================================================================
    // MARK: - The typing keyboard
    //
    // A keyboard extension starts as an empty view: iOS supplies no keys, no
    // layout, no shift logic, nothing. Every key here is built by hand.
    //
    // It exists because a dictation-only keyboard forces a keyboard switch to
    // fix a single word, which costs more than dictation saves. Wispr puts its
    // mic above a full keyboard for the same reason.
    // ========================================================================

    private enum Plane {
        case letters, numbers, symbols
    }

    private enum Shift {
        case off, once, locked
    }

    private var plane: Plane = .letters { didSet { rebuildKeys() } }
    private var shift: Shift = .once   { didSet { refreshCaps() } }
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var deleteRepeat: Timer?
    private var letterKeys: [UIButton] = []

    private let rowsStack = UIStackView()

    private func rows(for plane: Plane) -> [[String]] {
        switch plane {
        case .letters:
            return [
                ["q","w","e","r","t","y","u","i","o","p"],
                ["a","s","d","f","g","h","j","k","l"],
                ["z","x","c","v","b","n","m"]
            ]
        case .numbers:
            return [
                ["1","2","3","4","5","6","7","8","9","0"],
                ["-","/",":",";","(",")","$","&","@","\""],
                [".",",","?","!","'"]
            ]
        case .symbols:
            return [
                ["[","]","{","}","#","%","^","*","+","="],
                ["_","\\","|","~","<",">","€","£","¥","•"],
                [".",",","?","!","'"]
            ]
        }
    }

    private func rebuildKeys() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterKeys.removeAll()

        let layout = rows(for: plane)

        // Rows 1 and 2: plain equal-width keys. Row 2 is inset by roughly half a
        // key, which is what makes a QWERTY grid look right rather than merely
        // aligned.
        for (i, row) in layout.prefix(2).enumerated() {
            let stack = keyRow(row)
            if i == 1 {
                stack.isLayoutMarginsRelativeArrangement = true
                stack.directionalLayoutMargins = .init(top: 0, leading: 18, bottom: 0, trailing: 18)
            }
            rowsStack.addArrangedSubview(stack)
        }

        // Row 3: shift, letters, delete.
        let third = UIStackView()
        third.axis = .horizontal
        third.spacing = 5
        third.distribution = .fill

        let shiftKey = makeSpecial(
            image: "shift",
            title: plane == .letters ? nil : (plane == .numbers ? "#+=" : "123"),
            action: plane == .letters ? #selector(shiftTapped) : #selector(planeToggleTapped)
        )
        let deleteKey = makeSpecial(image: "delete.left", title: nil, action: #selector(deleteTapped))
        deleteKey.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        deleteKey.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        self.shiftKey = plane == .letters ? shiftKey : nil

        let inner = keyRow(layout[2])
        third.addArrangedSubview(shiftKey)
        third.addArrangedSubview(inner)
        third.addArrangedSubview(deleteKey)
        shiftKey.widthAnchor.constraint(equalTo: third.widthAnchor, multiplier: 0.13).isActive = true
        deleteKey.widthAnchor.constraint(equalTo: shiftKey.widthAnchor).isActive = true
        rowsStack.addArrangedSubview(third)

        // Row 4: plane switch, globe, space, return.
        let fourth = UIStackView()
        fourth.axis = .horizontal
        fourth.spacing = 5
        fourth.distribution = .fill

        let planeKey = makeSpecial(
            image: nil,
            title: plane == .letters ? "123" : "ABC",
            action: #selector(planeSwitchTapped)
        )
        let space = makeSpecial(image: nil, title: "space", action: #selector(spaceTapped))
        space.backgroundColor = .systemBackground
        let ret = makeSpecial(image: nil, title: "return", action: #selector(returnTapped))

        fourth.addArrangedSubview(planeKey)
        fourth.addArrangedSubview(globeButton)
        fourth.addArrangedSubview(space)
        fourth.addArrangedSubview(ret)
        planeKey.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.13).isActive = true
        globeButton.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.12).isActive = true
        ret.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.22).isActive = true
        rowsStack.addArrangedSubview(fourth)

        refreshCaps()
    }

    private var shiftKey: UIButton?

    private func keyRow(_ titles: [String]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.distribution = .fillEqually
        for t in titles {
            let b = makeKey(t)
            letterKeys.append(b)
            stack.addArrangedSubview(b)
        }
        return stack
    }

    private func makeKey(_ title: String) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .systemBackground
        b.layer.cornerRadius = 5
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.28
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowRadius = 0
        b.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func makeSpecial(image: String?, title: String?, action: Selector) -> UIButton {
        let b = UIButton(type: .custom)
        if let image {
            b.setImage(UIImage(systemName: image), for: .normal)
            b.tintColor = .label
        }
        if let title {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
            b.setTitleColor(.label, for: .normal)
        }
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 5
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func refreshCaps() {
        guard plane == .letters else { return }
        let upper = shift != .off
        for key in letterKeys {
            let t = key.title(for: .normal) ?? ""
            key.setTitle(upper ? t.uppercased() : t.lowercased(), for: .normal)
        }
        shiftKey?.setImage(
            UIImage(systemName: shift == .locked ? "capslock.fill" : (shift == .off ? "shift" : "shift.fill")),
            for: .normal
        )
        shiftKey?.backgroundColor = shift == .off ? .systemGray3 : .systemBackground
    }

    // MARK: - Typing actions

    @objc private func keyTapped(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(t)
        UIDevice.current.playInputClick()
        if shift == .once { shift = .off }
    }

    @objc private func keyDown(_ sender: UIButton) { sender.backgroundColor = .systemGray4 }
    @objc private func keyUp(_ sender: UIButton)   { sender.backgroundColor = .systemBackground }

    @objc private func shiftTapped() {
        // A second tap inside 300 ms is caps lock, the same gesture the system
        // keyboard uses, so it needs no teaching.
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.3 {
            shift = .locked
        } else {
            shift = (shift == .off) ? .once : .off
        }
        lastShiftTap = now
        UIDevice.current.playInputClick()
    }

    @objc private func planeSwitchTapped() {
        plane = (plane == .letters) ? .numbers : .letters
        UIDevice.current.playInputClick()
    }

    @objc private func planeToggleTapped() {
        plane = (plane == .numbers) ? .symbols : .numbers
        UIDevice.current.playInputClick()
    }

    @objc private func spaceTapped() {
        // Double space becomes ". ", matching the system keyboard.
        let now = Date()
        if now.timeIntervalSince(lastSpaceTap) < 0.3,
           let before = textDocumentProxy.documentContextBeforeInput,
           before.hasSuffix(" "), !before.hasSuffix("  ") {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            shift = .once
        } else {
            textDocumentProxy.insertText(" ")
        }
        lastSpaceTap = now
        UIDevice.current.playInputClick()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
        UIDevice.current.playInputClick()
    }

    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
        UIDevice.current.playInputClick()
    }

    @objc private func deleteDown(_ sender: UIButton) {
        sender.backgroundColor = .systemGray2
        deleteRepeat?.invalidate()
        // Hold to repeat, after the usual half-second grace period.
        let t = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fast = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.textDocumentProxy.deleteBackward() }
                }
                RunLoop.main.add(fast, forMode: .common)
                self.deleteRepeat = fast
            }
        }
        RunLoop.main.add(t, forMode: .common)
        deleteRepeat = t
    }

    @objc private func deleteUp(_ sender: UIButton) {
        sender.backgroundColor = .systemGray3
        deleteRepeat?.invalidate()
        deleteRepeat = nil
    }

    // MARK: - Layout

    private func layout() {
        view.backgroundColor = UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)

        let bar = UIStackView(arrangedSubviews: [micButton, modeButton, undoButton])
        bar.axis = .horizontal
        bar.spacing = 6
        bar.distribution = .fill

        rowsStack.axis = .vertical
        rowsStack.spacing = 9
        rowsStack.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [bar, rowsStack])
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        micButton.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isUserInteractionEnabled = false
        undoButton.isHidden = true

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 268),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),

            bar.heightAnchor.constraint(equalToConstant: 42),
            modeButton.widthAnchor.constraint(equalToConstant: 86),
            undoButton.widthAnchor.constraint(equalToConstant: 42),

            statusLabel.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: -10)
        ])

        rebuildKeys()
    }

    private func makeMic() -> UIButton {
        // Built entirely through UIButton.Configuration. Once a configuration is
        // assigned it owns the image and title, so a setImage call made
        // alongside it is silently discarded. contentEdgeInsets is the
        // pre-iOS-15 spelling of the same idea and is ignored here.
        var conf = UIButton.Configuration.plain()
        conf.image = UIImage(systemName: "mic.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        conf.baseForegroundColor = .white
        conf.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 0)

        let b = UIButton(configuration: conf)
        b.contentHorizontalAlignment = .left
        b.backgroundColor = .systemBlue
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        return b
    }

    private func makeStatus() -> UILabel {
        let l = UILabel()
        l.textAlignment = .left
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = .white
        l.numberOfLines = 1
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        l.text = "Tap to talk"
        return l
    }

    private func makeMode() -> UIButton {
        let b = UIButton(type: .custom)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        return b
    }

    private func makeGlobe() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 5
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        return b
    }

    private func makeUndo() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        return b
    }
}

/// Key clicks only sound if the input view declares it wants them.
final class KeyboardRootView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

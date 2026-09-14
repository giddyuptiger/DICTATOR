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
        case starting          // asked the app to record, waiting for it to confirm
        case recording
        case working
        case retryError        // a retryable failure; tap tries again
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
    private var retryMessage: String?

    // MARK: - Theme

    /// The board and keys are coloured from the host's keyboard appearance so
    /// Dictator matches the system keyboard beside it. The old build hard-coded a
    /// light board and used .systemBackground for keys, which rendered black keys
    /// on a light board in dark mode.
    private struct Palette {
        let board: UIColor
        let key: UIColor
        let keyPressed: UIColor
        let special: UIColor
        let specialPressed: UIColor
        let keyText: UIColor
        let specialText: UIColor
    }

    private var isDarkKeyboard: Bool {
        switch textDocumentProxy.keyboardAppearance {
        case .dark:  return true
        case .light: return false
        default:     return traitCollection.userInterfaceStyle == .dark
        }
    }

    private var palette: Palette {
        if isDarkKeyboard {
            return Palette(
                board:          UIColor(white: 0.125, alpha: 1),   // #202020
                key:            UIColor(white: 0.42,  alpha: 1),   // #6B6B6B
                keyPressed:     UIColor(white: 0.55,  alpha: 1),
                special:        UIColor(white: 0.275, alpha: 1),   // #464646
                specialPressed: UIColor(white: 0.38,  alpha: 1),
                keyText:        .white,
                specialText:    .white
            )
        } else {
            return Palette(
                board:          UIColor(red: 0.820, green: 0.827, blue: 0.851, alpha: 1), // #D1D3D9
                key:            .white,
                keyPressed:     UIColor(white: 0.87, alpha: 1),
                special:        UIColor(red: 0.678, green: 0.702, blue: 0.737, alpha: 1), // #ADB3BC
                specialPressed: UIColor(red: 0.60,  green: 0.63,  blue: 0.67,  alpha: 1),
                keyText:        .black,
                specialText:    .black
            )
        }
    }

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
        // Reaching the App Group at all proves Full Access is on; record it so
        // the container app's setup checklist can tick that row.
        SharedStore.markKeyboardFullAccess()
        lastSeenToken = SharedStore.resultToken
        applyTheme()
        updateHeight()
        refreshMode()
        startModeWatch()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyTheme()
        updateHeight()
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
                case .recording, .working, .starting, .retryError:
                    return          // mid-flight or showing an error, leave it alone
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
        dismissModeMenu()
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
            MainActor.assumeIsolated { self?.consumeResult() }
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
            // Both are fixed in the app. Try to open it so the user is not stuck.
            coldStart()
        case .needsSession:
            coldStart()
        case .ready:
            startRecording()
        case .recording:
            stopRecording()
        case .retryError:
            retry()
        case .starting, .working:
            return
        }
    }

    private func startRecording() {
        mode = .starting
        DarwinBridge.shared.post(.startRecording)

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
                    // Nobody picked up. Say so rather than quietly reverting to
                    // "Tap to talk", which reads as a button that does nothing.
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

    /// Ask the app to transcribe again on the audio it kept from a failure.
    private func retry() {
        retryMessage = nil
        DarwinBridge.shared.post(.retry)
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

    /// The one bounce. Only when the app is not running (or needs setup).
    private func coldStart() {
        mode = .needsSession
        statusLabel.text = "Opening Dictator. Swipe back and tap again."
        guard let url = URL(string: "dictator://dictate") else { return }

        // extensionContext.open is the only sanctioned way for an extension to
        // open a URL. On current iOS a keyboard gets `false` back and nothing
        // launches, so the honest fallback is to ask for a manual open. The
        // responder-chain openURL: walk that used to live here did launch the
        // app, but it is private-API-adjacent and was removed ahead of App
        // Store submission (2026-09-14).
        extensionContext?.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                self.statusLabel.text = opened
                    ? "Opening Dictator. Swipe back and tap again."
                    : "Open the Dictator app once to start."
            }
        }
    }

    private func consumeResult() {
        let token = SharedStore.resultToken
        guard token != lastSeenToken else { return }
        lastSeenToken = token
        cancelResultWatch()

        if let err = SharedStore.lastError {
            if SharedStore.lastErrorRetryable {
                retryMessage = err
                mode = .retryError
            } else {
                retryMessage = nil
                mode = .ready
                statusLabel.text = err
            }
            return
        }
        guard let text = SharedStore.transcript, !text.isEmpty else {
            mode = .ready
            return
        }
        insert(text)
        lastInserted = text
        undoButton.isHidden = false
        mode = .ready
        statusLabel.text = "Tap to talk"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func insert(_ text: String) {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput

        // Leading space when the previous character is not whitespace and the new
        // text does not open with punctuation.
        if let before, let last = before.last, !last.isWhitespace,
           let first = text.first, !first.isPunctuation {
            proxy.insertText(" ")
        }

        // Capitalise the first letter at a sentence start, unless the register is
        // Super casual, which is deliberately lowercase.
        var out = text
        if DictationMode.current != .superCasual, atSentenceStart(before) {
            out = capitalizingFirst(out)
        }
        proxy.insertText(out)
    }

    private func atSentenceStart(_ before: String?) -> Bool {
        guard let before else { return true }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        return ".!?\n".contains(last)
    }

    private func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
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
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemGray
            statusLabel.text = "Turn on Full Access for Dictator"
        case .needsKey:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemGray
            statusLabel.text = "Add your Groq key in Dictator"
        case .needsSession:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemBlue
            statusLabel.text = "Open Dictator once"
        case .ready:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemBlue
            statusLabel.text = "Tap to talk"
        case .starting:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemIndigo
            statusLabel.text = "Starting"
        case .recording:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemRed
            statusLabel.text = "Listening. Tap to stop."
        case .working:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemGray
            statusLabel.text = "Transcribing"
        case .retryError:
            micButton.isEnabled = true; micButton.alpha = 1
            micButton.backgroundColor = .systemRed
            statusLabel.text = retryMessage ?? "Tap to try again"
        }
    }

    // MARK: - Mode

    @objc private func modeTapped() {
        DictationMode.advance()
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func modeLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        showModeMenu()
    }

    private var modeMenu: UIView?

    /// A small four-row menu, for people who would rather pick a mode than cycle
    /// to it. Presented as an overlay inside the keyboard's own bounds, because a
    /// keyboard extension cannot reliably present a view controller and anything
    /// drawn above the top edge is clipped.
    private func showModeMenu() {
        dismissModeMenu()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let dimmer = UIButton(type: .custom)
        dimmer.frame = view.bounds
        dimmer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmer.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        dimmer.addTarget(self, action: #selector(dismissModeMenu), for: .touchUpInside)

        let container = UIView()
        container.backgroundColor = palette.special
        container.layer.cornerRadius = 8
        container.layer.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        for m in DictationMode.allCases {
            let isCurrent = (m == DictationMode.current)
            var conf = UIButton.Configuration.plain()
            conf.title = m.displayName
            conf.baseForegroundColor = palette.keyText
            conf.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            var bg = UIBackgroundConfiguration.clear()
            bg.backgroundColor = palette.key
            conf.background = bg
            conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
                var a = attr
                a.font = .systemFont(ofSize: 15, weight: isCurrent ? .semibold : .regular)
                return a
            }
            let b = UIButton(configuration: conf)
            b.contentHorizontalAlignment = .leading
            b.tag = DictationMode.allCases.firstIndex(of: m) ?? 0
            b.addTarget(self, action: #selector(modeMenuPicked(_:)), for: .touchUpInside)
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            stack.addArrangedSubview(b)
        }

        container.addSubview(stack)
        dimmer.addSubview(container)
        view.addSubview(dimmer)
        modeMenu = dimmer

        let mf = modeButton.convert(modeButton.bounds, to: view)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            container.widthAnchor.constraint(equalToConstant: 170),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: max(mf.minX, 6)),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: mf.maxY + 4)
        ])
    }

    @objc private func modeMenuPicked(_ sender: UIButton) {
        let all = DictationMode.allCases
        if all.indices.contains(sender.tag) {
            DictationMode.current = all[sender.tag]
        }
        dismissModeMenu()
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func dismissModeMenu() {
        modeMenu?.removeFromSuperview()
        modeMenu = nil
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
        third.spacing = 6
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
        fourth.spacing = 6
        fourth.distribution = .fill

        let planeKey = makeSpecial(
            image: nil,
            title: plane == .letters ? "123" : "ABC",
            action: #selector(planeSwitchTapped)
        )
        let space = makeSpecial(image: nil, title: "space", action: #selector(spaceTapped))
        space.backgroundColor = palette.key
        space.setTitleColor(palette.keyText, for: .normal)
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
        stack.spacing = 6
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
        b.setTitleColor(palette.keyText, for: .normal)
        b.backgroundColor = palette.key
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
            b.tintColor = palette.specialText
        }
        if let title {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
            b.setTitleColor(palette.specialText, for: .normal)
        }
        b.backgroundColor = palette.special
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
        shiftKey?.backgroundColor = shift == .off ? palette.special : palette.key
        shiftKey?.tintColor = shift == .off ? palette.specialText : palette.keyText
    }

    // MARK: - Key previews

    /// A pop-up above a pressed character key, as the system keyboard does. The
    /// old build only tinted the key, which is hard to see under a thumb.
    private lazy var keyPreview: UILabel = {
        let l = UILabel()
        l.textAlignment = .center
        l.font = .systemFont(ofSize: 28, weight: .regular)
        l.layer.cornerRadius = 6
        l.layer.masksToBounds = true
        l.isHidden = true
        l.isUserInteractionEnabled = false
        return l
    }()

    private func showPreview(for sender: UIButton) {
        guard letterKeys.contains(sender), let title = sender.title(for: .normal) else { return }
        if keyPreview.superview == nil { view.addSubview(keyPreview) }
        keyPreview.backgroundColor = palette.key
        keyPreview.textColor = palette.keyText
        keyPreview.text = title
        let f = sender.convert(sender.bounds, to: view)
        let w = max(f.width + 14, 34)
        let h = f.height + 18
        keyPreview.frame = CGRect(x: f.midX - w / 2, y: f.minY - h - 3, width: w, height: h)
        keyPreview.isHidden = false
        view.bringSubviewToFront(keyPreview)
    }

    private func hidePreview() { keyPreview.isHidden = true }

    // MARK: - Typing actions

    @objc private func keyTapped(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(t)
        UIDevice.current.playInputClick()
        if shift == .once { shift = .off }
    }

    @objc private func keyDown(_ sender: UIButton) {
        sender.backgroundColor = palette.keyPressed
        showPreview(for: sender)
    }

    @objc private func keyUp(_ sender: UIButton) {
        sender.backgroundColor = palette.key
        hidePreview()
    }

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
        sender.backgroundColor = palette.specialPressed
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
        sender.backgroundColor = palette.special
        deleteRepeat?.invalidate()
        deleteRepeat = nil
    }

    // MARK: - Layout

    private var heightConstraint: NSLayoutConstraint?

    private func layout() {
        let bar = UIStackView(arrangedSubviews: [modeButton, micButton, undoButton])
        bar.axis = .horizontal
        bar.spacing = 6
        bar.distribution = .fill

        rowsStack.axis = .vertical
        rowsStack.spacing = 11
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

        let height = view.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .required
        heightConstraint = height

        NSLayoutConstraint.activate([
            height,
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

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(modeLongPressed(_:)))
        modeButton.addGestureRecognizer(lp)

        rebuildKeys()
    }

    /// The keyboard is shorter in landscape, where vertical space is scarce.
    private func updateHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        heightConstraint?.constant = compact ? 196 : 268
    }

    private func applyTheme() {
        view.backgroundColor = palette.board
        modeButton.backgroundColor = palette.special
        modeButton.setTitleColor(palette.specialText, for: .normal)
        globeButton.backgroundColor = palette.special
        globeButton.tintColor = palette.specialText
        undoButton.backgroundColor = palette.special
        undoButton.tintColor = palette.specialText
        rebuildKeys()
        render()
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

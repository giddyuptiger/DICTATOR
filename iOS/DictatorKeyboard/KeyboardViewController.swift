import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// A key that keeps its drop shadow cheap.
///
/// A CALayer shadow with no `shadowPath` is computed by rendering the layer
/// offscreen every time the key redraws — and with ~30 keys, each press (which
/// changes a key's background) and every relayout paid that cost, which is the
/// main source of typing jank. Setting an explicit `shadowPath` (updated when the
/// bounds change) turns the shadow into a cheap pre-rasterized rectangle.
final class KeyButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard layer.shadowOpacity > 0 else { return }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }
}

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

    private enum Mode: Equatable {
        case needsFullAccess
        case needsKey
        case needsSession      // app not running: cold start required
        case waking            // launching the app, waiting for it to come alive
        case ready
        case starting          // asked the app to record, waiting for it to confirm
        case recording
        case working
        case retryError        // a retryable failure; tap tries again
    }

    private var mode: Mode = .ready {
        // Render only on a real change. The 1 s modeWatch reassigns `mode` every
        // tick (usually to the same value); re-rendering the pill each second was
        // needless main-thread work while the user was typing.
        didSet { if mode != oldValue { render() } }
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
    /// Temporary diagnostic row: one button per app-open method, shown only when
    /// the app is not reachable, so we can find which technique launches Dictator
    /// on a real device/iOS. Remove once the winning method is confirmed.
    private lazy var debugRow    = makeDebugRow()
    private var lastInserted: String?
    private var retryMessage: String?
    /// Set when a wake attempt failed, so the needsSession line can tell the
    /// truth ("couldn't open") instead of the generic "Tap to wake Dictator".
    private var wakeMessage: String?

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

    /// Every colour is a DYNAMIC colour: UIKit resolves it against the view's own
    /// trait (its light/dark appearance) at draw time. The board, the keys and the
    /// glyphs are therefore ALWAYS the same theme — they resolve against the same
    /// trait at the same moment, so there is no manual light/dark flag that the
    /// board and the keys could read at different lifecycle points. That flag was
    /// the cause of the "grey board, black keys" mix: two earlier attempts (live
    /// read, then a cached bool) both still let the two diverge. Dynamic colours
    /// make a mix structurally impossible, and they follow the system appearance
    /// automatically (per Jeremy: always follow system) with no re-theming code.
    ///
    /// Light: cool grey board, white letter keys, grey special keys, ink glyphs.
    /// Dark: near-black board, raised mid-grey keys, darker special keys, white
    /// glyphs. Keys shift on press in both.
    private static func dyn(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static let dynamicPalette = Palette(
        board:          dyn(rgb(209, 212, 219), rgb(28,  28,  30)),  // #D1D4DB / #1C1C1E
        key:            dyn(.white,             rgb(72,  72,  74)),  // white   / #48484A
        keyPressed:     dyn(rgb(228, 230, 234), rgb(102, 102, 104)),// #E4E6EA / lighter
        special:        dyn(rgb(172, 178, 189), rgb(49,  49,  51)),  // #ACB2BD / #313133
        specialPressed: dyn(rgb(191, 196, 205), rgb(72,  72,  74)),
        keyText:        dyn(rgb(27,  27,  31),  .white),             // ink / white
        specialText:    dyn(rgb(27,  27,  31),  .white)
    )

    private var palette: Palette { Self.dynamicPalette }

    // MARK: - Pill highlights

    /// The mic pill's state colours. Soft pastel grounds with a deep, same-hue
    /// ink for the icon and label, instead of the old saturated "neon" system
    /// colours — softer on the eye while staying clearly legible and distinct by
    /// hue. The pill keeps its shadow, so a pale pastel still lifts off the board.
    private struct PillStyle { let bg: UIColor; let ink: UIColor }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r/255, green: g/255, blue: b/255, alpha: 1)
    }

    private static let pillBlue   = PillStyle(bg: rgb(169, 198, 240), ink: rgb(34,  64, 111)) // ready / wake
    private static let pillRed    = PillStyle(bg: rgb(242, 183, 179), ink: rgb(138, 44,  38)) // recording / retry
    private static let pillIndigo = PillStyle(bg: rgb(198, 193, 236), ink: rgb(58,  51, 112)) // busy
    private static let pillAmber  = PillStyle(bg: rgb(243, 211, 155), ink: rgb(110, 78,  18)) // needs setup

    private func applyPill(_ s: PillStyle) {
        micButton.backgroundColor = s.bg
        micButton.configuration?.baseForegroundColor = s.ink
        statusLabel.textColor = s.ink
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Colours are dynamic and resolve themselves; a re-apply here keeps the
        // key glyphs crisp if the trait only finished resolving on screen.
        applyTheme()
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
                case .recording:
                    // The app can end a capture on its own — at the 5-minute cap
                    // — without the user tapping stop. Follow it into transcribing
                    // so the keyboard doesn't sit on "Listening" while a result
                    // quietly arrives, and buzz so the user knows it auto-stopped
                    // and their words are safe. If instead the app went silent, it
                    // crashed mid-recording; its audio was flushed to disk.
                    if SharedStore.liveState == "transcribing" {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        self.mode = .working
                        self.waitForResult(hardCap: Date().addingTimeInterval(180))
                    } else if SharedStore.secondsSinceLive > 6 {
                        self.wakeMessage = "Dictator stopped mid-recording. Reopen it to recover your recording."
                        self.mode = .needsSession
                    }
                    return
                case .working, .starting, .retryError, .waking:
                    return          // mid-flight or showing an error, leave it alone
                default:
                    self.refreshMode()   // renders only if the mode actually changed
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
        // A live, reachable app proves the App Group + Darwin path works — which
        // is ALL this keyboard needs. Both work WITHOUT Full Access (Full Access
        // only gates network, and the keyboard does none — the container app does
        // every network call). So NEVER demote a working keyboard to "Turn on
        // Full Access": iOS's hasFullAccess flag is unreliable and flaps to false
        // right after a reinstall or a keyboard switch, which is exactly what made
        // the pill bounce waking → "Tap to talk" → "Turn on Full Access". Trust
        // the empirical signal (is the app actually answering?) over the flag.
        if appIsAlive {
            guard let k = SharedStore.groqAPIKey, !k.isEmpty else { mode = .needsKey; return }
            wakeMessage = nil   // a live app clears any stale "couldn't open" note
            mode = .ready
            return
        }
        // The app is not answering. Point at the most useful fix: without Full
        // Access the app also can't be launched from here, so surface that first;
        // otherwise it just needs waking (or a key).
        if !hasFullAccess { mode = .needsFullAccess; return }
        guard let k = SharedStore.groqAPIKey, !k.isEmpty else { mode = .needsKey; return }
        mode = .needsSession
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
        case .starting, .working, .waking:
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
        waitForResult(hardCap: Date().addingTimeInterval(180))
    }

    /// Ask the app to transcribe again on the audio it kept from a failure.
    private func retry() {
        retryMessage = nil
        DarwinBridge.shared.post(.retry)
        mode = .working
        waitForResult(hardCap: Date().addingTimeInterval(180))
    }

    /// Polls the App Group for a new result token.
    ///
    /// The .resultReady Darwin notification still fires and is still handled,
    /// but it cannot be depended on: a keyboard extension is recycled freely by
    /// the system, and an extension that was torn down and rebuilt between the
    /// stop tap and the transcript has no observer left to receive it. The
    /// shared container survives that; a notification does not.
    /// Wait for a transcript, patiently.
    ///
    /// The old version gave up after a flat 25 s. A five-minute dictation is a
    /// ~10 MB upload plus Whisper time, which routinely runs past 25 s, so the
    /// keyboard would declare failure while the app was still working and then
    /// strand the result it later produced. The real signals are: a new result
    /// token (done), or the app going silent (crashed/killed). So wait as long as
    /// the app keeps stamping the App Group; only the app dying, or an absolute
    /// backstop, ends the wait. A long transcription now shows elapsed seconds so
    /// the wait never reads as a hang.
    private func waitForResult(hardCap: Date) {
        resultWatch?.invalidate()
        let startedAt = Date()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if SharedStore.resultToken != self.lastSeenToken {
                    self.cancelResultWatch()
                    self.consumeResult()
                    return
                }
                // The app crashed or was jettisoned mid-transcription: it has
                // stopped stamping the App Group. Its audio was persisted to
                // disk, so reopening recovers it.
                if SharedStore.secondsSinceLive > 6 {
                    self.cancelResultWatch()
                    self.statusLabel.text = "Dictator stopped. Reopen it — your recording was saved."
                    self.wakeMessage = "Dictator stopped mid-transcription. Reopen it to recover your recording."
                    self.mode = .needsSession
                    return
                }
                if Date() >= hardCap {
                    self.cancelResultWatch()
                    self.statusLabel.text = "Still working. Open Dictator to check."
                    self.mode = .ready
                    return
                }
                // Still working: show elapsed once it is long enough to matter,
                // so a slow transcription reads as progress, not a freeze.
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                self.statusLabel.text = elapsed >= 3 ? "Transcribing… \(elapsed)s" : "Transcribing"
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
    ///
    /// The old version was silent when the launch failed: it set "Opening
    /// Dictator…", trusted the launch to have worked, and never corrected itself,
    /// so a refused launch read as a button that does nothing. Now every wake
    /// gives haptic feedback, enters a `.waking` state, tries every known open
    /// method (see attemptOpen/OpenMethod), and polls whether the app actually
    /// came alive — advancing to ready on success or saying so honestly on failure.
    private func coldStart() {
        wakeMessage = nil
        mode = .waking
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Try every known method, best-first, until one "takes". iOS 18+ broke
        // the legacy perform("openURL:") selector; the modern path — walk the
        // responder chain to the real UIApplication and call
        // open(_:options:completionHandler:) — is the current sanctioned way, and
        // Apple App Review does allow a keyboard to launch its OWN container app.
        for method in OpenMethod.allCases where attemptOpen(method) { break }

        // Whatever the launch call claims, the only truth is whether the app
        // starts stamping the App Group. Poll for it. If the launch worked, the
        // app comes to the foreground over us and this timer is suspended until
        // the user swipes back — by which point viewWillAppear has already found
        // it alive and moved to .ready, so the failure branch never fires. If the
        // launch was refused, we stay foregrounded and this reports it.
        waitForWake(deadline: Date().addingTimeInterval(3.0))
    }

    private func waitForWake(deadline: Date) {
        coldStartTimer?.invalidate()
        coldStartTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .waking else { return }
                if self.appIsAlive {
                    self.cancelWait()
                    self.wakeMessage = nil
                    self.mode = .ready
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else if Date() >= deadline {
                    self.cancelWait()
                    self.wakeMessage = "Couldn't open Dictator. Open it from your Home Screen, then come back."
                    self.mode = .needsSession
                }
            }
        }
    }

    // MARK: - Launching the container app

    /// The known ways for a keyboard extension to open its container app, in
    /// order of expected reliability on current iOS. We try them best-first, and
    /// the debug row lets us test each one individually on a real device.
    enum OpenMethod: Int, CaseIterable {
        case modernResponder    // responder chain → UIApplication.open(options:)
        case legacySelector     // responder chain → perform("openURL:") (pre-iOS18)
        case extensionContext   // extensionContext.open (usually refused for kbds)

        /// Short label for the debug button.
        var label: String {
            switch self {
            case .modernResponder:  return "A: open()"
            case .legacySelector:   return "B: openURL:"
            case .extensionContext: return "C: extCtx"
            }
        }
    }

    private var dictateURL: URL { URL(string: "dictator://dictate")! }

    /// Attempt one open method. Returns whether the call was actually made — NOT
    /// whether the app opened (only the App-Group poll can know that). iOS 18
    /// broke `perform("openURL:")`; `modernResponder` is the current path.
    @discardableResult
    private func attemptOpen(_ method: OpenMethod) -> Bool {
        let url = dictateURL
        switch method {
        case .modernResponder:
            var responder: UIResponder? = self
            while let r = responder {
                if let app = r as? UIApplication {
                    app.open(url, options: [:], completionHandler: nil)
                    return true
                }
                responder = r.next
            }
            return false
        case .legacySelector:
            let selector = NSSelectorFromString("openURL:")
            var responder: UIResponder? = self
            while let r = responder {
                if r.responds(to: selector) {
                    r.perform(selector, with: url)
                    return true
                }
                responder = r.next
            }
            return false
        case .extensionContext:
            extensionContext?.open(url, completionHandler: nil)
            return extensionContext != nil
        }
    }

    /// Debug: try ONE named method, then report whether the app came alive, so we
    /// can tell exactly which technique launches Dictator on this device/iOS.
    private func debugTryOpen(_ method: OpenMethod) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let made = attemptOpen(method)
        mode = .waking
        statusLabel.text = "\(method.label): trying…"
        let deadline = Date().addingTimeInterval(3.0)
        coldStartTimer?.invalidate()
        coldStartTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.appIsAlive {
                    self.cancelWait()
                    self.wakeMessage = nil
                    self.mode = .ready
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else if Date() >= deadline {
                    self.cancelWait()
                    self.wakeMessage = made
                        ? "\(method.label): no launch"
                        : "\(method.label): not available"
                    self.mode = .needsSession
                }
            }
        }
    }

    @objc private func debugOpenA() { debugTryOpen(.modernResponder) }
    @objc private func debugOpenB() { debugTryOpen(.legacySelector) }
    @objc private func debugOpenC() { debugTryOpen(.extensionContext) }

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

        micButton.isEnabled = true
        micButton.alpha = 1

        // Show the diagnostic open-method buttons only while the app is not
        // reachable — that is the only time launching it is relevant.
        switch mode {
        case .needsSession, .needsFullAccess, .waking:
            debugRow.isHidden = false
        default:
            debugRow.isHidden = true
        }

        switch mode {
        case .needsFullAccess:
            applyPill(Self.pillAmber)
            statusLabel.text = "Turn on Full Access for Dictator"
        case .needsKey:
            applyPill(Self.pillAmber)
            statusLabel.text = "Add your Groq key in Dictator"
        case .needsSession:
            applyPill(Self.pillBlue)
            // Honest copy: a keyboard extension cannot reliably launch its
            // container app on modern iOS, so we instruct rather than promise a
            // tap that often can't deliver. The tap still attempts a launch (it
            // works on some setups), but the words tell the user the reliable path.
            statusLabel.text = wakeMessage ?? "Open the Dictator app to wake it"
        case .waking:
            applyPill(Self.pillIndigo)
            statusLabel.text = "Waking Dictator…"
        case .ready:
            applyPill(Self.pillBlue)
            statusLabel.text = "Tap to talk"
        case .starting:
            applyPill(Self.pillIndigo)
            statusLabel.text = "Starting"
        case .recording:
            applyPill(Self.pillRed)
            statusLabel.text = "Listening. Tap to stop."
        case .working:
            applyPill(Self.pillIndigo)
            statusLabel.text = "Transcribing"
        case .retryError:
            applyPill(Self.pillRed)
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
            if isCurrent {
                conf.image = UIImage(systemName: "checkmark")
                conf.imagePadding = 8
                conf.imagePlacement = .trailing
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
    private var deleteTicks = 0
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
        // KeyButton (not UIButton(type:)) so the shadow gets a shadowPath and does
        // not force an offscreen render on every press/relayout. Frame init keeps
        // the .custom button behaviour.
        let b = KeyButton(frame: .zero)
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
        deleteTicks = 0
        // Hold to repeat, after a short grace period, then ACCELERATE and switch
        // to whole-word deletion — exactly what the system keyboard does. A flat
        // per-character repeat crawls when you want to clear a paragraph; this
        // wipes single chars for the first stretch, then eats words, so holding
        // backspace actually clears "a bunch" fast.
        let grace = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fast = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.deleteRepeatTick() }
                }
                RunLoop.main.add(fast, forMode: .common)
                self.deleteRepeat = fast
            }
        }
        RunLoop.main.add(grace, forMode: .common)
        deleteRepeat = grace
    }

    /// One tick of a held backspace. Deletes single characters for the first
    /// ~1.5 s, then switches to whole-word deletion so a long hold clears text
    /// quickly instead of one letter at a time.
    private func deleteRepeatTick() {
        deleteTicks += 1
        if deleteTicks > 16 {
            deleteWordBackward()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    /// Delete the whitespace and the word immediately before the cursor. Falls
    /// back to a single character when the host app does not expose the context
    /// (some secure fields do not).
    private func deleteWordBackward() {
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, !before.isEmpty else {
            proxy.deleteBackward(); return
        }
        let chars = Array(before)
        var i = chars.count - 1
        var count = 0
        while i >= 0, chars[i].isWhitespace { count += 1; i -= 1 }   // trailing spaces/newlines
        while i >= 0, !chars[i].isWhitespace { count += 1; i -= 1 }   // the word itself
        for _ in 0..<max(count, 1) { proxy.deleteBackward() }
    }

    @objc private func deleteUp(_ sender: UIButton) {
        sender.backgroundColor = palette.special
        deleteRepeat?.invalidate()
        deleteRepeat = nil
        deleteTicks = 0
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

        let root = UIStackView(arrangedSubviews: [bar, debugRow, rowsStack])
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
            debugRow.heightAnchor.constraint(equalToConstant: 30),
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

    /// The keyboard's light/dark, from the host's requested keyboard appearance,
    /// falling back to the system trait. This is the signal that matches the
    /// system keyboard sitting next to us.
    private func resolveDark() -> Bool {
        switch textDocumentProxy.keyboardAppearance {
        case .dark:  return true
        case .light: return false
        default:     return traitCollection.userInterfaceStyle == .dark
        }
    }

    private func applyTheme() {
        // FORCE one appearance on the whole keyboard. Dynamic colours were not
        // enough: in a keyboard extension the root view and the key buttons can
        // resolve their light/dark trait DIFFERENTLY, which is what produced the
        // "light board, dark keys" mix even with dynamic colours. Pinning
        // overrideUserInterfaceStyle makes every descendant inherit the same
        // style, so board, keys, bar and glyphs all resolve to it — no mix.
        view.overrideUserInterfaceStyle = resolveDark() ? .dark : .light
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
        b.layer.cornerRadius = 12
        // A soft shadow so the pill reads as the one raised, tappable hero above
        // the flat board, rather than another panel painted on it.
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.18
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowRadius = 3
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

    /// Three tiny buttons, one per open method, so we can find which one actually
    /// launches Dictator on a real device. Tap each; whichever brings Dictator to
    /// the foreground is the winner. Temporary — removed once confirmed.
    private func makeDebugRow() -> UIStackView {
        let make: (String, Selector) -> UIButton = { title, action in
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .systemGray4
            b.layer.cornerRadius = 8
            b.addTarget(self, action: action, for: .touchUpInside)
            return b
        }
        let row = UIStackView(arrangedSubviews: [
            make(OpenMethod.modernResponder.label, #selector(debugOpenA)),
            make(OpenMethod.legacySelector.label,  #selector(debugOpenB)),
            make(OpenMethod.extensionContext.label, #selector(debugOpenC)),
        ])
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        row.isHidden = true
        return row
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

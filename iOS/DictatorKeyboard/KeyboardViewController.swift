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

/// The vertical stack that holds every key row. Its one job beyond layout is to
/// make sure NO tap is ever lost in the gaps.
///
/// Keys are UIButtons with 6pt gaps between them, 11pt between rows (the band above
/// the space bar is the worst offender), and small side margins. A touch that lands
/// in one of those gaps normally hits the stack view — not a button — and iOS
/// silently drops it, which is the "misses ~1 in 12 letters" bug. Every serious
/// third-party keyboard hits this and fixes it the same way: one surface owns the
/// touches and snaps each one to the NEAREST key.
///
/// Here we do the low-risk version of that: keep the existing buttons and their
/// (already touch-down) commit path, but override hitTest so a tap in a gap is
/// routed to the closest key instead of falling through. A point inside a real key
/// still returns that key unchanged.
final class KeyHitStack: UIStackView {
    /// When false, the nearest-key snapping below is skipped and hit testing is
    /// normal. The emoji plane sets this off: its grid is a UICollectionView, and
    /// snapping a grid tap to the nearest UIControl would steal it for the control
    /// row's ABC / space / delete buttons.
    var snapEnabled = true
    /// Marks the space bar so hitTest can lift its hit area upward a touch.
    static let spaceTag = 9901
    /// How far up the space bar's hit area reaches, in points. Covers the gap
    /// above it plus a sliver of the b/n/m row, so a fast thumb aiming for space
    /// doesn't catch those letters. Kept small so it barely steals from them.
    private static let spaceLift: CGFloat = 13

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Emoji plane: normal hit testing, no nearest-key snapping (see snapEnabled).
        guard snapEnabled else { return super.hitTest(point, with: event) }

        // Only claim touches that land within our own bounds (the key area). A
        // point outside — the mic pill/toolbar above the keys, or the margin below
        // — MUST fall through to its real view. Without this guard the nearest-key
        // snap below stole taps on the "Tap to talk" pill and typed y/u instead,
        // because UIKit calls hitTest here for sibling points too. (0.1.86 bug.)
        guard self.point(inside: point, with: event) else { return nil }

        // Space-bar lift: give the space bar a small head start on the band just
        // above it, so quick space taps that land low on b/n/m still register as
        // space. Only extends UPWARD, only by spaceLift, so normal b/n/m taps are
        // unaffected.
        if let space = firstControl(in: self, tagged: Self.spaceTag) {
            var f = space.convert(space.bounds, to: self)
            f.origin.y -= Self.spaceLift
            f.size.height += Self.spaceLift
            if f.contains(point) { return space }
        }

        let hit = super.hitTest(point, with: event)
        // A real, tappable key was hit — use it as-is.
        if let hit, hit !== self, hit.isUserInteractionEnabled, hit is UIControl {
            return hit
        }
        // Otherwise the touch landed in a gap or margin. Find the nearest key so
        // the tap is never lost.
        var best: UIControl?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        func scan(_ v: UIView) {
            for sub in v.subviews {
                if let control = sub as? UIControl,
                   control.isUserInteractionEnabled, !control.isHidden, control.alpha > 0.01 {
                    let frame = control.convert(control.bounds, to: self)
                    let d = Self.squaredDistance(from: point, to: frame)
                    if d < bestDistance { bestDistance = d; best = control }
                } else {
                    scan(sub)   // recurse into row stacks / containers, not into keys
                }
            }
        }
        scan(self)
        return best ?? hit
    }

    /// Find the first descendant control carrying `tag` (the space bar).
    private func firstControl(in v: UIView, tagged tag: Int) -> UIControl? {
        for sub in v.subviews {
            if let c = sub as? UIControl, c.tag == tag { return c }
            if let found = firstControl(in: sub, tagged: tag) { return found }
        }
        return nil
    }

    /// Squared distance from a point to the nearest edge of a rect (0 if inside).
    /// Squared is enough for a min-comparison and avoids a sqrt per key.
    private static func squaredDistance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
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
        case needsSetup        // first run: onboarding not finished yet
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
    private var messageClear: Timer?

    private lazy var micButton   = makeMic()
    private lazy var statusLabel = makeStatus()
    private lazy var globeButton = makeGlobe()
    private lazy var undoButton  = makeUndo()
    private lazy var redoButton  = makeRedo()
    private lazy var modeButton  = makeMode()
    private lazy var polishButton = makePolish()
    private var lastInserted: String?
    /// Set when `lastInserted` replaced existing text (the Polish key): undo
    /// deletes the replacement AND puts this back, so a polish is never lossy.
    private var undoRestores: String?

    /// One Polish request in flight: what was sent, and how to replace it when
    /// the answer comes back.
    private struct PolishJob {
        let original: String
        let beforeCount: Int
        let afterCount: Int
        let isSelection: Bool
    }
    private var polishJob: PolishJob?
    private var lastPolishToken: String?
    private var polishTimeout: Timer?
    /// The text most recently removed by undo, so redo can put it back. Cleared
    /// whenever a new dictation is inserted (that invalidates the redo history).
    private var lastUndone: String?
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
        refreshReturnKey()   // the return key's label/colour depends on this field's returnKeyType
        startModeWatch()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Colours are dynamic and resolve themselves; a re-apply here keeps the
        // key glyphs crisp if the trait only finished resolving on screen.
        applyTheme()
        // Kill the edge-key input delay. iOS's own screen-edge swipe recognizers
        // live on the keyboard's window and default to delaysTouchesBegan = true,
        // which holds back the first touch on keys near the edges (q, a, p, l,
        // space) just long enough to drop it during fast typing. Clearing it is a
        // well-worn fix. Re-run every appear because the window can change; use the
        // safe optional form (a force-unwrap here is a known crash in other kbds).
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    /// Ask the system not to defer our edge touches for its own gestures, so the
    /// edge keys respond as fast as the centre keys.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        [.left, .right, .bottom]
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyTheme()
        updateHeight()
    }

    /// The host's text changed — by our key, by dictation, or by the user moving
    /// the caret. Two things have to follow it.
    ///
    /// 1. Shift. Nothing re-read the document context, so shift was whatever the
    ///    last keystroke left it as: tapping into the middle of a word offered a
    ///    capital, and the letter after a full stop did not. Now it tracks the
    ///    caret the way the system keyboard does.
    /// 2. Appearance. A host can put a dark sheet over a light screen and change
    ///    `keyboardAppearance` without any trait change, which fires no
    ///    traitCollectionDidChange — so the board stayed in the wrong theme.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncShiftToContext()
        refreshReturnKey()   // focus may have moved to a field with a different returnKeyType
        if (view.overrideUserInterfaceStyle == .dark) != resolveDark() { applyTheme() }
    }

    /// Auto-capitalisation, from the caret rather than from memory. Caps lock is
    /// left alone, and a field that asked for no autocapitalisation gets none.
    private func syncShiftToContext() {
        guard plane == .letters, shift != .locked else { return }
        guard textDocumentProxy.autocapitalizationType != UITextAutocapitalizationType.none else {
            if shift == .once { shift = .off }
            return
        }
        let wanted: Shift = shouldAutocapitalize(textDocumentProxy.documentContextBeforeInput) ? .once : .off
        if shift != wanted { shift = wanted }
    }

    /// A sentence boundary for the SHIFT key, which is stricter than the one used
    /// when inserting a transcript.
    ///
    /// Terminal punctuation alone is not enough: it has to be followed by a space
    /// or a newline. Capitalising the moment a full stop is typed turns
    /// "hello.com" into "hello.Com" and "3.5" into "3.5" only by luck.
    private func shouldAutocapitalize(_ before: String?) -> Bool {
        guard let before, let last = before.last else { return true }   // empty field
        if last == "\n" { return true }
        guard last == " " else { return false }
        // Skip a run of spaces to find what the sentence actually ended with.
        guard let terminal = before.dropLast().reversed().first(where: { $0 != " " }) else {
            return true                                                 // only spaces so far
        }
        return ".!?".contains(terminal)
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
        messageClear?.invalidate()
        messageClear = nil
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
        bridge.observe(.polishReady) { [weak self] in
            MainActor.assumeIsolated { self?.consumePolish() }
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
        // No API-key gate anymore. Transcription no longer needs a user-supplied
        // key: the container app always has a path (on-device, or the backend
        // proxy). A live, reachable app is all this keyboard requires.
        if appIsAlive {
            wakeMessage = nil   // a live app clears any stale "couldn't open" note
            mode = .ready
            return
        }
        // The app is not answering. Point at the most useful fix: without Full
        // Access the app also can't be launched from here, so surface that first;
        // then, if the user has never finished first-run setup, send them to do
        // it; otherwise the app just needs waking.
        if !hasFullAccess { mode = .needsFullAccess; return }
        if !SharedStore.onboardingDone { mode = .needsSetup; return }
        mode = .needsSession
    }

    // MARK: - Actions

    @objc private func micTapped() {
        // A tap on the pill is always deliberate — it is a separate row above the
        // keys and coldStart() only ever runs from here (nothing auto-opens the
        // app). An earlier build tried to suppress "accidental brushes" by ignoring
        // a pill tap within 1.2 s of a keystroke, but that swallowed real wake taps
        // right after typing (the pill "just flickered"), which is worse. So act on
        // every tap.
        switch mode {
        case .needsFullAccess, .needsSetup:
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
                    // Nobody picked up: the app is not resident (iOS suspended or
                    // killed it — common in Low Power Mode). Show the wake prompt
                    // rather than AUTO-launching the app: an unexpected jump to
                    // Dictator mid-typing is jarring. The user taps to wake it
                    // deliberately.
                    self.wakeMessage = nil
                    self.mode = .needsSession
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
                    self.wakeMessage = "Dictator stopped mid-transcription. Reopen it to recover your recording."
                    self.mode = .needsSession
                    self.render()
                    return
                }
                if Date() >= hardCap {
                    self.cancelResultWatch()
                    self.mode = .ready
                    // flash AFTER the mode change: the mode's own render would
                    // otherwise overwrite this the moment it ran.
                    self.flash("Still working. Open Dictator to check.", seconds: 6)
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

    /// Show a one-off message on the pill, then fall back to the mode's own text.
    ///
    /// Assigning `statusLabel.text` directly does not survive and does not clear:
    /// `render()` only runs when the MODE changes, so a message set while the
    /// mode was already `.ready` sat on the pill until the next state change —
    /// "Nothing heard" stayed under a blue Tap-to-talk pill indefinitely. Worse,
    /// a message set BEFORE a mode assignment was wiped by that mode's render
    /// and never seen at all.
    private func flash(_ message: String, seconds: TimeInterval = 4) {
        messageClear?.invalidate()
        statusLabel.text = message
        micButton.accessibilityValue = message
        UIAccessibility.post(notification: .announcement, argument: message)
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.messageClear = nil
                self.render()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        messageClear = t
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


    private func consumeResult() {
        let token = SharedStore.resultToken
        guard token != lastSeenToken else { return }
        lastSeenToken = token
        cancelResultWatch()
        // Also cancel an in-flight capture/wake wait. A result arriving while
        // waitForCapture was still polling left that timer running, so a couple
        // of seconds later it fired anyway and overwrote the result we had just
        // shown with "Open the Dictator app to wake it".
        cancelWait()

        if let err = SharedStore.lastError {
            if SharedStore.lastErrorRetryable {
                retryMessage = err
                mode = .retryError
                render()          // the mode may already BE .retryError
            } else {
                retryMessage = nil
                mode = .ready
                flash(err)
            }
            return
        }
        guard let text = SharedStore.transcript, !text.isEmpty else {
            mode = .ready
            return
        }

        // Some hosts silently ignore a keyboard extension's insertText — Google
        // Calendar's event/task title field is one: the transcript is produced but
        // nothing lands. Detect the common case (an empty field that still reports
        // no text right after we inserted) and fall back to the clipboard, so the
        // words are never lost — the user can paste them. Scoped to a field that was
        // empty beforehand, so normal typing into existing text never trips it.
        let hadText = textDocumentProxy.hasText
        let inserted = insert(text)
        if !hadText, !textDocumentProxy.hasText {
            UIPasteboard.general.string = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            lastInserted = nil               // nothing actually inserted, so nothing to undo
            lastUndone = nil
            undoButton.isHidden = true
            redoButton.isHidden = true
            mode = .ready
            render()
            flash("Couldn't type here — copied. Tap the field and paste.")
            return
        }

        lastInserted = inserted
        undoRestores = nil               // a dictation adds text; nothing to put back
        lastUndone = nil                 // a fresh dictation invalidates redo
        undoButton.isHidden = false
        redoButton.isHidden = true
        mode = .ready
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Inserts the transcript and returns EXACTLY what was inserted.
    ///
    /// Returning it is the point: undo deletes one character per character of
    /// what it thinks it typed, and the leading space below was not counted, so
    /// undo always left a stray space behind. One insertText call, one string,
    /// one thing to undo.
    @discardableResult
    private func insert(_ text: String) -> String {
        lastSwipedInsert = nil
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput

        // Capitalise the first letter at a sentence start, unless the register is
        // Super casual, which is deliberately lowercase.
        var out = text
        if DictationMode.current != .superCasual, atSentenceStart(before) {
            out = capitalizingFirst(out)
        }

        // Leading space when the previous character is not whitespace and the new
        // text does not open with punctuation.
        if let before, let last = before.last, !last.isWhitespace,
           let first = text.first, !first.isPunctuation {
            out = " " + out
        }

        // Multi-line transcripts (numbered lists, paragraphs) need care. A single
        // insertText of a big blob containing "\n" leaves some hosts — WhatsApp's
        // growing composer among them — stuck at one visible line: the text is
        // there but the box never reflows to its new height. Inserting each line
        // and each newline as its own call behaves like pressing Return, which the
        // host does grow for; a final zero-offset position nudge asks it to
        // recompute once more. Undo is unaffected: the concatenation equals `out`.
        if out.contains("\n") {
            let parts = out.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if !part.isEmpty { proxy.insertText(part) }
                if i < parts.count - 1 { proxy.insertText("\n") }
            }
            proxy.adjustTextPosition(byCharacterOffset: 0)
        } else {
            proxy.insertText(out)
        }
        return out
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
        // A polish replaced text: put the original back.
        if let original = undoRestores { textDocumentProxy.insertText(original) }
        lastInserted = nil
        lastUndone = t                 // keep it so redo can put it back
        undoButton.isHidden = true
        redoButton.isHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func redoTapped() {
        guard let t = lastUndone else { return }
        if let original = undoRestores {
            for _ in 0..<original.count { textDocumentProxy.deleteBackward() }
        }
        textDocumentProxy.insertText(t)
        lastInserted = t               // now undoable again
        lastUndone = nil
        redoButton.isHidden = true
        undoButton.isHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Rendering

    private func render() {
        modeButton.setTitle(DictationMode.current.displayName, for: .normal)
        modeButton.accessibilityLabel = "Style: \(DictationMode.current.displayName)"

        micButton.isEnabled = true
        micButton.alpha = 1
        defer {
            // VoiceOver reads the pill as one control, so the status line has to
            // travel with it. Without this the pill announced only "Dictate" and
            // never said whether it was listening, working, or asking for setup.
            micButton.accessibilityValue = statusLabel.text
            micButton.accessibilityLabel = mode == .recording ? "Stop dictating" : "Dictate"
        }

        switch mode {
        case .needsFullAccess:
            applyPill(Self.pillAmber)
            statusLabel.text = "Turn on Full Access for Dictator"
        case .needsSetup:
            applyPill(Self.pillAmber)
            statusLabel.text = "Complete setup in Dictator"
        case .needsSession:
            applyPill(Self.pillBlue)
            // Short, action-first copy: the tap attempts to launch the container
            // app (works on most setups), so lead with the action. wakeMessage
            // carries the fuller fallback path when a launch actually fails.
            statusLabel.text = wakeMessage ?? "Tap to wake Dictator"
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
        case letters, numbers, symbols, emoji
    }

    private enum Shift {
        case off, once, locked
    }

    private var plane: Plane = .letters { didSet { rebuildKeys() } }
    private var shift: Shift = .once   { didSet { refreshCaps() } }
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    /// When the user last typed a character. A mic-pill tap that lands within a
    /// moment of typing is treated as an accidental brush and is ignored for the
    /// app-launch cases, so typing can never bounce you into the Dictator app.
    private var lastKeyTime = Date.distantPast
    private var deleteRepeat: Timer?
    private var deleteTicks = 0
    private var letterKeys: [UIButton] = []

    // Swipe typing (see the "Swipe typing" section at the end of the file).
    /// A letter key inserts on touch-DOWN. If that same touch then travels across
    /// the board it is promoted to a swipe and the one character it already
    /// inserted is taken back — but only when these two prove that the last
    /// key-down was that touch's, and nothing else was typed in between.
    private var keyDownSeq = 0
    private var lastKeyDownButton: UIButton?
    /// What the last swipe inserted (leading space included), so the next
    /// backspace can take the whole word back. Cleared by any other key.
    private var lastSwipedInsert: String?
    /// The key layout is written to the activity log once per keyboard session,
    /// ahead of the first swipe path, so a logged swipe can be replayed exactly.
    private var swipeLayoutLogged = false
    private let swipeRecognizer = UIPanGestureRecognizer()
    private let swipeTrail = CAShapeLayer()
    private var glide = GlideState()

    private let rowsStack = KeyHitStack()
    private lazy var emojiView = makeEmojiView()

    private func makeEmojiView() -> EmojiKeyboardView {
        let v = EmojiKeyboardView()
        v.onPick = { [weak self] emoji in self?.insertEmoji(emoji) }
        return v
    }

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
        case .emoji:
            return []   // the emoji plane builds its own grid (see buildEmojiPlane)
        }
    }

    private func rebuildKeys() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterKeys.removeAll()

        // The emoji plane is one tall grid + a short control row (not equal key
        // rows), and its grid does its own hit testing.
        rowsStack.distribution = (plane == .emoji) ? .fill : .fillEqually
        rowsStack.snapEnabled = (plane != .emoji)

        // Swipe typing lives on the letters plane only. A rebuild under a live
        // swipe (a theme flip mid-gesture) ends it cleanly rather than decoding a
        // path against keys that no longer exist.
        endGlide(commit: false)
        swipeRecognizer.isEnabled = (plane == .letters) && swipeTypingEnabled

        if plane == .emoji { buildEmojiPlane(); return }

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
        shiftKey.accessibilityLabel = plane == .letters
            ? "Shift"
            : (plane == .numbers ? "More symbols" : "Numbers")
        // Delete fires on touch-DOWN only. It used to ALSO carry a touchUpInside
        // target, so lifting off after a long hold deleted one extra character
        // after the repeat had already stopped.
        let deleteKey = makeSpecial(image: "delete.left", title: nil, action: nil)
        deleteKey.accessibilityLabel = "Delete"
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

        // Row 4: plane switch, globe (switch keyboards — keeps Japanese etc.),
        // emoji, space, return.
        let fourth = UIStackView()
        fourth.axis = .horizontal
        fourth.spacing = 6
        fourth.distribution = .fill

        let planeKey = makeSpecial(
            image: nil,
            title: plane == .letters ? "123" : "ABC",
            action: #selector(planeSwitchTapped)
        )
        planeKey.accessibilityLabel = plane == .letters ? "Numbers and punctuation" : "Letters"
        // The emoji key opens OUR in-keyboard emoji keyboard (a real categorized
        // picker), so it never switches away to another keyboard. Keyboard
        // switching (Japanese, etc.) lives on its own globe key beside it.
        let emojiKey = makeSpecial(image: "face.smiling", title: nil, action: #selector(emojiTapped))
        emojiKey.accessibilityLabel = "Emoji"
        // Space on touch-DOWN, for the same reason as the letters: fast typing
        // rolls off the space bar before a clean touchUpInside, dropping the space
        // (this is what turned "chat tomorrow" into "chattomorrow").
        let space = makeSpecial(image: nil, title: "space", action: nil)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchDown)
        space.accessibilityLabel = "Space"
        // Tag it so the hit surface can lift its hit area upward a little: a fast
        // thumb reaching for space often lands on the b/n/m row just above it.
        space.tag = KeyHitStack.spaceTag
        space.backgroundColor = palette.key
        space.setTitleColor(palette.keyText, for: .normal)
        let ret = makeSpecial(image: nil, title: returnKeyTitle(), action: #selector(returnTapped))
        ret.accessibilityLabel = returnKeyTitle()
        returnKey = ret
        refreshReturnKey()

        fourth.addArrangedSubview(planeKey)
        fourth.addArrangedSubview(globeButton)
        fourth.addArrangedSubview(emojiKey)
        fourth.addArrangedSubview(space)
        fourth.addArrangedSubview(ret)
        planeKey.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.12).isActive = true
        globeButton.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.10).isActive = true
        emojiKey.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.10).isActive = true
        ret.widthAnchor.constraint(equalTo: fourth.widthAnchor, multiplier: 0.20).isActive = true
        rowsStack.addArrangedSubview(fourth)

        refreshCaps()
    }

    /// The emoji plane: our full categorized emoji keyboard (EmojiKeyboardView)
    /// filling the key area, plus a short control row with ABC (back to letters),
    /// space, and delete. Tapping an emoji inserts it and never switches keyboards.
    private func buildEmojiPlane() {
        emojiView.reload()
        emojiView.setContentHuggingPriority(.defaultLow, for: .vertical)
        rowsStack.addArrangedSubview(emojiView)   // fills the vertical space

        let ctrl = UIStackView()
        ctrl.axis = .horizontal
        ctrl.spacing = 6
        ctrl.distribution = .fill

        let abc = makeSpecial(image: nil, title: "ABC", action: #selector(emojiBackTapped))
        abc.accessibilityLabel = "Letters"
        let space = makeSpecial(image: nil, title: "space", action: nil)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchDown)
        space.accessibilityLabel = "Space"
        space.tag = KeyHitStack.spaceTag
        space.backgroundColor = palette.key
        space.setTitleColor(palette.keyText, for: .normal)
        let del = makeSpecial(image: "delete.left", title: nil, action: nil)
        del.accessibilityLabel = "Delete"
        del.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        del.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        ctrl.addArrangedSubview(abc)
        ctrl.addArrangedSubview(space)
        ctrl.addArrangedSubview(del)
        abc.widthAnchor.constraint(equalTo: ctrl.widthAnchor, multiplier: 0.20).isActive = true
        del.widthAnchor.constraint(equalTo: ctrl.widthAnchor, multiplier: 0.15).isActive = true
        ctrl.heightAnchor.constraint(equalToConstant: 44).isActive = true
        rowsStack.addArrangedSubview(ctrl)
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
        // Insert on touch-DOWN, like the system keyboard. Inserting on
        // touchUpInside dropped characters during fast "rolling" typing (you press
        // the next key before lifting the last, so the previous key never fires a
        // clean touchUpInside). touchDown fires reliably for every key press.
        b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    /// `action` is optional because two of these keys fire on touch-DOWN, not on
    /// touchUpInside. Space used to be built with a touchUpInside target that was
    /// then removed again, and delete kept one it should never have had.
    private func makeSpecial(image: String?, title: String?, action: Selector?) -> UIButton {
        let b = UIButton(type: .custom)
        if let image {
            b.setImage(UIImage(systemName: image), for: .normal)
            b.tintColor = palette.specialText
        }
        if let title {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
            // "continue" is a real returnKeyType title and does not fit a 22%
            // key at full size.
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.7
            b.titleLabel?.lineBreakMode = .byClipping
            b.setTitleColor(palette.specialText, for: .normal)
        }
        b.backgroundColor = palette.special
        b.layer.cornerRadius = 5
        if let action { b.addTarget(self, action: action, for: .touchUpInside) }
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

    @objc private func keyDown(_ sender: UIButton) {
        // KEEP THIS PATH MINIMAL. It runs on every keypress, and any main-thread
        // work here shows up as typing lag and — when the thread stalls — dropped
        // keys (iOS coalesces touches while the main thread is busy). So: insert
        // the character, flip the press colour, and nothing else. Deliberately
        // NOT here: playInputClick() (its sound routes through the audio system,
        // which in this app is busy holding the always-on mic session — a
        // per-keystroke stall a normal keyboard never has) and showPreview() (a
        // full convert/frame/bringSubviewToFront layout pass per press).
        if let t = sender.title(for: .normal) {
            // A letter tapped right after a SWIPED word gets a space in front, as
            // on Apple's keyboard: swipe "the", tap "iOS" -> "the iOS", not
            // "theiOS". Only after a swipe (lastSwipedInsert is nil otherwise, so
            // this costs a nil check on the hot path), only for letters, and only
            // when the text does not already end in whitespace.
            if lastSwipedInsert != nil, t.count == 1, t.first?.isLetter == true,
               let last = textDocumentProxy.documentContextBeforeInput?.last, !last.isWhitespace {
                textDocumentProxy.insertText(" ")
            }
            textDocumentProxy.insertText(t)
            if shift == .once { shift = .off }
        }
        // Two stores for swipe typing: which key this touch-down was, and a count
        // so the swipe handler can prove nothing else was typed since.
        keyDownSeq &+= 1
        lastKeyDownButton = sender
        lastSwipedInsert = nil
        lastKeyTime = Date()
        sender.backgroundColor = palette.keyPressed
    }

    @objc private func keyUp(_ sender: UIButton) {
        sender.backgroundColor = palette.key
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
    }

    @objc private func planeSwitchTapped() {
        plane = (plane == .letters) ? .numbers : .letters
    }

    @objc private func planeToggleTapped() {
        plane = (plane == .numbers) ? .symbols : .numbers
    }

    @objc private func emojiTapped() {
        plane = .emoji
    }

    @objc private func emojiBackTapped() {
        plane = .letters
    }

    /// Insert a tapped emoji. Recents are recorded inside EmojiKeyboardView.
    private func insertEmoji(_ emoji: String) {
        lastSwipedInsert = nil
        textDocumentProxy.insertText(emoji)
        lastKeyTime = Date()
    }

    @objc private func spaceTapped() {
        lastSwipedInsert = nil
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
    }

    @objc private func returnTapped() {
        lastSwipedInsert = nil
        textDocumentProxy.insertText("\n")
    }

    private var returnKey: UIButton?

    /// The system keyboard makes the return key PROMINENT (blue, white text) when
    /// the field wants an action — Go, Send, Search, Done, etc. — and leaves a plain
    /// "return" grey. Match that so our key reads as the submit button it is.
    private func refreshReturnKey() {
        guard let ret = returnKey else { return }
        let title = returnKeyTitle()
        ret.setTitle(title, for: .normal)
        ret.accessibilityLabel = title
        if textDocumentProxy.returnKeyType == .default {
            ret.backgroundColor = palette.special
            ret.setTitleColor(palette.specialText, for: .normal)
        } else {
            ret.backgroundColor = .systemBlue
            ret.setTitleColor(.white, for: .normal)
        }
    }

    /// The return key says what it will do, like the system keyboard does. A
    /// Send field that offers a key labelled "return" is the kind of small wrong
    /// detail that makes a keyboard feel like a stand-in for the real one.
    private func returnKeyTitle() -> String {
        switch textDocumentProxy.returnKeyType {
        case .go:            return "go"
        case .join:          return "join"
        case .next:          return "next"
        case .route:         return "route"
        case .search:        return "search"
        case .google:        return "search"
        case .yahoo:         return "search"
        case .send:          return "send"
        case .done:          return "done"
        case .emergencyCall: return "call"
        case .continue:      return "continue"
        default:             return "return"
        }
    }

    @objc private func deleteDown(_ sender: UIButton) {
        sender.backgroundColor = palette.specialPressed
        // The one deletion a tap performs, on touch-down like every other key.
        // Right after a swiped word, one backspace takes back the WHOLE word (and
        // the space the swipe added), as Apple's keyboard does, so a wrong guess
        // costs one tap rather than one per letter. Only while the text still
        // ends with exactly what the swipe inserted; anything typed since makes
        // this an ordinary single-character delete.
        if let swiped = lastSwipedInsert,
           let before = textDocumentProxy.documentContextBeforeInput, before.hasSuffix(swiped) {
            for _ in 0..<swiped.count { textDocumentProxy.deleteBackward() }
            // A taken-back swipe is the one wrong-guess signal that needs no
            // effort from the user; the log pairs it with the swipe above it.
            SharedStore.appendSwipeLog("swipe-undo \(swiped.trimmingCharacters(in: .whitespaces))")
        } else {
            textDocumentProxy.deleteBackward()
        }
        lastSwipedInsert = nil
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
        let bar = UIStackView(arrangedSubviews: [modeButton, polishButton, micButton, undoButton, redoButton])
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
        redoButton.isHidden = true

        let height = view.heightAnchor.constraint(equalToConstant: 268)
        // NOT .required. The system installs its own temporary height constraints
        // while a keyboard appears and rotates, and a required constraint of ours
        // conflicts with them — which shows up as constraint-break logs and a
        // visible height jump on the first appearance. 999 wins against
        // everything that matters and yields to the system's own.
        height.priority = UILayoutPriority(999)
        heightConstraint = height

        NSLayoutConstraint.activate([
            height,
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),

            bar.heightAnchor.constraint(equalToConstant: 42),
            modeButton.widthAnchor.constraint(equalToConstant: 86),
            polishButton.widthAnchor.constraint(equalToConstant: 42),
            undoButton.widthAnchor.constraint(equalToConstant: 42),
            redoButton.widthAnchor.constraint(equalToConstant: 42),

            statusLabel.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: -10)
        ])

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(modeLongPressed(_:)))
        modeButton.addGestureRecognizer(lp)

        setUpSwipeTyping()
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
        redoButton.backgroundColor = palette.special
        redoButton.tintColor = palette.specialText
        emojiView.glyphTint = palette.keyText
        emojiView.stripBackground = palette.board
        emojiView.selectedTabBackground = palette.special
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
        b.accessibilityLabel = "Dictate"
        return b
    }

    private func makeStatus() -> UILabel {
        let l = UILabel()
        l.textAlignment = .left
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = .white
        // Two lines. The honest failure copy ("Dictator stopped mid-transcription.
        // Reopen it to recover your recording.") was being squeezed onto one line
        // at 70% size, which is the point where a message stops being read.
        l.numberOfLines = 2
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.8
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
        b.accessibilityHint = "Changes the writing style. Touch and hold to pick one."
        return b
    }

    private func makeGlobe() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 5
        b.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        b.accessibilityLabel = "Next keyboard"
        return b
    }

    private func makeUndo() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        b.accessibilityLabel = "Undo dictation"
        return b
    }

    private func makeRedo() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "arrow.uturn.forward"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(redoTapped), for: .touchUpInside)
        b.accessibilityLabel = "Redo dictation"
        return b
    }

    private func makePolish() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "wand.and.stars"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemGray3
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(polishTapped), for: .touchUpInside)
        b.accessibilityLabel = "Polish text"
        return b
    }

    // MARK: - Polish (Pro)

    /// Rewrite what is already in the field in the current mode — typos, swipe
    /// mis-guesses, punctuation, capitals, and the register (Formal, Expressive,
    /// Shakespeare…). Selected text is polished on its own; with no selection,
    /// the text the host exposes around the cursor is (for a message, that is
    /// the whole message). The work happens in the app over the same channel a
    /// dictation uses; the keyboard itself never networks.
    @objc private func polishTapped() {
        guard Pro.allows(.polish) else { flash("Polish is a Pro feature."); return }
        guard polishJob == nil else { return }
        guard mode == .ready || mode == .retryError else {
            flash(appIsAlive ? "Busy. Try again in a moment." : "Tap the pill to wake Dictator first.")
            return
        }
        let proxy = textDocumentProxy
        let job: PolishJob
        if let selected = proxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            job = PolishJob(original: selected, beforeCount: 0, afterCount: 0, isSelection: true)
        } else {
            let before = proxy.documentContextBeforeInput ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            let text = before + after
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flash("Nothing to polish yet.")
                return
            }
            job = PolishJob(original: text, beforeCount: before.count, afterCount: after.count, isSelection: false)
        }
        polishJob = job
        SharedStore.publishPolishRequest(job.original)
        DarwinBridge.shared.post(.polish)
        flash("Polishing…", seconds: 20)
        polishTimeout?.invalidate()
        let t = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.polishJob != nil else { return }
                self.polishJob = nil
                self.flash("Couldn't reach Dictator. Try again.")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        polishTimeout = t
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The app answered: replace exactly what was sent with the polished text,
    /// and arm undo to put the original back.
    private func consumePolish() {
        let token = SharedStore.polishResultToken
        guard token != lastPolishToken else { return }
        lastPolishToken = token
        polishTimeout?.invalidate()
        polishTimeout = nil
        guard let job = polishJob else { return }
        polishJob = nil

        if let err = SharedStore.polishError { flash(err); return }
        guard let polished = SharedStore.polishResult, !polished.isEmpty else {
            flash("Couldn't polish right now. Try again.")
            return
        }
        let proxy = textDocumentProxy
        if job.isSelection {
            proxy.insertText(polished)             // replaces the selection
        } else {
            // We read before + after around the cursor: jump to the end of that
            // window, delete exactly what we read, and type the polished text.
            if job.afterCount > 0 { proxy.adjustTextPosition(byCharacterOffset: job.afterCount) }
            for _ in 0..<(job.beforeCount + job.afterCount) { proxy.deleteBackward() }
            proxy.insertText(polished)
        }
        lastInserted = polished
        undoRestores = job.original
        lastUndone = nil
        lastSwipedInsert = nil
        undoButton.isHidden = false
        redoButton.isHidden = true
        render()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Key clicks only sound if the input view declares it wants them.
final class KeyboardRootView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Swipe typing

/// QuickPath-style swipe (glide) typing on the letters plane.
///
/// How it coexists with insert-on-touch-down (LESSONS: non-negotiable for taps):
/// a touch on a letter key inserts that letter immediately, exactly as before. A
/// pan recognizer on the key stack watches the same touch without ever cancelling
/// it. If the touch travels far enough to reach a DIFFERENT key, it is promoted to
/// a swipe: the one letter it already inserted is deleted (only when the key-down
/// count proves it was this touch's, and nothing else was typed since), a trail is
/// drawn, and on lift the path is decoded to a word (SwipeDecoder) and inserted
/// with QuickPath's spacing and capitalisation rules. A jittery tap never travels
/// to another key, so tap typing is untouched. Special keys never start a swipe.
extension KeyboardViewController: UIGestureRecognizerDelegate {

    /// One swipe, from first touch to lift.
    private struct GlideState {
        var startKey: UIButton?
        var startPoint = CGPoint.zero
        /// Shift as it stood when the touch began (before the key-down consumed
        /// a one-shot shift), so the swiped word capitalises as a tap would have.
        var shiftAtStart: Shift = .off
        var seqAtStart = 0
        var points: [CGPoint] = []
        var active = false
    }

    /// The one gate for swipe typing: the Settings switch today, and — when Pro
    /// ships — the place to also require the entitlement (swipe typing is a Pro
    /// line item; Apple's keyboard has it, Wispr's does not). Read on plane
    /// changes, never per key.
    private var swipeTypingEnabled: Bool { SharedStore.swipeTypingEnabled }

    private func setUpSwipeTyping() {
        swipeRecognizer.addTarget(self, action: #selector(glidePan(_:)))
        swipeRecognizer.maximumNumberOfTouches = 1
        // Never take the touch away from the key underneath: it keeps its own
        // touch-down insert, press colour and lift, exactly as for a tap.
        swipeRecognizer.cancelsTouchesInView = false
        swipeRecognizer.delaysTouchesBegan = false
        swipeRecognizer.delaysTouchesEnded = false
        swipeRecognizer.delegate = self
        rowsStack.addGestureRecognizer(swipeRecognizer)

        swipeTrail.fillColor = nil
        swipeTrail.lineWidth = 9
        swipeTrail.lineCap = .round
        swipeTrail.lineJoin = .round
        swipeTrail.opacity = 0

        SwipeDecoder.shared.warmUp()
        // The user's own vocabulary is swipeable too. Off the main thread: this
        // reads the App Group.
        DispatchQueue.global(qos: .utility).async {
            let words = PersonalDictionary.load().entries.map(\.canonical)
            SwipeDecoder.shared.addUserWords(words)
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === swipeRecognizer else { return true }
        guard plane == .letters, !glide.active else { return false }
        // Only a touch that starts ON a letter key can become a swipe; shift,
        // delete, space and 123 never do. This runs before the key's touch-down,
        // so `shift` and `keyDownSeq` here are the values BEFORE that insert.
        let p = touch.location(in: view)
        guard let key = letterKey(at: p) else { return false }
        glide = GlideState(startKey: key, startPoint: p, shiftAtStart: shift,
                           seqAtStart: keyDownSeq, points: [p], active: false)
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeRecognizer else { return true }
        return plane == .letters && glide.startKey != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Never block the system's own (edge) gestures.
        gestureRecognizer === swipeRecognizer
    }

    // MARK: Gesture

    @objc private func glidePan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: view)
        switch g.state {
        case .began, .changed:
            if let last = glide.points.last, hypot(p.x - last.x, p.y - last.y) < 2 { return }
            if glide.points.count < 1500 { glide.points.append(p) }
            if !glide.active { promoteIfSwiping(at: p) }
            if glide.active {
                // No implicit animation: the trail must follow the finger, not lag it.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                swipeTrail.path = trailPath()
                CATransaction.commit()
            }
        case .ended:
            // The lift point is where the person aimed the last letter; the last
            // .changed sample can sit a few points short of it.
            if glide.active, glide.points.count < 1500 { glide.points.append(p) }
            endGlide(commit: true)
        case .cancelled, .failed:
            // A system gesture took the touch. Commit anyway: never drop a word.
            endGlide(commit: true)
        default:
            break
        }
    }

    /// A touch becomes a swipe once it has travelled about half a key's width AND
    /// reached a different key. A wobble on one key stays a tap; the "different
    /// key" half of the test is what keeps a jittery tap a tap, so the distance
    /// can stay short enough that a two-letter word on neighbouring keys ("we",
    /// "as") still promotes even when the finger starts near the shared edge.
    private func promoteIfSwiping(at p: CGPoint) {
        guard let startKey = glide.startKey else { return }
        let travelled = hypot(p.x - glide.startPoint.x, p.y - glide.startPoint.y)
        guard travelled >= max(14, letterKeyWidth() * 0.45) else { return }
        guard let here = letterKey(at: p, slack: 0) ?? nearestLetterKey(to: p), here !== startKey else { return }
        // Exactly one key-down since this touch began: the letter it inserted. Any
        // other count means another finger typed too, so this cannot be a swipe.
        guard keyDownSeq == glide.seqAtStart &+ 1,
              let tapped = lastKeyDownButton, letterKeys.contains(tapped) else {
            glide.startKey = nil   // give up on this touch; it stays a plain tap
            return
        }
        textDocumentProxy.deleteBackward()
        tapped.backgroundColor = palette.key
        // The key that actually typed the letter is the keyboard's own hit-test
        // (gap-snapping included); make it the start-letter prior's anchor.
        glide.startKey = tapped
        glide.active = true

        // The trail, in the board's ink at low alpha, above everything.
        let ink = palette.keyText.resolvedColor(with: view.traitCollection)
        swipeTrail.strokeColor = ink.withAlphaComponent(0.35).cgColor
        swipeTrail.removeAllAnimations()
        view.layer.addSublayer(swipeTrail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipeTrail.path = trailPath()
        swipeTrail.opacity = 1
        CATransaction.commit()
    }

    /// Finish the current swipe: fade the trail and, if `commit`, decode the path
    /// and insert the word. Safe to call when no swipe is in progress.
    private func endGlide(commit: Bool) {
        let wasActive = glide.active
        let points = glide.points
        let shiftAtStart = glide.shiftAtStart
        // The key the touch-down hit-tested to: what a tap would have typed.
        let startLetter = glide.startKey?.title(for: .normal)?.lowercased().first
        glide = GlideState()
        guard wasActive else { return }
        fadeOutTrail()
        guard commit else { return }
        let centres = letterCentres()
        let keyWidth = letterKeyWidth()
        let previous = previousWordForContext()
        let ranked = SwipeDecoder.shared.decodeRanked(path: points, centers: centres, keyWidth: keyWidth,
                                                      startLetter: startLetter, previousWord: previous)
        logSwipe(points: points, ranked: ranked, startLetter: startLetter, previous: previous,
                 centres: centres, keyWidth: keyWidth)
        guard let word = ranked.first?.word else { return }
        insertSwiped(word, shiftAtStart: shiftAtStart)
    }

    /// Record the swipe in the activity log (Details → Report a problem): the
    /// decoded word and the path, plus the key layout once per session. The
    /// first device test decoded most words wrong while every simulation of the
    /// same decoder scored above 80%, so real paths are the only way to tune it.
    /// A swipe is a rare event, so this write is nowhere near the typing hot path.
    /// The word before the cursor as swipe keys (lowercase letters, apostrophes
    /// dropped), the sentence-start token at the start of a field or after
    /// ". ! ?", or nil when there is nothing usable (a number, say).
    private func previousWordForContext() -> String? {
        guard let before = textDocumentProxy.documentContextBeforeInput else { return SwipeDecoder.sentenceStart }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return SwipeDecoder.sentenceStart }
        if ".!?".contains(last) { return SwipeDecoder.sentenceStart }
        let tail = trimmed.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        let word = String(tail.reversed()).lowercased().filter { $0.isLetter }
        return word.isEmpty ? nil : word
    }

    private func logSwipe(points: [CGPoint], ranked: [SwipeDecoder.Candidate], startLetter: Character?,
                          previous: String?, centres: [Character: CGPoint], keyWidth: CGFloat) {
        if !swipeLayoutLogged {
            swipeLayoutLogged = true
            let layout = centres.keys.sorted().compactMap { ch -> String? in
                guard let c = centres[ch] else { return nil }
                return "\(ch)=\(Int(c.x.rounded())),\(Int(c.y.rounded()))"
            }.joined(separator: " ")
            SharedStore.appendSwipeLog("swipe-layout kw=\(Int(keyWidth.rounded())) \(layout)")
        }
        // The pick, the runners-up with their scores (key widths, lower is
        // better), the key the touch-down typed, and the path (~120 points max).
        let picks = ranked.map { "\($0.word):\(String(format: "%.2f", $0.score))" }.joined(separator: " ")
        let step = max(1, points.count / 120)
        var compact = [String]()
        for (i, p) in points.enumerated() where i % step == 0 || i == points.count - 1 {
            compact.append("\(Int(p.x.rounded())),\(Int(p.y.rounded()))")
        }
        let start = startLetter.map(String.init) ?? "?"
        SharedStore.appendSwipeLog("swipe → \(ranked.first?.word ?? "∅") [\(picks)] start=\(start) prev=\(previous ?? "-") n=\(points.count) \(compact.joined(separator: ";"))")
    }

    /// Insert a swiped word with QuickPath's rules: a leading space unless the
    /// previous character is whitespace or an opener, and capitalised as a tap
    /// would have been (shift as it stood when the touch began), or because the
    /// auto-space just created a sentence start ("Hi." + swipe -> "Hi. There").
    private func insertSwiped(_ word: String, shiftAtStart: Shift) {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput
        var out = word
        var addedSpace = false
        if let last = before?.last, !last.isWhitespace, !"([{\"'“‘/-@#_".contains(last) {
            out = " " + out
            addedSpace = true
        }
        let autoCaps = proxy.autocapitalizationType != UITextAutocapitalizationType.none
        let sentenceStart = addedSpace && autoCaps && ".!?".contains(before?.last ?? " ")
        func capitalised(_ s: String) -> String {
            guard let i = s.firstIndex(where: { !$0.isWhitespace }) else { return s }
            return String(s[..<i]) + String(s[i]).uppercased() + String(s[s.index(after: i)...])
        }
        switch shiftAtStart {
        case .locked: out = out.uppercased()
        case .once:   out = capitalised(out)
        case .off:    if sentenceStart { out = capitalised(out) }
        }
        proxy.insertText(out)
        lastSwipedInsert = out
        lastKeyTime = Date()
        if shift == .once { shift = .off }
    }

    // MARK: Geometry

    private func letterKey(at p: CGPoint, slack: CGFloat = 4) -> UIButton? {
        for key in letterKeys where !key.isHidden {
            if key.convert(key.bounds, to: view).insetBy(dx: -slack, dy: -slack).contains(p) { return key }
        }
        return nil
    }

    private func nearestLetterKey(to p: CGPoint) -> UIButton? {
        var best: UIButton?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for key in letterKeys where !key.isHidden {
            let f = key.convert(key.bounds, to: view)
            let d = hypot(f.midX - p.x, f.midY - p.y)
            if d < bestDistance { bestDistance = d; best = key }
        }
        return best
    }

    private func letterKeyWidth() -> CGFloat {
        guard !letterKeys.isEmpty else { return 0 }
        let total = letterKeys.reduce(CGFloat(0)) { $0 + $1.bounds.width }
        return total / CGFloat(letterKeys.count)
    }

    /// Centre of each a–z key on screen, in the controller view's coordinates.
    private func letterCentres() -> [Character: CGPoint] {
        var out = [Character: CGPoint]()
        for key in letterKeys {
            guard let t = key.title(for: .normal)?.lowercased(), t.count == 1,
                  let ch = t.first, ch.isLetter else { continue }
            let f = key.convert(key.bounds, to: view)
            out[ch] = CGPoint(x: f.midX, y: f.midY)
        }
        return out
    }

    private func trailPath() -> CGPath? {
        guard let first = glide.points.first else { return nil }
        let path = UIBezierPath()
        path.move(to: first)
        for p in glide.points.dropFirst() { path.addLine(to: p) }
        return path.cgPath
    }

    private func fadeOutTrail() {
        // A standalone layer animates opacity implicitly (0.25 s); clear the path
        // once that has finished so the next swipe starts clean.
        swipeTrail.opacity = 0
        let trail = swipeTrail
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.glide.active else { return }
            trail.path = nil
        }
    }
}

import AppKit

/// A floating "I'm listening" overlay, like Wispr Flow's: a frosted pill at the
/// bottom-center of the screen with an animated waveform while you hold the key,
/// and a gentle shimmer while it transcribes. It fades out when done.
///
/// The one hard rule: it must NEVER take focus. It is a non-activating panel that
/// ignores the mouse, so the app you are dictating into keeps key focus and the
/// transcript still lands where your cursor is. Showing it uses
/// `orderFrontRegardless()`, never `makeKey…`.
@MainActor
final class ListeningIndicator {

    private var panel: NSPanel?
    private let waveform = WaveformView()

    /// Bumped on every show. The fade-out completion checks it before ordering
    /// the panel out, because the two fades overlap: dictate, release, and start
    /// again inside the 0.18 s hide animation, and the completion for the OLD
    /// hide would order the panel out from under the NEW recording — leaving you
    /// dictating with no visible indicator. (The dead `hideWorkItem` this
    /// replaces was cancelled in one place and never actually set anywhere.)
    private var showGeneration = 0

    // MARK: - Public API

    func showListening() {
        showGeneration &+= 1
        ensurePanel()
        reposition()
        waveform.mode = .listening
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        fade(to: 1, duration: 0.16)
    }

    func showTranscribing() {
        guard panel != nil else { return }
        waveform.mode = .transcribing
    }

    /// Live mic level, 0...1, from the dictation session.
    func update(level: Float) {
        waveform.targetLevel = CGFloat(max(0, min(1, level)))
    }

    func hide() {
        guard let panel else { return }
        let generation = showGeneration
        fade(to: 0, duration: 0.18) { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            panel.orderOut(nil)
            self.waveform.mode = .idle
        }
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        let size = NSSize(width: 168, height: 52)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]

        // Frosted HUD pill.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = size.height / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        waveform.frame = blur.bounds.insetBy(dx: 26, dy: 16)
        waveform.autoresizingMask = [.width, .height]
        blur.addSubview(waveform)

        p.contentView = blur
        panel = p
    }

    /// Bottom-centre of the active screen, sitting above the Dock.
    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let w = panel.frame.width, h = panel.frame.height
        let x = vf.midX - w / 2
        let y = vf.minY + 96
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, then: (() -> Void)? = nil) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }, completionHandler: then)
    }
}

/// A small waveform of vertical bars. While listening the bars react to the live
/// mic level (with a little per-bar variation so it looks alive even in near
/// silence); while transcribing they run a slow travelling shimmer.
private final class WaveformView: NSView {

    enum Mode { case idle, listening, transcribing }

    var mode: Mode = .idle {
        didSet {
            if mode == .idle { stop() } else { start() }
        }
    }
    var targetLevel: CGFloat = 0

    private let barCount = 5
    private var bars: [CALayer] = []
    private var displayLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildBars()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildBars() {
        for _ in 0..<barCount {
            let l = CALayer()
            l.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            l.cornerRadius = 2
            layer?.addSublayer(l)
            bars.append(l)
        }
    }

    override func layout() {
        super.layout()
        layoutBars()
    }

    private func layoutBars() {
        let barWidth: CGFloat = 4
        let spacing: CGFloat = 6
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        var x = (bounds.width - totalWidth) / 2
        let midY = bounds.height / 2
        let minH: CGFloat = 4
        let maxH = max(minH, bounds.height)

        // Per-bar weighting: taller in the middle, like a real meter.
        let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.85, 0.55]

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // we animate manually at 60fps
        for (i, bar) in bars.enumerated() {
            let w = weights[i % weights.count]
            let amp: CGFloat
            switch mode {
            case .transcribing:
                amp = 0.35 + 0.30 * (sin(phase + CGFloat(i) * 0.9) * 0.5 + 0.5)
            case .listening:
                let idle = 0.12 + 0.06 * (sin(phase * 2 + CGFloat(i)) * 0.5 + 0.5)
                amp = max(idle, displayLevel * w)
            case .idle:
                amp = 0.12
            }
            let h = minH + (maxH - minH) * min(1, amp)
            bar.frame = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }

    // MARK: - Animation loop

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Ease the displayed level toward the target, and boost it a bit so
                // ordinary speech fills the meter.
                let boosted = min(1, self.targetLevel * 6)
                self.displayLevel += (boosted - self.displayLevel) * 0.25
                self.phase += 0.18
                self.layoutBars()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        displayLevel = 0
    }
}

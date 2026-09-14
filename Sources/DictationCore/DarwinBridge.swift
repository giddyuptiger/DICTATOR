import Foundation

/// Cross-process signalling between the keyboard extension and the container app.
///
/// Darwin notifications are the only IPC that reaches a BACKGROUNDED app from an
/// extension. They carry no payload, so they are used purely as doorbells; the
/// actual data moves through the App Group (see SharedStore).
///
/// This is the mechanism that lets the keyboard start a recording WITHOUT
/// switching apps. The container app, kept alive by its audio background mode,
/// hears the notification and starts capturing. No app switch, no bounce.
public enum DarwinSignal: String, CaseIterable, Sendable {
    /// Keyboard → app: begin capturing.
    case startRecording = "design.irons.dictator.start"
    /// Keyboard → app: stop capturing and transcribe.
    case stopRecording  = "design.irons.dictator.stop"
    /// Keyboard → app: retry transcription on the audio kept from a failure.
    case retry          = "design.irons.dictator.retry"
    /// Keyboard → app: are you alive? (cold-start detection)
    case ping           = "design.irons.dictator.ping"
    /// Keyboard → app: I am on screen, open the microphone.
    case keyboardShown  = "design.irons.dictator.kbshown"
    /// Keyboard → app: I am gone, release the microphone.
    case keyboardHidden = "design.irons.dictator.kbhidden"

    /// App → keyboard: I am alive and the engine is warm.
    case pong           = "design.irons.dictator.pong"
    /// App → keyboard: transcript is in the shared store.
    case resultReady    = "design.irons.dictator.result"
    /// App → keyboard: something went wrong, read the error from the store.
    case failed         = "design.irons.dictator.failed"
}

/// `@unchecked Sendable` is accurate rather than a dodge: every mutable member
/// (`handlers`) is guarded by `lock`, and the Darwin callback arrives on an
/// arbitrary thread, so the compiler cannot verify the invariant we are in fact
/// maintaining by hand.
public final class DarwinBridge: @unchecked Sendable {

    public static let shared = DarwinBridge()
    private init() {}

    private var handlers: [String: () -> Void] = [:]
    private let lock = NSLock()

    // MARK: - Posting

    public func post(_ signal: DarwinSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.rawValue as CFString),
            nil, nil, true
        )
    }

    // MARK: - Observing

    /// Handler is invoked on the main queue.
    public func observe(_ signal: DarwinSignal, handler: @escaping () -> Void) {
        lock.lock()
        handlers[signal.rawValue] = handler
        lock.unlock()

        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let bridge = Unmanaged<DarwinBridge>.fromOpaque(observer).takeUnretainedValue()
            bridge.fire(name.rawValue as String)
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            signal.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func fire(_ name: String) {
        lock.lock()
        let handler = handlers[name]
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }

    public func stopObserving() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        lock.lock(); handlers.removeAll(); lock.unlock()
    }
}

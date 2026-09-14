import Cocoa
import CoreGraphics

/// Hold-to-talk on a modifier key.
///
/// The fn / globe key is the one you want, and it is also the awkward one. It never
/// produces keyDown or keyUp events, only `.flagsChanged` with `.maskSecondaryFn`
/// set or cleared. Carbon's RegisterEventHotKey cannot see it at all. So: a
/// CGEventTap, which needs Accessibility permission.
///
/// IMPORTANT, and this will waste an hour if you miss it: macOS claims fn for its
/// own dictation and emoji picker. Set
///   System Settings > Keyboard > "Press 🌐 to" = "Do Nothing"
/// or your tap will fight the system. Right Option is offered as a trigger that
/// nothing else wants.
///
/// Main-actor isolated: the tap's run-loop source is added to the main run loop
/// in start(), so CoreGraphics delivers every callback on the main thread. The
/// callback below asserts that rather than assuming it.
@MainActor
public final class HotkeyMonitor {

    public enum Trigger {
        case fn
        case rightOption
        case rightCommand

        var flag: CGEventFlags {
            switch self {
            case .fn:            return .maskSecondaryFn
            case .rightOption:   return .maskAlternate
            case .rightCommand:  return .maskCommand
            }
        }

        /// Right-hand modifiers share a flag with their left twin, so we
        /// disambiguate on keycode. fn has no keycode.
        var keyCode: CGKeyCode? {
            switch self {
            case .fn:            return nil
            case .rightOption:   return 61
            case .rightCommand:  return 54
            }
        }
    }

    public enum HotkeyError: Error, LocalizedError {
        case accessibilityDenied
        case tapCreationFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is required to watch for the hotkey."
            case .tapCreationFailed:
                return "Could not create the event tap."
            }
        }
    }

    /// Ignore taps shorter than this, so a stray brush of the key does nothing.
    public var minimumHoldDuration: TimeInterval = 0.15

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    /// Fired instead of onRelease when the key was held for less than
    /// `minimumHoldDuration`. A brushed key should discard, not transcribe.
    public var onCancel: (() -> Void)?

    private let trigger: Trigger
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isHeld = false
    private var pressedAt: Date?

    public init(trigger: Trigger = .fn) {
        self.trigger = trigger
    }

    // MARK: - Permission

    /// Prompts once, then returns whether we are trusted. The app must be
    /// re-launched after the user grants it; macOS does not hand it over live.
    @discardableResult
    public static func ensureAccessibility(prompt: Bool = true) -> Bool {
        // kAXTrustedCheckOptionPrompt is a mutable C global, which Swift 6 will
        // not let a Swift function read. Its value is this fixed string.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard Self.ensureAccessibility() else { throw HotkeyError.accessibilityDenied }
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // assumeIsolated can only return Sendable values, and Unmanaged<CGEvent>
            // is not one, so the handler answers a Bool: swallow, or pass through.
            let swallow = MainActor.assumeIsolated {
                monitor.handle(type: type, event: event)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.tap = tap
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        tap = nil
        source = nil
        isHeld = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that takes too long in its callback. Re-arm it,
        // otherwise the hotkey silently dies after a hiccup.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard type == .flagsChanged else { return false }

        let flagIsSet = event.flags.contains(trigger.flag)
        let matchesKey: Bool
        if let expected = trigger.keyCode {
            matchesKey = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == expected
        } else {
            matchesKey = true
        }
        guard matchesKey else { return false }

        if flagIsSet && !isHeld {
            isHeld = true
            pressedAt = Date()
            // Defer the handler so the tap callback returns at once; a slow
            // callback gets the tap disabled by the system.
            Task { @MainActor [weak self] in self?.onPress?() }
            // Swallow it so the host app never sees the modifier.
            return true

        } else if !flagIsSet && isHeld {
            isHeld = false
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            pressedAt = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if held >= self.minimumHoldDuration {
                    self.onRelease?()
                } else {
                    self.onCancel?()
                }
            }
            return true
        }

        return false
    }

    deinit {
        // Only ever released from main-actor state in the app delegate.
        MainActor.assumeIsolated { stop() }
    }
}

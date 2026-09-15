import Cocoa
import ApplicationServices

/// Gets text into whatever has focus.
///
/// Two strategies, because neither works everywhere:
///
///  1. Accessibility API. Clean, instant, leaves the pasteboard alone. Works in
///     native AppKit apps. Fails in most Electron apps and some browsers, which
///     either do not expose kAXSelectedText or ignore writes to it.
///
///  2. Pasteboard plus synthetic Cmd-V. Works essentially everywhere, including
///     Electron. Clobbers the clipboard, so we save and restore it.
///
/// Try 1, fall back to 2. That ordering is what makes it feel native in Mail and
/// still work in Slack.
public struct MacTextInserter {

    public init() {}

    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // Pasteboard + Cmd-V is the universal path. The Accessibility write is
        // cleaner (no clipboard touch) and works in native AppKit apps like
        // Messages, but in Electron/Chromium apps (Claude, Slack, VS Code, Discord)
        // it reports success while inserting nothing — so we never fell back and
        // the text vanished. Pasting works in BOTH, and we save/restore the
        // clipboard so it stays invisible. Reliability beats the clipboard nicety.
        insertViaPasteboard(text)
    }

    /// Bundle ID of the frontmost app, for picking a ToneProfile.
    public static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Strategy 1

    private func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else { return false }

        let target = element as! AXUIElement

        // Only attempt this on things that actually take text. Writing selected text
        // to a non-text element can do surprising things.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard let roleString, textRoles.contains(roleString) else { return false }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }

        let result = AXUIElementSetAttributeValue(
            target,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Strategy 2

    private func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot every representation, not just the string, so copying an image
        // and then dictating does not destroy the image.
        let saved: [(NSPasteboard.PasteboardType, Data)] = pasteboard.types?.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Restore after the paste has been consumed. Electron/Chromium apps
        // process a synthetic paste slower than native ones, and restoring too
        // early puts the old clipboard back before the app has read the new text
        // (the paste then lands as nothing, or the old contents). 350 ms is safe
        // across the slow ones without being noticeable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pasteboard.clearContents()
            for (type, data) in saved {
                pasteboard.setData(data, forType: type)
            }
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Do not let our synthetic keystrokes feed back into our own event tap.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey: CGKeyCode = 9  // "v"

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        // Post at the HID level, as if from the hardware, rather than the annotated
        // session tap. Stubborn Electron apps (Claude's desktop app among them)
        // ignore a session-level synthetic Cmd-V but honour an HID-level one.
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

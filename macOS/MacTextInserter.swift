import Cocoa

/// Gets text into whatever has focus: the pasteboard plus a synthetic Cmd-V,
/// with the clipboard saved and restored around it.
///
/// There WAS a second strategy, writing kAXSelectedText through the
/// Accessibility API, tried first because it leaves the clipboard alone. It is
/// gone. In Electron and Chromium apps (Claude, Slack, VS Code, Discord) that
/// write reports success and inserts nothing, so the fallback never ran and the
/// dictation silently vanished. Pasting works in those apps AND in native ones,
/// so there is one path, and it is the one that always works.
///
/// (The Accessibility code sat here unused and uncalled after that decision,
/// describing behaviour the app no longer had.)
public struct MacTextInserter {

    public init() {}

    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        insertViaPasteboard(text)
    }

    /// Bundle ID of the frontmost app, for picking a ToneProfile.
    public static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Pasteboard insert

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

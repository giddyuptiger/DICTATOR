import SwiftUI
import AppKit
import ServiceManagement

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// Dictator for Mac. Menu bar agent, no Dock icon (LSUIElement in Info.plist).
///
/// Hold the trigger key, talk, release. Text lands where the cursor is.
///
/// Unlike the iOS side, nothing here is sandboxed and nothing is forbidden: the
/// Mac can hold the microphone, run Parakeet on the Neural Engine, and type into
/// any app. This is the half of the product with no platform argument to win.
@main
struct DictatorMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(delegate)
        } label: {
            Image(systemName: delegate.menuIcon)
        }
        Settings {
            SettingsView().environmentObject(delegate)
        }
    }
}

// MARK: - Menu

struct MenuContent: View {
    @EnvironmentObject var app: AppDelegate

    var body: some View {
        Text(app.status)
        if let t = app.lastTiming { Text(t).font(.caption) }
        if !app.lastTranscript.isEmpty {
            Divider()
            Text(app.lastTranscript.prefix(60) + (app.lastTranscript.count > 60 ? "…" : ""))
                .font(.caption)
            Button("Copy last transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.lastTranscript, forType: .string)
            }
        }
        Divider()
        Picker("Mode", selection: Binding(
            get: { app.mode },
            set: { app.mode = $0; DictationMode.current = $0 }
        )) {
            ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Divider()
        Text("Engine: \(app.engineLabel)").font(.caption)
        if app.needsAccessibility {
            Text("Waiting for Accessibility permission").font(.caption).foregroundStyle(.orange)
        }
        Divider()
        Button("Settings…") { app.openSettings() }
        Button("Quit Dictator") { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    @Published var status = "Starting…"
    @Published var lastTiming: String?
    @Published var lastTranscript = ""
    @Published var isRecording = false
    @Published var engineLabel = "loading"
    @Published var needsAccessibility = false
    @Published var mode: DictationMode = DictationMode.current

    private var session: DictationSession?
    private let inserter = MacTextInserter()
    private var hotkey: HotkeyMonitor?
    private var capturedBundleID: String?
    private var accessibilityWatch: Timer?

    var menuIcon: String {
        if isRecording { return "mic.fill" }
        if status.hasPrefix("Ready") { return "mic" }
        return "mic.slash"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await bootstrap() }
    }

    // MARK: - Setup

    private func bootstrap() async {
        guard await AudioRecorder.requestPermission() else {
            status = "Microphone permission denied"
            return
        }

        // Ask for Accessibility before anything depends on it. Without this the
        // first sign of trouble is a CGEventTap that silently refuses to be
        // created, which reads as "the hotkey does nothing" and sends you
        // looking in the wrong place entirely.
        if !AXIsProcessTrusted() {
            needsAccessibility = true
            let prompt = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
            watchForAccessibility()
        }

        let dictionary = PersonalDictionary.mergeFromCloud()
        let key = KeychainStore.groqAPIKey()

        // Local first. Fall back to cloud if the model will not load, so a
        // FluidAudio API change cannot leave you with no working dictation.
        var speech: SpeechProvider = LocalParakeet(tier: .accurate)
        var label = "Parakeet (local)"

        status = "Loading local model…"
        do {
            try await speech.prepare()
        } catch {
            if let key, !key.isEmpty {
                speech = GroqTranscription(apiKey: key, biasTerms: dictionary.entries.map(\.canonical))
                label = "Groq (cloud fallback)"
                status = "Local model unavailable, using cloud"
            } else {
                status = "Local model failed and no API key set. Open Settings."
                engineLabel = "none"
                return
            }
        }
        engineLabel = label

        let session = DictationSession(
            speech: speech,
            cleanupProvider: key.flatMap { $0.isEmpty ? nil : GroqCleanup(apiKey: $0) },
            dictionary: dictionary
        )
        self.session = session

        startHotkey()
    }

    /// macOS grants Accessibility without telling the app, and a CGEventTap
    /// created before the grant stays dead. Polling means the hotkey starts
    /// working the moment permission lands, instead of after a relaunch nobody
    /// knows to perform.
    private func watchForAccessibility() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                self.accessibilityWatch?.invalidate()
                self.accessibilityWatch = nil
                self.needsAccessibility = false
                self.startHotkey()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        accessibilityWatch = t
    }

    private func startHotkey() {
        let trigger: HotkeyMonitor.Trigger = Prefs.useRightOption ? .rightOption : .fn
        let monitor = HotkeyMonitor(trigger: trigger)
        monitor.onPress   = { [weak self] in Task { @MainActor in self?.begin() } }
        monitor.onRelease = { [weak self] in Task { @MainActor in self?.end() } }
        monitor.onCancel  = { [weak self] in Task { @MainActor in self?.cancel() } }

        do {
            try monitor.start()
            hotkey = monitor
            status = "Ready. Hold \(Prefs.useRightOption ? "right ⌥" : "fn") to talk."
        } catch {
            status = "Grant Accessibility permission, then relaunch Dictator."
        }
    }

    // MARK: - Dictation

    private func begin() {
        guard !isRecording, let session else { return }
        capturedBundleID = MacTextInserter.frontmostBundleID
        Task {
            do {
                try await session.start()
                isRecording = true
                Cue.start()
                status = "Listening…"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func cancel() {
        guard let session else { return }
        Task {
            await session.cancel()
            isRecording = false
            status = "Ready."
        }
    }

    private func end() {
        guard isRecording, let session else { return }
        isRecording = false
        Cue.stop()
        status = "Transcribing…"
        let bundleID = capturedBundleID

        Task {
            let profile = ToneProfile.forBundleID(bundleID)
            guard let out = await session.finish(profile: profile) else {
                status = "Ready."
                return
            }
            lastTranscript = out.text
            inserter.insert(out.text)
            lastTiming = String(format: "%.0f ms transcribe · %.0f ms cleanup",
                                out.transcribeTime * 1000, out.cleanupTime * 1000)
            status = "Ready."
        }
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Preferences

enum Prefs {
    private static var d: UserDefaults { .standard }
    static var useRightOption: Bool {
        get { d.bool(forKey: "useRightOption") }
        set { d.set(newValue, forKey: "useRightOption") }
    }
    static var playSounds: Bool {
        get { d.object(forKey: "playSounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSounds") }
    }
}

/// Start and stop cues.
///
/// A hold-to-talk key has no visible affordance: the menu bar icon is the only
/// feedback, and you are usually looking at the app you are dictating into, not
/// at the menu bar. Two short system sounds tell you the microphone opened and
/// closed without stealing your eyes.
enum Cue {
    static func start() { play("Tink") }
    static func stop()  { play("Pop") }
    private static func play(_ name: String) {
        guard Prefs.playSounds else { return }
        NSSound(named: name)?.play()
    }
}

/// Launch at login, via the modern API. The old LaunchAgent plist approach is
/// deprecated and needs a separate helper bundle; this is one call.
enum LoginItem {
    static var enabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("login item: \(error.localizedDescription)")
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppDelegate
    @State private var apiKey = KeychainStore.groqAPIKey() ?? ""
    @State private var rightOption = Prefs.useRightOption
    @State private var saved = false
    @State private var mode = DictationMode.current
    @State private var sounds = Prefs.playSounds
    @State private var launchAtLogin = LoginItem.enabled

    var body: some View {
        Form {
            Section("Trigger key") {
                Picker("Hold to talk", selection: $rightOption) {
                    Text("fn / 🌐").tag(false)
                    Text("Right Option").tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: rightOption) { _, new in Prefs.useRightOption = new }

                Text("If you use fn, set System Settings › Keyboard › \"Press 🌐 to\" to \"Do Nothing\", or macOS will take the key for its own dictation. Relaunch after changing this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup and fallback") {
                SecureField("Groq API key", text: $apiKey)
                Button("Save") {
                    KeychainStore.setGroqAPIKey(apiKey)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                if saved { Text("Saved").font(.caption).foregroundStyle(.green) }
                Text("Optional. Transcription runs locally on this Mac. The key is used for the cleanup pass, and as a fallback if the local model will not load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Picker("Mode", selection: $mode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: mode) { _, new in
                    DictationMode.current = new
                    app.mode = new
                }
                Toggle("Play a sound when recording starts and stops", isOn: $sounds)
                    .onChange(of: sounds) { _, new in Prefs.playSounds = new }
                Toggle("Launch Dictator at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in LoginItem.enabled = new }
            }

            Section("Permissions") {
                Button("Open Accessibility settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
                Text("Required to watch for the trigger key and to type into other apps. macOS does not apply it until Dictator is relaunched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(app.status).font(.caption)
                Text("Engine: \(app.engineLabel)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "design.irons.dictator"
    private static let account = "groq"

    static func groqAPIKey() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setGroqAPIKey(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = key.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

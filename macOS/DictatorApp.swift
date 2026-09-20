import SwiftUI
import AppKit
import AVFoundation
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
            MenuBarLabel().environmentObject(delegate)
        }
        Settings {
            SettingsView().environmentObject(delegate)
        }
    }
}

// MARK: - Menu bar label

/// The menu bar icon, and the one piece of SwiftUI that is ALWAYS on screen.
///
/// That second job is why it is a view instead of a bare `Image`. Opening the
/// Settings scene needs `@Environment(\.openSettings)`, which only exists inside
/// a view — and the AppDelegate has to open Settings on first run. It used to do
/// that with `NSApp.sendAction(Selector(("showSettingsWindow:")))`, which does
/// nothing at all in a menu-bar-only (LSUIElement) app on macOS 14+, so the
/// first-run setup window silently never appeared. The menu's own content view
/// cannot do it either: it only exists while the menu is open. This one always
/// exists, so a request from anywhere in the app can be honoured.
struct MenuBarLabel: View {
    @EnvironmentObject var app: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if app.menuShowsLogo {
                // The brand mark (soundwave + mustache), as a template image so it
                // tints to the menu bar the way an SF Symbol would.
                Image("MenuBarIcon").renderingMode(.template)
            } else {
                // Recording or not-ready: keep the symbol, which carries that state.
                Image(systemName: app.menuIcon)
            }
        }
        .onChange(of: app.settingsRequest) { _, _ in
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

// MARK: - Menu

struct MenuContent: View {
    @EnvironmentObject var app: AppDelegate
    // The reliable way to open a Settings scene from a menu-bar-only (LSUIElement)
    // app on macOS 14+. The old NSApp.sendAction(showSettingsWindow:) selector
    // silently does nothing here, which is why "Settings…" appeared dead.
    @Environment(\.openSettings) private var openSettingsAction

    private func openSettings(_ tab: SettingsTab) {
        app.selectedTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction()
    }

    var body: some View {
        Text(app.status)
        if let t = app.lastTiming { Text(t).font(.caption) }
        if !app.lastTranscript.isEmpty {
            Divider()
            Text(app.lastTranscript.prefix(60) + (app.lastTranscript.count > 60 ? "…" : ""))
                .font(.caption)
            Button("Copy last dictation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.lastTranscript, forType: .string)
            }
        }
        Divider()
        Menu("Mode") {
            ForEach(DictationMode.allCases, id: \.self) { m in
                // A Toggle in a macOS menu renders as a native checkmark item, which
                // shows reliably across macOS versions — unlike a Button whose
                // systemImage the menu may not draw (why his Mac had no checks).
                Toggle(m.displayName, isOn: Binding(
                    get: { app.mode == m },
                    set: { on in
                        if on {
                            app.mode = m
                            DictationMode.current = m
                        }
                    }
                ))
            }
        }
        Button("Vocabulary…") { openSettings(.vocabulary) }
        if app.needsAccessibility {
            Text("Allow Dictator in Accessibility, then click Restart Dictator below.")
                .font(.caption).foregroundStyle(.orange)
        }
        Divider()
        Button("Settings…") { openSettings(.setup) }
        // macOS only hands an Accessibility grant to a freshly launched process, so
        // a one-click restart is the reliable way to make the hotkey start working
        // right after the user allows it.
        Button("Restart Dictator") { app.restart() }
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
    @Published var micGranted = false
    @Published var mode: DictationMode = DictationMode.current
    @Published var selectedTab: SettingsTab = .setup
    /// Bumped to ask MenuBarLabel to open the Settings scene. See MenuBarLabel.
    @Published var settingsRequest = 0

    private var session: DictationSession?
    private let inserter = MacTextInserter()
    private var hotkey: HotkeyMonitor?
    private var capturedBundleID: String?
    private var accessibilityWatch: Timer?
    private let indicator = ListeningIndicator()

    /// The warning symbol shown in place of the logo when a permission is
    /// missing — the one case where the menu bar itself should nag the user.
    var menuIcon: String { "exclamationmark.triangle.fill" }

    /// The brand mark is the menu-bar icon in every normal state (idle,
    /// listening, transcribing) — recording is signalled by the floating green
    /// waveform, not by swapping the icon. We only fall back to a warning symbol
    /// when Dictator literally can't work: microphone or Accessibility denied.
    var menuShowsLogo: Bool { micGranted && !needsAccessibility }

    /// Relaunch the app. macOS activates an Accessibility grant only for a freshly
    /// launched process, so after the user allows Dictator the reliable path is a
    /// restart, not waiting for the running process to notice. One click beats
    /// "quit and reopen."
    func restart() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await bootstrap() }

        // First launch: open the guided Setup tab once the app has settled.
        if !UserDefaults.standard.bool(forKey: "macFirstRunDone") {
            UserDefaults.standard.set(true, forKey: "macFirstRunDone")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings(tab: .setup)
            }
        }
    }

    // MARK: - Setup

    private func bootstrap() async {
        micGranted = await AudioRecorder.requestPermission()
        if !micGranted {
            // Do NOT stop here. Returning early meant a denied microphone also
            // meant no hotkey, no model, and no working Settings window — so the
            // one screen that explains how to fix it was unreachable, and only a
            // relaunch got you out. Set the flag, start watching for the grant,
            // and build everything else as usual.
            watchForMicrophone()
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

        // Feed the live mic level to the floating waveform. The waveform runs its
        // own 60fps animation and just reads this target, so per-buffer work is a
        // single assignment.
        await session.setOnLevel { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.indicator.update(level: level) }
            }
        }

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

    /// macOS grants the microphone without telling the app, exactly as it does
    /// with Accessibility. Poll so the status line corrects itself when the user
    /// comes back from System Settings, rather than lying until the next launch.
    private var micWatch: Timer?

    private func watchForMicrophone() {
        guard micWatch == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
                self.micWatch?.invalidate()
                self.micWatch = nil
                self.micGranted = true
                if self.hotkey != nil { self.status = self.readyStatus }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        micWatch = t
    }

    private var readyStatus: String {
        guard micGranted else { return "Microphone is off. Allow it in System Settings." }
        return "Ready. Hold \(Prefs.useRightOption ? "right ⌥" : "fn") to talk."
    }

    /// Rebuild the event tap, e.g. after the trigger key changes.
    func restartHotkey() { startHotkey() }

    private func startHotkey() {
        // Tear the old tap down first. bootstrap() and the Accessibility watcher
        // can both reach here, and replacing `hotkey` without stopping it left
        // the previous CGEventTap installed and listening — two taps, two
        // onPress calls, one keypress.
        hotkey?.stop()
        hotkey = nil

        let trigger: HotkeyMonitor.Trigger = Prefs.useRightOption ? .rightOption : .fn
        let monitor = HotkeyMonitor(trigger: trigger)
        monitor.onPress   = { [weak self] in Task { @MainActor in self?.begin() } }
        monitor.onRelease = { [weak self] in Task { @MainActor in self?.end() } }
        monitor.onCancel  = { [weak self] in Task { @MainActor in self?.cancel() } }

        do {
            try monitor.start()
            hotkey = monitor
            status = readyStatus
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
                indicator.showListening()
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
            indicator.hide()
            status = readyStatus
        }
    }

    private func end() {
        guard isRecording, let session else { return }
        isRecording = false
        Cue.stop()
        indicator.showTranscribing()
        status = "Transcribing…"
        let bundleID = capturedBundleID

        Task {
            let profile = ToneProfile.forBundleID(bundleID)
            guard let out = await session.finish(profile: profile) else {
                indicator.hide()
                status = readyStatus
                return
            }
            lastTranscript = out.text
            // Pasting uses a synthetic Cmd-V, which needs Accessibility. Reinstalling
            // or moving the app commonly resets that grant, and the paste then fails
            // SILENTLY — worse, MacTextInserter restores the clipboard afterward, so
            // the dictation vanishes with no explanation (exactly the "animation shows
            // but nothing pastes" report). Guard it: only auto-paste when trusted;
            // otherwise leave the text on the clipboard (so it's never lost) and tell
            // the user how to fix it.
            if AXIsProcessTrusted() {
                inserter.insert(out.text)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(out.text, forType: .string)
                needsAccessibility = true
                watchForAccessibility()
                status = "Allow Dictator in Accessibility, then Restart Dictator. Your text is on the clipboard — press ⌘V to paste it."
                indicator.hide()
                return
            }
            lastTiming = String(format: "%.0f ms transcribe · %.0f ms cleanup",
                                out.transcribeTime * 1000, out.cleanupTime * 1000)
            indicator.hide()
            status = readyStatus
        }
    }

    func showSettings(tab: SettingsTab) {
        selectedTab = tab
        settingsRequest += 1
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

enum SettingsTab: String {
    case setup, general, writing, vocabulary, groq, status
}

struct SettingsView: View {
    @EnvironmentObject var app: AppDelegate

    var body: some View {
        TabView(selection: Binding(
            get: { app.selectedTab },
            set: { app.selectedTab = $0 }
        )) {
            SetupTab()
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag(SettingsTab.setup)
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            WritingTab()
                .tabItem { Label("Writing", systemImage: "text.alignleft") }
                .tag(SettingsTab.writing)
            VocabularyTab()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag(SettingsTab.vocabulary)
            GroqTab()
                .tabItem { Label("Groq", systemImage: "key") }
                .tag(SettingsTab.groq)
            StatusTab()
                .tabItem { Label("Status", systemImage: "info.circle") }
                .tag(SettingsTab.status)
        }
        .frame(width: 500, height: 440)
    }
}

// MARK: - Setup tab (first-run guide)

private struct SetupRow: View {
    let done: Bool
    let showCheck: Bool
    let title: String
    let detail: String
    let buttonTitle: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if showCheck {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? .green : .secondary)
                }
                Text(title).font(.headline)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle) {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
        .padding(.vertical, 3)
    }
}

struct SetupTab: View {
    @EnvironmentObject var app: AppDelegate

    var body: some View {
        Form {
            Section("Get Dictator working") {
                SetupRow(
                    done: app.micGranted, showCheck: true,
                    title: "Microphone",
                    detail: "Allow the microphone so Dictator can hear you.",
                    buttonTitle: "Open Microphone settings",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                SetupRow(
                    done: !app.needsAccessibility, showCheck: true,
                    title: "Accessibility",
                    detail: "Lets Dictator watch for the hold-to-talk key and type into other apps. It starts working when you come back; no relaunch needed.",
                    buttonTitle: "Open Accessibility settings",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                SetupRow(
                    done: false, showCheck: false,
                    title: "The fn key",
                    detail: "Set System Settings › Keyboard › \"Press 🌐 to\" to Do Nothing, or macOS takes the key for its own dictation. Or pick Right Option in General.",
                    buttonTitle: "Open Keyboard settings",
                    url: "x-apple.systempreferences:com.apple.preference.keyboard"
                )
            }
            Section("Engine") {
                Text(app.status).font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @EnvironmentObject var app: AppDelegate
    @State private var rightOption = Prefs.useRightOption
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
                .onChange(of: rightOption) { _, new in
                    Prefs.useRightOption = new
                    // Rebuild the tap now. This used to need a relaunch, which is
                    // a lot to ask for flipping a radio button.
                    app.restartHotkey()
                }

                Text("If you use fn, set System Settings › Keyboard › \"Press 🌐 to\" to \"Do Nothing\", or macOS will take the key for its own dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Keyboard settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }

            Section("Behaviour") {
                Toggle("Play a sound when recording starts and stops", isOn: $sounds)
                    .onChange(of: sounds) { _, new in Prefs.playSounds = new }
                Toggle("Launch Dictator at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in LoginItem.enabled = new }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Writing tab

struct WritingTab: View {
    @EnvironmentObject var app: AppDelegate
    @State private var mode = DictationMode.current

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Mode", selection: $mode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: mode) { _, new in
                    DictationMode.current = new
                    app.mode = new
                }
            }

            Section("Tone profiles") {
                Text("Dictator matches how it writes to where your cursor is. You can read exactly what it tells the cleanup model, which a closed tool never shows you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ToneProfile.defaults) { p in
                    DisclosureGroup(p.name) {
                        if !p.bundleIDs.isEmpty {
                            Text("Apps: " + p.bundleIDs.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(p.instructions)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Vocabulary tab

struct VocabularyTab: View {
    var body: some View {
        MacVocabularyView()
            .padding()
    }
}

// MARK: - Groq tab

struct GroqTab: View {
    @State private var apiKey = KeychainStore.groqAPIKey() ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Groq API key") {
                SecureField("gsk_…", text: $apiKey)
                Button("Save") {
                    KeychainStore.setGroqAPIKey(apiKey)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                if saved { Text("Saved").font(.caption).foregroundStyle(.green) }
                Text("Optional. Transcription runs locally on this Mac. The key is used for the cleanup pass, and as a fallback if the local model will not load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Without a key, Dictator inserts what it heard, with your vocabulary applied and no cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get a key", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Status tab

struct StatusTab: View {
    @EnvironmentObject var app: AppDelegate

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State", value: app.status)
                LabeledContent("Engine", value: app.engineLabel)
                if let t = app.lastTiming { LabeledContent("Last", value: t) }
                LabeledContent("Microphone", value: app.micGranted ? "Allowed" : "Not allowed")
                LabeledContent("Accessibility", value: app.needsAccessibility ? "Waiting" : "Granted")
            }
        }
        .formStyle(.grouped)
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

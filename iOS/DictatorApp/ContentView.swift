import SwiftUI
import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

@main
struct DictatorApp: App {
    @StateObject private var recorder = BackgroundRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .task {
                    seedAPIKeyIfNeeded()
                    // Warming has to happen while foregrounded. This is the
                    // moment iOS grants the audio IO the background mode keeps.
                    await recorder.warmUp()
                }
                .onOpenURL { url in
                    // dictator://dictate — the keyboard's cold-start fallback.
                    if url.host == "dictate" { recorder.beginCapture() }
                }
        }
    }

    /// Writes the build-time key into the App Group once, so neither this app nor
    /// the keyboard extension needs it typed on a phone. Anything saved in
    /// settings wins, because this only fires when the stored value is empty.
    ///
    /// The key itself lives in Secrets.swift, which is gitignored locally and
    /// written from an environment variable by ci_scripts/ci_post_clone.sh on
    /// Xcode Cloud. It is never in the repository.
    private func seedAPIKeyIfNeeded() {
        guard (SharedStore.groqAPIKey ?? "").isEmpty else { return }
        guard !BuildSecrets.groqAPIKey.isEmpty else { return }
        SharedStore.groqAPIKey = BuildSecrets.groqAPIKey
    }
}

struct ContentView: View {
    @EnvironmentObject private var recorder: BackgroundRecorder
    @State private var apiKey: String = ""
    @State private var savedFlash = false
    @State private var showKeyField = false
    @State private var selectedMode: DictationMode = DictationMode.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statusCard

                    if recorder.state == .cold {
                        Button("Start dictation session") {
                            recorder.note("button tapped")
                            Task { await recorder.warmUp() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }

                    modeSection
                    keySection
                    setupSection

                    if !recorder.lastTranscript.isEmpty {
                        section("Last transcript") {
                            Text(recorder.lastTranscript)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }

                    section("Activity") {
                        HStack {
                            Button("Refresh") { recorder.reloadLog() }.font(.caption)
                            Spacer()
                            Button("Clear") { recorder.clearLog() }.font(.caption)
                        }
                        if recorder.eventLog.isEmpty {
                            Text("nothing yet").foregroundStyle(.secondary).font(.caption)
                        } else {
                            ForEach(recorder.eventLog, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if recorder.state != .cold {
                        Button("Stop session and release microphone", role: .destructive) {
                            recorder.shutDown()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }

                    Text(Self.versionLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("Dictator")
            .onAppear {
                // The log now outlives the process, so re-read it every time the
                // app comes forward. This is the record of what happened while
                // you were in another app, which is the only place it matters.
                recorder.reloadLog()
                selectedMode = DictationMode.current   // the keyboard may have changed it
                // Read AFTER the app's .task has seeded the App Group, otherwise
                // the field reads empty on first launch and looks broken.
                let stored = SharedStore.groqAPIKey ?? ""
                apiKey = stored
                showKeyField = stored.isEmpty
            }
        }
    }

    // MARK: - Pieces

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                Text(statusText).font(.headline)
            }
            if recorder.state == .capturing {
                ProgressView(value: Double(min(recorder.level * 6, 1)))
                    .tint(.red)
            }
            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var dotColor: Color {
        switch recorder.state {
        case .cold: return .gray
        case .warm: return .green
        case .capturing: return .red
        case .transcribing: return .orange
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .cold: return "Session off"
        case .warm: return "Ready"
        case .capturing: return "Listening"
        case .transcribing: return "Transcribing"
        case .failed(let e): return "Problem: \(e)"
        }
    }

    private var statusDetail: String {
        switch recorder.state {
        case .cold:
            return "Start a session to use the Dictator keyboard in other apps."
        case .failed:
            return "Check Settings › Privacy › Microphone."
        default:
            return "The microphone stays open while the session runs, so the keyboard can record without switching back here. That is why the orange dot is lit. Stop the session to release it."
        }
    }

    private var modeSection: some View {
        section("Mode") {
            Picker("Mode", selection: $selectedMode) {
                ForEach(DictationMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedMode) { _, new in DictationMode.current = new }
            Text(modeBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBlurb: String {
        switch selectedMode {
        case .superCasual: return "Lowercase, contractions, barely any punctuation. How you text."
        case .casual:      return "Normal writing. Sentence case, ordinary punctuation."
        case .formal:      return "Complete sentences, no contractions. Disciplined, not inflated."
        case .emoji:       return "Casual, plus exactly one emoji per message."
        }
    }

    /// Collapsed once a key is present. It stays reachable because rotating a key
    /// should not require a rebuild, but it is not the first thing you should see
    /// on an app that is already working.
    @ViewBuilder
    private var keySection: some View {
        if showKeyField {
            expandedKeySection
        } else {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Groq key set").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Change") { showKeyField = true }
                    .font(.caption)
            }
        }
    }

    private var expandedKeySection: some View {
        section("Groq API key") {
            SecureField("gsk_…", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    SharedStore.groqAPIKey = apiKey
                    savedFlash = true
                    showKeyField = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFlash = false }
                }
                .disabled(apiKey.isEmpty)
                .buttonStyle(.bordered)
                if savedFlash {
                    Text("saved").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Link("Get a key", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }
        }
    }

    private var setupSection: some View {
        section("Keyboard setup") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Settings › General › Keyboard › Keyboards")
                Text("2. Add New Keyboard › Dictator")
                Text("3. Tap Dictator, turn on Allow Full Access")
            }
            .font(.callout)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    /// "0.1.4 (3)": the version we ratchet by hand and the build Xcode Cloud
    /// assigns. Here so "which build is this?" is answered without TestFlight.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

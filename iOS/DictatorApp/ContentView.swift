import SwiftUI
import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

@main
struct DictatorApp: App {
    @StateObject private var recorder = BackgroundRecorder()
    @StateObject private var dictionary = DictionaryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(dictionary)
                .task {
                    seedAPIKeyIfNeeded()
                    // Warm-up is triggered from ContentView once onboarding is
                    // done, so the mic prompt does not fire over the onboarding's
                    // own explained microphone step.
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
    @EnvironmentObject private var dictionary: DictionaryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedMode: DictationMode = DictationMode.current

    @State private var showOnboarding = false
    @State private var onboardingStart = 1
    @State private var showCorrection = false

    // Live setup checklist, refreshed on appear and when the app returns.
    @State private var keyDone = false
    @State private var keyboardAdded = false
    @State private var fullAccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statusCard
                    turnButton
                    modeSection
                    vocabularySection
                    lastDictationSection
                    setupSection
                    detailsLink

                    Text(Self.versionLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("Dictator")
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(startStep: onboardingStart) {
                showOnboarding = false
                refreshChecklist()
                // Now that the mic step has been shown, warm the engine up.
                Task { await recorder.warmUp() }
            }
        }
        .sheet(isPresented: $showCorrection) {
            CorrectionSheet(store: dictionary)
        }
        .task {
            selectedMode = DictationMode.current
            refreshChecklist()
            dictionary.reload()
            if SharedStore.onboardingDone {
                // Warming has to happen while foregrounded. This is the moment
                // iOS grants the audio IO the background mode keeps.
                await recorder.warmUp()
            } else {
                // First run: walk the user through setup, then warm up.
                onboardingStart = 1
                showOnboarding = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                recorder.isForeground = true
                refreshChecklist()
                selectedMode = DictationMode.current
                recorder.reloadLog()
                // The engine may have died while we were away (iOS suspended it,
                // an interruption, low memory). Returning to the app used to do
                // nothing because state was still "warm"; now we rebuild if it is
                // actually dead. This is the fix for "it says wake and only a
                // force-quit revives it".
                if SharedStore.onboardingDone {
                    Task { await recorder.resync() }
                }
            case .background, .inactive:
                recorder.isForeground = false
            @unknown default:
                break
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                Text(statusHeadline).font(.headline)
                Spacer()
                Text(micLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if recorder.state == .capturing {
                ProgressView(value: Double(min(recorder.level * 6, 1)))
                    .tint(Self.pastelRed)
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

    // Soft, muted accents instead of the saturated system colours, to match the
    // keyboard's pastel pills. Still saturated enough to read as a 12pt status dot.
    static let pastelGreen = Color(red: 0.36, green: 0.66, blue: 0.45) // sage
    static let pastelRed   = Color(red: 0.85, green: 0.47, blue: 0.44) // soft rose
    static let pastelAmber = Color(red: 0.87, green: 0.66, blue: 0.36) // soft amber

    private var dotColor: Color {
        switch recorder.state {
        case .cold: return .gray
        case .warm: return Self.pastelGreen
        case .capturing: return Self.pastelRed
        case .transcribing: return Self.pastelAmber
        case .failed: return Self.pastelRed
        }
    }

    private var statusHeadline: String {
        switch recorder.state {
        case .cold: return "Dictator is off"
        case .warm: return "Dictator is ready"
        case .capturing: return "Listening"
        case .transcribing: return "Transcribing"
        case .failed(let e): return e.contains("denied") ? "Microphone is off in Settings" : "Couldn't turn on"
        }
    }

    /// The honest mic-state line. While Dictator is on, the microphone is open
    /// the whole time, because that is the only way the keyboard can dictate from
    /// another app. It is closed only when Dictator is off.
    private var micLine: String {
        switch recorder.state {
        case .cold, .failed: return ""
        default: return "Microphone on"
        }
    }

    private var statusDetail: String {
        switch recorder.state {
        case .cold:
            return "Turn Dictator on to use its keyboard in other apps."
        case .failed(let e):
            return e.contains("denied") ? "Turn the microphone on in Settings, then come back." : e
        default:
            return "Dictator keeps the microphone open while it's on, so the keyboard can dictate from any app. The orange dot shows it. Turn Dictator off to close the microphone."
        }
    }

    @ViewBuilder
    private var turnButton: some View {
        switch recorder.state {
        case .cold:
            Button("Turn on") {
                recorder.note("turn on tapped")
                Task { await recorder.warmUp() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        case .failed:
            // A failed warm-up is recoverable, not a dead end: always offer a
            // retry. CannotInterruptOthers clears once another app releases audio.
            Button("Try again") {
                Task { await recorder.retryWarmUp() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        default:
            Button("Turn off", role: .destructive) {
                recorder.shutDown()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Mode

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
        case .expressive:  return "Casual, with ! and … where the feeling calls for it."
        case .emoji:       return "Casual, plus one emoji placed where it fits best."
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        section("Vocabulary") {
            NavigationLink {
                VocabularyView(store: dictionary)
            } label: {
                HStack {
                    Text(vocabCountLine)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Text("Names and terms Dictator should spell your way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vocabCountLine: String {
        let n = dictionary.entries.count
        if n == 0 { return "Add your first word" }
        return n == 1 ? "1 word" : "\(n) words"
    }

    // MARK: - Last dictation

    @ViewBuilder
    private var lastDictationSection: some View {
        if !recorder.lastTranscript.isEmpty {
            section(recorder.lastWasRecovered ? "Recovered dictation" : "Last dictation") {
                if recorder.lastWasRecovered {
                    Label("Recovered from a dictation that didn't finish last time.",
                          systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(recorder.lastTranscript)
                    .font(.callout)
                    .textSelection(.enabled)
                HStack {
                    Button {
                        UIPasteboard.general.string = recorder.lastTranscript
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .font(.caption)
                    Spacer()
                    Button {
                        showCorrection = true
                    } label: { Label("Fix a word", systemImage: "character.cursor.ibeam") }
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Setup checklist

    private var setupSection: some View {
        section("Setup") {
            checklistRow(done: keyDone, title: "Groq key added", step: 1)
            checklistRow(done: keyboardAdded, title: "Dictator keyboard added", step: 2)
            checklistRow(done: fullAccess, title: "Full Access on", step: 3)
        }
    }

    private func checklistRow(done: Bool, title: String, step: Int) -> some View {
        Button {
            onboardingStart = step
            showOnboarding = true
        } label: {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Self.pastelGreen : .secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
                if !done {
                    Text("Set up").font(.caption).foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func refreshChecklist() {
        keyDone = !(SharedStore.groqAPIKey ?? "").isEmpty
        let installed = (UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String]) ?? []
        keyboardAdded = installed.contains { $0.hasPrefix("design.irons.dictator.keyboard") }
        // The keyboard can only write to the App Group with Full Access, so a
        // stamp there is proof it was granted.
        fullAccess = SharedStore.keyboardEverSeen
    }

    // MARK: - Details

    private var detailsLink: some View {
        NavigationLink {
            DetailsView(recorder: recorder)
        } label: {
            HStack {
                Text("Details").foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// "0.1.5 (3)": the version we ratchet by hand and the build Xcode Cloud
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

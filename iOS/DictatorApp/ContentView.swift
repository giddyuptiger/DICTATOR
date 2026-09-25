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
                    installCrashLogger()
                    // The Groq key now lives on the backend, not in the app. Clear
                    // any previously-seeded embedded key once so existing installs
                    // route through the proxy.
                    SharedStore.migrateKeyToBackendIfNeeded()
                    // Undo 0.1.60's forced 1-minute mic-hold once; Dictator no
                    // longer touches music, so the short window isn't needed.
                    SharedStore.migrateMusicHoldIfNeeded()
                    // Warm-up is triggered from ContentView once onboarding is
                    // done, so the mic prompt does not fire over the onboarding's
                    // own explained microphone step.
                }
                .onOpenURL { url in
                    // dictator://dictate — the keyboard woke a sleeping app. Only
                    // WARM (do not record here): the user wants to dictate in their
                    // other app. Warming makes Dictator resident so the keyboard
                    // reaches it in place from now on, and the banner tells the
                    // user to go back once.
                    if url.host == "dictate" {
                        Task { await recorder.warmForWake() }
                    }
                }
        }
    }

}

/// Record the reason for any uncaught Objective-C exception into the shared
/// activity log before the app dies, so a crash is diagnosable from Details →
/// Report a problem instead of guessed at. This catches the AVAudioEngine family
/// of crashes ("required condition is false: …"), which are NSExceptions. (Pure
/// Swift traps / signals are not catchable this way, but the audio crashes we
/// care about are.) The closure captures nothing, so it is a valid C handler.
private func installCrashLogger() {
    NSSetUncaughtExceptionHandler { exception in
        let name = exception.name.rawValue
        let reason = exception.reason ?? "unknown"
        let frames = exception.callStackSymbols.prefix(6).joined(separator: " | ")
        SharedStore.appendLog("CRASH \(name): \(reason)")
        SharedStore.appendLog("CRASH stack: \(frames)")
    }
}

// MARK: - Root

/// Three tabs, not a scroll of setting cards:
///  • Home     — the live status hero + a real tap-to-dictate scratchpad + recent.
///  • Style    — the five writing registers, each shown with a worked example.
///  • Settings — engine, mic hold, setup, diagnostics, about.
/// The whole thing is wrapped in a ZStack so the full-screen wake screen (shown
/// when the keyboard wakes a sleeping app) can cover the tabs entirely.
struct ContentView: View {
    @EnvironmentObject private var recorder: BackgroundRecorder
    @EnvironmentObject private var dictionary: DictionaryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = 0
    @State private var selectedMode: DictationMode = DictationMode.current

    @State private var showOnboarding = false
    @State private var onboardingStart = 1
    @State private var showCorrection = false

    @State private var idleMinutes = SharedStore.idleReleaseMinutes
    @State private var engine: TranscriptionEngine = SharedStore.transcriptionEngine
    @State private var swipeTyping = SharedStore.swipeTypingEnabled

    // Live setup checklist, refreshed on appear and when the app returns.
    @State private var keyboardAdded = false
    @State private var fullAccess = false

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                homeTab
                    .tabItem { Label("Home", systemImage: "waveform") }
                    .tag(0)
                styleTab
                    .tabItem { Label("Style", systemImage: "textformat.alt") }
                    .tag(1)
                settingsTab
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(2)
            }
            .tint(Self.brandGreenDeep)

            // Full-screen wake screen. When the keyboard wakes the app to make it
            // resident (dictator://dictate), we don't want to dump the user into
            // the settings UI — they want to get back to their app and dictate. So
            // we cover everything with a calm screen pointing at the home-swipe.
            if recorder.wokeForDictation {
                WakeScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }
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
            SharedStore.migrateMusicHoldIfNeeded()   // idempotent; ensures the picker shows the corrected value
            idleMinutes = SharedStore.idleReleaseMinutes
            engine = SharedStore.transcriptionEngine
            swipeTyping = SharedStore.swipeTypingEnabled
            refreshChecklist()
            dictionary.reload()
            if !SharedStore.onboardingDone {
                // First run: walk the user through setup.
                onboardingStart = 1
                showOnboarding = true
            }
            // Deliberately DO NOT warm the mic just because the app is open. An
            // active record session makes iOS turn other audio (music, video, calls)
            // down the whole time — the "my volume is low while Dictator is open"
            // bug. The mic warms only when it's actually needed: the keyboard wakes
            // it via the wake flow (onOpenURL), and the in-app mic warms on tap.
            recorder.releaseForForegroundIdle()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                recorder.isForeground = true
                refreshChecklist()
                selectedMode = DictationMode.current
                recorder.reloadLog()
                // Coming back to the app should NOT leave the mic hot (that ducks
                // other audio). Release it unless we were woken specifically to
                // dictate or are mid-capture. The keyboard re-warms on demand.
                recorder.releaseForForegroundIdle()
            case .inactive:
                // NOT "we have left". .inactive fires for a notification banner, a
                // Control Centre pull-down, the app switcher, and the system
                // permission alert — all while we are still on screen. Only
                // .background means the user has actually left.
                break
            case .background:
                recorder.isForeground = false
                recorder.wokeForDictation = false
            @unknown default:
                break
            }
        }
        .animation(.easeInOut(duration: 0.25), value: recorder.wokeForDictation)
    }

    // MARK: - Home tab

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    heroCard
                    if showSetupPrompt { finishSetupCard }
                    lastDictationSection
                    howToCard
                }
                .padding()
                .padding(.bottom, 24)
            }
            .navigationTitle("Dictator")
        }
    }

    /// The centrepiece: a big status dial that is also the record button, plus a
    /// one-line status. Tapping it does the obvious next thing for the current
    /// state — turn on, dictate, stop, or retry — so the home screen actually
    /// *does* something instead of only describing settings.
    private var heroCard: some View {
        VStack(spacing: 18) {
            micDial

            VStack(spacing: 6) {
                Text(statusHeadline)
                    .font(.title2.bold())
                Text(heroSub)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }

            heroControlRow
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [dialGlow.opacity(0.14), .clear],
                                startPoint: .top, endPoint: .center
                            )
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var micDial: some View {
        Button(action: micDialTapped) {
            ZStack {
                // A soft ring that swells with the mic level while recording, so
                // the dial visibly reacts to your voice.
                if recorder.state == .capturing {
                    Circle()
                        .stroke(Self.pastelRed.opacity(0.35), lineWidth: 7)
                        .frame(width: 150, height: 150)
                        .scaleEffect(1 + CGFloat(min(recorder.level * 6, 1)) * 0.16)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                }
                Circle()
                    .fill(dialFill)
                    .frame(width: 140, height: 140)
                    .shadow(color: dialGlow.opacity(0.45), radius: 18, y: 7)
                dialIcon
            }
            .frame(width: 168, height: 168)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .transcribing)
        .accessibilityLabel(dialAccessibilityLabel)
    }

    @ViewBuilder
    private var dialIcon: some View {
        switch recorder.state {
        case .cold:
            Image(systemName: "power")
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.white)
        case .warm:
            Image(systemName: "mic.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
        case .capturing:
            Image(systemName: "stop.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
        case .transcribing:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var dialFill: LinearGradient {
        switch recorder.state {
        case .warm:
            return Self.brandGradient
        case .capturing:
            return LinearGradient(colors: [Self.pastelRed, Color(red: 0.72, green: 0.28, blue: 0.28)],
                                  startPoint: .top, endPoint: .bottom)
        case .transcribing:
            return LinearGradient(colors: [Self.pastelAmber, Color(red: 0.86, green: 0.52, blue: 0.18)],
                                  startPoint: .top, endPoint: .bottom)
        case .failed:
            return LinearGradient(colors: [Self.pastelRed, Color(red: 0.72, green: 0.28, blue: 0.28)],
                                  startPoint: .top, endPoint: .bottom)
        case .cold:
            return LinearGradient(colors: [Color(.systemGray2), Color(.systemGray3)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    private var dialGlow: Color {
        switch recorder.state {
        case .warm: return Self.brandGreen
        case .capturing, .failed: return Self.pastelRed
        case .transcribing: return Self.pastelAmber
        case .cold: return .gray
        }
    }

    private func micDialTapped() {
        switch recorder.state {
        case .cold:
            recorder.note("turn on tapped (dial)")
            Task { await recorder.warmUp() }
        case .warm:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            recorder.beginCapture()
        case .capturing:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            recorder.endCapture()
        case .transcribing:
            break
        case .failed:
            Task { await recorder.retryWarmUp() }
        }
    }

    private var dialAccessibilityLabel: String {
        switch recorder.state {
        case .cold: return "Turn Dictator on"
        case .warm: return "Dictate"
        case .capturing: return "Stop dictating"
        case .transcribing: return "Transcribing"
        case .failed: return "Try again"
        }
    }

    /// A quiet secondary control under the dial: turn Dictator off once it's on,
    /// so leaving the mic open is never a trap.
    @ViewBuilder
    private var heroControlRow: some View {
        switch recorder.state {
        case .warm, .capturing:
            Button {
                if recorder.state == .capturing { recorder.endCapture() }
                recorder.shutDown()
            } label: {
                Label("Turn off", systemImage: "power")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        case .failed:
            Button("Try again") { Task { await recorder.retryWarmUp() } }
                .buttonStyle(.borderedProminent)
                .tint(Self.brandGreenDeep)
        default:
            EmptyView()
        }
    }

    private var heroSub: String {
        switch recorder.state {
        case .cold:
            return "Tap to turn on. Then dictate right here, or from the Dictator keyboard in any app."
        case .warm:
            return "Tap the mic to dictate here — or open any app, switch to the Dictator keyboard, and talk."
        case .capturing:
            return "Listening… tap to stop. Dictator records over your music, never turning it down."
        case .transcribing:
            return "Turning your speech into clean text…"
        case .failed(let e):
            return e.contains("denied")
                ? "Turn the microphone on in Settings, then come back."
                : e
        }
    }

    private var statusHeadline: String {
        switch recorder.state {
        case .cold: return "Dictator is off"
        case .warm: return "Ready to dictate"
        case .capturing: return "Listening"
        case .transcribing: return "Transcribing"
        case .failed(let e): return e.contains("denied") ? "Microphone is off" : "Couldn't turn on"
        }
    }

    // MARK: - Home: finish-setup nudge (only until setup is complete)

    private var showSetupPrompt: Bool { !(keyboardAdded && fullAccess) }

    private var finishSetupCard: some View {
        Button {
            onboardingStart = keyboardAdded ? 2 : 1
            showOnboarding = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Self.brandGreenDeep)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Finish setting up")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(keyboardAdded
                         ? "Turn on Full Access so the keyboard can dictate."
                         : "Add the Dictator keyboard to use it in other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Self.brandGreen.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Home: recent dictation

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        UIPasteboard.general.string = recorder.lastTranscript
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    // MARK: - Home: how to use it elsewhere

    private var howToCard: some View {
        section("Use Dictator anywhere") {
            howToRow(1, "mic.fill", "Dictate here", "Tap the mic above to turn speech into text in this app.")
            Divider().opacity(0.4)
            howToRow(2, "globe", "Or in any app", "Tap the 🌐 globe on any keyboard and pick Dictator.")
            Divider().opacity(0.4)
            howToRow(3, "text.bubble", "Then just talk", "Tap the Dictator mic and speak. Clean text lands where your cursor is.")
        }
    }

    private func howToRow(_ n: Int, _ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Self.brandGreenDeep)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Style tab

    private var styleTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How Dictator writes")
                            .font(.headline)
                        Text("Pick the register. Dictator formats every dictation this way — from how you text to fully formal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 12) {
                        ForEach(DictationMode.allCases, id: \.self) { mode in
                            styleCard(mode)
                        }
                    }

                    vocabularyCard
                }
                .padding()
                .padding(.bottom, 24)
            }
            .navigationTitle("Style")
        }
    }

    private func styleCard(_ mode: DictationMode) -> some View {
        let selected = selectedMode == mode
        return Button {
            selectedMode = mode
            DictationMode.current = mode
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(mode.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Self.brandGreenDeep : Color(.systemGray3))
                }
                Text(modeBlurb(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(styleExample(mode))
                    .font(.callout.italic())
                    .foregroundStyle(selected ? Self.brandGreenDeep : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Self.brandGreen : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func modeBlurb(_ mode: DictationMode) -> String {
        switch mode {
        case .superCasual: return "Lowercase, contractions, barely any punctuation. How you text."
        case .casual:      return "Normal writing. Sentence case, ordinary punctuation."
        case .formal:      return "Complete sentences, no contractions. Disciplined, not inflated."
        case .expressive:  return "Casual, with ! and … where the feeling calls for it."
        case .emoji:       return "Casual, plus one emoji placed where it fits best."
        case .patois:      return "Rewrites what you said in Jamaican Patois."
        case .shakespearean: return "Rewrites what you said in Shakespearean English."
        }
    }

    private func styleExample(_ mode: DictationMode) -> String {
        switch mode {
        case .superCasual: return "hey u around? wanna grab food later"
        case .casual:      return "Hey, are you around? Want to grab food later?"
        case .formal:      return "Hello. Are you available? I would like to arrange a meal."
        case .expressive:  return "Hey! You around? Let's grab food later!"
        case .emoji:       return "Hey, you around? Let's grab food later 🍜"
        case .patois:      return "Yuh deh bout? Yuh waan grab a food later?"
        case .shakespearean: return "Art thou nearby? Shall we sup together anon?"
        }
    }

    private var vocabularyCard: some View {
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

    // MARK: - Settings tab

    private var settingsTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    transcriptionSection
                    micHoldSection
                    keyboardSection
                    setupSection
                    aboutSection
                }
                .padding()
                .padding(.bottom, 24)
            }
            .navigationTitle("Settings")
        }
    }

    private var transcriptionSection: some View {
        section("Transcription") {
            Picker("Engine", selection: $engine) {
                Text("On-device").tag(TranscriptionEngine.onDevice)
                Text("Cloud").tag(TranscriptionEngine.cloud)
            }
            .pickerStyle(.segmented)
            .onChange(of: engine) { _, new in recorder.setTranscriptionEngine(new) }
            Text(engineBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineBlurb: String {
        switch engine {
        case .onDevice:
            switch recorder.modelStatus {
            case .idle:
                return "Transcribes privately on your iPhone — nothing is sent to the cloud, and it works offline. The speech model downloads once the first time you turn Dictator on."
            case .downloading:
                return "Downloading the on-device speech model… this happens once, then it works offline."
            case .ready:
                return "Ready — your speech is transcribed on your iPhone. The formatting step still uses the cloud for now (fast and cheap); a fully on-device version is coming."
            case .failed(let e):
                return "The on-device model couldn't load (\(e)). Falling back to the cloud; try turning Dictator off and on."
            }
        case .cloud:
            return "Transcribes in the cloud for the best accuracy on noisy audio, accents, and proper nouns. Audio is sent for transcription and not stored."
        }
    }

    /// iOS won't let the microphone be reopened from the background, so once
    /// Dictator lets it go, the next dictation costs a trip to this app and a
    /// swipe back. A short window means less orange dot and more trips; a long one
    /// means the reverse.
    private var micHoldSection: some View {
        section("Keep the microphone ready") {
            Picker("Release after", selection: $idleMinutes) {
                Text("5 min").tag(5)
                Text("30 min").tag(30)
                Text("2 hours").tag(120)
                Text("Never").tag(0)
            }
            .pickerStyle(.segmented)
            .onChange(of: idleMinutes) { _, new in SharedStore.idleReleaseMinutes = new }
            Text(idleBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var idleBlurb: String {
        switch idleMinutes {
        case 0:
            return "Dictator holds the microphone until you turn it off, so the keyboard always dictates in place. Uses a little more battery, and the orange mic dot stays on."
        default:
            let label = idleMinutes >= 60 ? "\(idleMinutes / 60) hours" : "\(idleMinutes) minutes"
            return "After \(label) without dictating, Dictator releases the microphone to save battery. Waking it again means opening this app and swiping back, so pick a longer window if that happens often."
        }
    }

    /// Swipe (glide) typing on the Dictator keyboard. On by default; the switch is
    /// here for anyone who finds it catches their fast tapping. The keyboard reads
    /// the flag whenever it shows the letters, so a change applies immediately.
    private var keyboardSection: some View {
        section("Keyboard") {
            Toggle("Swipe to type", isOn: $swipeTyping)
                .onChange(of: swipeTyping) { _, new in SharedStore.swipeTypingEnabled = new }
            Text("Slide your finger from letter to letter to type a word, the way the iPhone keyboard does. Tapping works as before. Turn this off if it gets in the way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSection: some View {
        section("Setup") {
            checklistRow(done: keyboardAdded, title: "Dictator keyboard added", step: 1)
            checklistRow(done: fullAccess, title: "Full Access on", step: 2)
            NavigationLink {
                DetailsView(recorder: recorder)
            } label: {
                HStack {
                    Text("Diagnostics & activity").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
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
                    Text("Set up").font(.caption).foregroundStyle(Self.brandGreenDeep)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var aboutSection: some View {
        section("About") {
            Link(destination: URL(string: "https://giddyuptiger.github.io/DICTATOR/privacy-policy.html")!) {
                aboutRow("Privacy Policy", "hand.raised")
            }
            .buttonStyle(.plain)
            Link(destination: URL(string: "https://giddyuptiger.github.io/DICTATOR/terms.html")!) {
                aboutRow("Terms of Use", "doc.text")
            }
            .buttonStyle(.plain)
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Self.versionLine).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func aboutRow(_ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
    }

    private func refreshChecklist() {
        let installed = (UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String]) ?? []
        keyboardAdded = installed.contains { $0.hasPrefix("design.irons.dictator.keyboard") }
        // The keyboard can only write to the App Group with Full Access, so a
        // stamp there is proof it was granted.
        fullAccess = SharedStore.keyboardEverSeen
    }

    // MARK: - Design tokens

    // Soft, muted accents instead of the saturated system colours, to match the
    // keyboard's pastel pills. Still saturated enough to read as a status dot.
    static let pastelGreen = Color(red: 0.36, green: 0.66, blue: 0.45) // sage
    static let pastelRed   = Color(red: 0.85, green: 0.47, blue: 0.44) // soft rose
    static let pastelAmber = Color(red: 0.87, green: 0.66, blue: 0.36) // soft amber

    // Brand accent — green, matched to the app icon (soundwave + mustache).
    static let brandGreen = Color(red: 0.22, green: 0.89, blue: 0.61)     // #37E39B
    static let brandGreenDeep = Color(red: 0.07, green: 0.64, blue: 0.36) // #12A45C
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandGreen, brandGreenDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Helpers

    /// "0.1.79 (3)": the hand-ratcheted version and the build Xcode Cloud assigns.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The neon waveform mark from the app icon, drawn as a row of gradient bars.
private struct WaveformMark: View {
    // Symmetric-ish amplitude pattern, as a fraction of the available height.
    private let amps: [CGFloat] = [0.30, 0.62, 0.42, 1.0, 0.55, 0.80, 0.38, 0.92, 0.48, 0.70, 0.28]

    var body: some View {
        GeometryReader { geo in
            let count = amps.count
            let spacing: CGFloat = 6
            let barW = max((geo.size.width - CGFloat(count - 1) * spacing) / CGFloat(count), 3)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(amps.indices, id: \.self) { i in
                    Capsule()
                        .fill(ContentView.brandGradient)
                        .frame(width: barW, height: max(geo.size.height * amps[i], barW))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .shadow(color: ContentView.brandGreen.opacity(0.35), radius: 6)
        }
    }
}

// MARK: - Wake screen

/// The screen the keyboard drops you on when it wakes Dictator to make it
/// resident. This is the Wispr Flow move: instead of the settings UI, show a
/// calm, mostly blank screen whose only job is to point you back to the app you
/// came from. iOS won't let an app return you automatically, so we teach the one
/// gesture that does — the swipe along the bottom home edge that jumps to the
/// previous app.
///
/// Two things matter here and both are deliberate:
///  1. NOTHING on this screen scrolls. A scroll view sitting on the bottom edge
///     fights the home-swipe gesture and makes iOS demand two swipes, which is
///     exactly the "swipe back is next to impossible" the user hit on the
///     scrolling settings page. This is a plain ZStack — no ScrollView anywhere —
///     so the bottom edge is clear and one swipe works.
///  2. The bottom bar doesn't just point; a fingertip actually travels the swipe
///     path left→right, over and over, so it's obvious what to physically do.
private struct WakeScreen: View {
    @State private var bounce = false

    // Dictator's green, matched to the app icon / keyboard accent.
    private static let brandTop    = Color(red: 0.22, green: 0.89, blue: 0.61) // #37E39B
    private static let brandBottom = Color(red: 0.07, green: 0.64, blue: 0.36) // #12A45C

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Logo mark: rounded square with the mic glyph, in the brand
                // gradient. Stands in for the app icon on this blank canvas.
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Self.brandTop, Self.brandBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 116, height: 116)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Self.brandTop.opacity(0.35), radius: 18, y: 8)

                VStack(spacing: 10) {
                    Text("Dictator is ready")
                        .font(.title2.bold())
                    Text("Swipe back to the app you were in, then tap the mic to dictate.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Points at the bar below, where the gesture actually is. Green,
                // with a chevron that nods toward the bar (0.1.126; the old "Stay
                // in Dictator" link read as an instruction and confused people;
                // the app is still reachable from the Home Screen).
                VStack(spacing: 6) {
                    Text("Swipe back to your typing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Self.brandBottom)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Self.brandBottom)
                        .offset(y: bounce ? 5 : -2)
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: bounce)
                }
                .padding(.bottom, 10)
                .onAppear { bounce = true }
            }

            // The colored bar hugging the bottom edge, right where the home-swipe
            // gesture lives. A fingertip travels the whole width to demonstrate.
            VStack {
                Spacer()
                SwipeHintBar(top: Self.brandTop, bottom: Self.brandBottom)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The bottom "Swipe back to your app" bar with a fingertip that continuously
/// glides left→right along the bar, trailing a soft motion blur and fading out at
/// each end so the loop never snaps. Driven by TimelineView so the motion is
/// frame-smooth and self-looping (no state juggling), and GeometryReader so the
/// fingertip travels the bar's real width on any device.
private struct SwipeHintBar: View {
    let top: Color
    let bottom: Color

    /// One full traverse, in seconds. Unhurried enough to read as "drag", not "flick".
    private let period: Double = 1.8

    var body: some View {
        // Kept deliberately SHORT. The system swipe-to-previous-app gesture only
        // fires very near the bottom edge, so a tall bar invites the user to swipe
        // in its (too-high) middle, where nothing happens. 0.1.122: shorter again
        // (about 38 pt from 62) — the label now sits beside the track instead of
        // above it, because a swipe inside the green but above the track was
        // still too high to fire.
        // The label moved above the bar (green, with the chevron); the bar is
        // the fingertip's track, full width.
        HStack(spacing: 12) {
            GeometryReader { geo in
                let dotSize: CGFloat = 20
                let inset: CGFloat = 8
                let travel = max(geo.size.width - dotSize - inset * 2, 0)

                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let t = now.truncatingRemainder(dividingBy: period) / period // 0…1
                    let eased = Self.easeInOut(t)
                    let x = inset + travel * eased
                    let alpha = Self.edgeFade(t)

                    ZStack(alignment: .leading) {
                        // Faint dashed track the fingertip runs along, so the path
                        // reads even at the instant the dot has faded out.
                        Capsule()
                            .strokeBorder(.white.opacity(0.28),
                                          style: StrokeStyle(lineWidth: 2, dash: [3, 5]))
                            .frame(height: 3)
                            .frame(maxWidth: .infinity)

                        // Motion trail: two ghosts lagging behind the fingertip.
                        fingertip(dotSize * 0.82)
                            .opacity(alpha * 0.18)
                            .offset(x: max(x - dotSize * 0.65, inset))
                        fingertip(dotSize * 0.9)
                            .opacity(alpha * 0.32)
                            .offset(x: max(x - dotSize * 0.33, inset))

                        // The fingertip itself.
                        fingertip(dotSize)
                            .opacity(alpha)
                            .offset(x: x)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: dotSize)
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 12) // sits low, still clear of the home indicator
        .background(
            LinearGradient(colors: [top, bottom], startPoint: .leading, endPoint: .trailing)
        )
    }

    /// A white puck with a subtle chevron, reading as a fingertip on the track.
    private func fingertip(_ size: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "chevron.right")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(bottom)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    /// Smooth start/stop so the drag accelerates and eases in, like a real swipe.
    private static func easeInOut(_ t: Double) -> CGFloat {
        CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
    }

    /// Fade the fingertip in over the first sliver and out over the last, so the
    /// wrap from the right edge back to the left is never visible as a jump.
    private static func edgeFade(_ t: Double) -> Double {
        let edge = 0.14
        if t < edge { return t / edge }
        if t > 1 - edge { return (1 - t) / edge }
        return 1
    }
}

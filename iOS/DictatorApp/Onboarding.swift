import SwiftUI
import AVFoundation
import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// First run: five screens, one each, from install to a working dictation. The
/// two Apple dialogs people bail at (Full Access, microphone) are explained on
/// the screen before each one, so the warning is expected rather than alarming.
///
/// Copy here is consent-surface and instructional, so it names the mechanism on
/// purpose (VOICE.md § 2). Re-check the Full Access paragraph if the keyboard
/// target ever gains a network call.
struct OnboardingView: View {
    let onFinish: () -> Void

    init(startStep: Int = 1, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: min(max(startStep, 1), 5))
    }

    @State private var step: Int
    private let total = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step \(step) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip setup") { finish() }
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.top)

            ProgressView(value: Double(step), total: Double(total))
                .padding(.horizontal)
                .padding(.top, 6)

            ScrollView {
                Group {
                    switch step {
                    case 1: keyStep
                    case 2: keyboardStep
                    case 3: fullAccessStep
                    case 4: micStep
                    default: tryStep
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Step 1: Groq key

    @State private var key = ""
    @State private var checking = false
    @State private var keyMessage: String?
    @State private var keyOK = false

    private var keyStep: some View {
        step(
            title: "Dictator runs on your own Groq account",
            body: "Groq turns your voice into text. A key is free to create, and Groq bills you for what you use. Half an hour a day is about a dollar a month, and nothing when you're not talking."
        ) {
            Link("Get a key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                .font(.callout)

            SecureField("Paste your key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    validateKey()
                } label: {
                    if checking { ProgressView() } else { Text("Check and save") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)

                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(keyOK ? .green : .red)
                }
            }

            nextRow(enabled: keyOK, laterAdvances: true)
        }
    }

    private func validateKey() {
        checking = true
        keyMessage = nil
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let ok = try await GroqTranscription.validateKey(candidate)
                await MainActor.run {
                    checking = false
                    keyOK = ok
                    if ok {
                        SharedStore.groqAPIKey = candidate
                        keyMessage = "Key works"
                    } else {
                        keyMessage = "Groq didn't accept that key"
                    }
                }
            } catch {
                await MainActor.run {
                    checking = false
                    keyOK = false
                    keyMessage = "Couldn't reach Groq. Check your connection."
                }
            }
        }
    }

    // MARK: - Step 2: add the keyboard

    private var keyboardStep: some View {
        step(
            title: "Add Dictator to your keyboards",
            body: "Settings opens on Dictator's page. Tap Keyboards, then turn on Dictator and Allow Full Access. The checklist on the home screen ticks when you come back."
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            nextRow(enabled: true, laterAdvances: true)
        }
    }

    // MARK: - Step 3: Full Access explainer

    private var fullAccessStep: some View {
        step(
            title: "About the warning you're about to see",
            body: "Apple shows the same warning for every keyboard that talks to its app. In Dictator, Full Access lets the keyboard read the text this app wrote. The keyboard has no network code. This app sends your audio to Groq to be transcribed, and nothing else."
        ) {
            nextRow(nextTitle: "Got it", enabled: true, laterAdvances: false)
        }
    }

    // MARK: - Step 4: microphone

    @State private var micAsked = false

    private var micStep: some View {
        step(
            title: "The orange dot is the truth",
            body: "While Dictator is on, it keeps the microphone open so the keyboard can dictate from any app without switching back here. Your iPhone shows the orange dot the whole time it's open. Turn Dictator off when you want the microphone closed."
        ) {
            Button("Allow the microphone") {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    await MainActor.run { micAsked = true; step = 5 }
                }
            }
            .buttonStyle(.borderedProminent)

            nextRow(enabled: true, laterAdvances: true)
        }
    }

    // MARK: - Step 5: try it

    @State private var tryText = ""

    private var tryStep: some View {
        step(
            title: "Try it",
            body: "Tap here, hold the globe to choose Dictator, then tap Tap to talk."
        ) {
            TextField("Say something…", text: $tryText)
                .textFieldStyle(.roundedBorder)

            if !tryText.isEmpty {
                Text("That's it.")
                    .font(.headline)
                    .foregroundStyle(.green)
            }

            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func step<Content: View>(
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func nextRow(nextTitle: String = "Next", enabled: Bool, laterAdvances: Bool) -> some View {
        HStack {
            if enabled {
                Button(nextTitle) { advance() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if laterAdvances && step < total {
                Button("Do this later") { advance() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func advance() {
        if step < total { step += 1 } else { finish() }
    }

    private func finish() {
        SharedStore.onboardingDone = true
        onFinish()
    }
}

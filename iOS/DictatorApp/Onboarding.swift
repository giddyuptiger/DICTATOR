import SwiftUI
import AVFoundation
import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// First run: four screens, one each, from install to a working dictation. No API
/// key step anymore — transcription runs on the device and cleanup goes through the
/// backend, so there's nothing for the user to paste. The two Apple dialogs people
/// bail at (Full Access, microphone) are explained on the screen before each one, so
/// the warning is expected rather than alarming.
///
/// Copy here is consent-surface and instructional, so it names the mechanism on
/// purpose (VOICE.md § 2). Re-check the Full Access paragraph if the keyboard target
/// ever makes its own network call.
///
/// App Review rule that shapes the microphone step (guideline 5.1.1(iv); the 1.0
/// (122) rejection): a screen shown before a system permission prompt may explain,
/// but its button must be neutral ("Continue"/"Next", not "Allow…") and the user
/// must always proceed to the prompt — no skip or "later" that bypasses it.
struct OnboardingView: View {
    let onFinish: () -> Void

    init(startStep: Int = 1, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: min(max(startStep, 1), 4))
    }

    @State private var step: Int
    private let total = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step \(step) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Not on the microphone step. App Review (guideline 5.1.1(iv))
                // requires that a message shown before a permission prompt always
                // leads to that prompt: no skip, no "later". The rejection of
                // 1.0 (122) named this very button.
                if step != 3 {
                    Button("Skip setup") { finish() }
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            ProgressView(value: Double(step), total: Double(total))
                .padding(.horizontal)
                .padding(.top, 6)

            ScrollView {
                Group {
                    switch step {
                    case 1: keyboardStep
                    case 2: fullAccessStep
                    case 3: micStep
                    default: tryStep
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Step 1: add the keyboard

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

    // MARK: - Step 2: Full Access explainer

    private var fullAccessStep: some View {
        step(
            title: "About the warning you're about to see",
            body: "Apple shows the same warning for every keyboard that can reach its app. In Dictator, Full Access lets the keyboard receive the text this app produced and reach the network. Your speech is transcribed on your iPhone; only the short cleanup step contacts our server. The keyboard never logs what you type."
        ) {
            nextRow(nextTitle: "Got it", enabled: true, laterAdvances: false)
        }
    }

    // MARK: - Step 3: microphone

    @State private var micAsked = false
    @State private var micGranted = false

    private var micStep: some View {
        step(
            title: "The orange dot is the truth",
            body: "While Dictator is on, it keeps the microphone open so the keyboard can dictate from any app without switching back here. Your iPhone shows the orange dot the whole time it's open. Turn Dictator off when you want the microphone closed."
        ) {
            // App Review (guideline 5.1.1(iv), rejection of 1.0 (122)): a message
            // shown before a permission prompt must use a neutral button
            // ("Continue" or "Next", never "Allow…"), and the user must always go
            // on to the system prompt — so until the prompt has been shown there is
            // no Next, no "Do this later" and no Skip on this screen. The decision
            // itself is made in Apple's dialog, which is the point of the rule.
            if !micAsked {
                Button("Continue") {
                    Task {
                        let granted = await AVAudioApplication.requestRecordPermission()
                        await MainActor.run {
                            micAsked = true
                            micGranted = granted
                            // Only move on if it was actually granted. Walking the
                            // user to "Try it" after they tapped Don't Allow sets
                            // them up to watch a mic button do nothing.
                            if granted { step = 4 }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if !micGranted {
                // The prompt has been shown (or was answered on an earlier run),
                // so the user may now continue without the microphone.
                Text("Dictator can't hear you yet. Open Settings › Dictator and turn the microphone on, then come back.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption)

                nextRow(enabled: true, laterAdvances: false)
            }
        }
    }

    // MARK: - Step 4: try it

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

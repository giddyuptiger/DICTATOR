import SwiftUI
import UIKit
import AVFoundation

// ============================================================================
// PROBE v4 — no buttons. Everything fires automatically on launch.
//
// v3's buttons did not respond, which made the UI itself a variable. This
// version removes it: the permission request and the in-app recording test
// both run from .task the moment the view appears. The only thing you tap is
// the system permission dialog.
//
// Why this app matters at all: the microphone TCC grant has to be established
// by the CONTAINING APP. A keyboard extension asking for permission itself
// gets a meaningless "true" and then no samples. That is what v2 hit.
// ============================================================================

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var lines: [String] = ["starting…"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MIC PROBE")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.bottom, 8)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l)
                            .font(.system(size: 15, weight: .regular, design: .monospaced))
                            .foregroundColor(l.contains("FAIL") || l.contains("DENIED") ? .red
                                             : (l.contains("OK") || l.contains("GRANTED") || l.contains("WORKS") ? .green : .white))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .task { await run() }
    }

    private func say(_ s: String) { lines.append(s) }

    private func run() async {
        lines = ["MIC PROBE", "iOS \(UIDevice.current.systemVersion)", ""]

        // 1. Current state before we ask.
        if #available(iOS 17.0, *) {
            say("before: \(describe(AVAudioApplication.shared.recordPermission))")
        }

        // 2. Ask. This is the grant the extension will inherit.
        say("requesting permission…")
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
        }
        say(granted ? "GRANTED" : "DENIED  (Settings > Privacy > Microphone)")
        if #available(iOS 17.0, *) {
            say("after: \(describe(AVAudioApplication.shared.recordPermission))")
        }
        say("")

        guard granted else {
            say("Fix permission, then relaunch.")
            return
        }

        // 3. Prove the grant is real by recording here, where nothing is sandboxed.
        say("recording 1s in this app…")
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("apptest.m4a")
            try? FileManager.default.removeItem(at: url)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1
            ])
            guard r.record() else { say("FAIL: record() returned false in the APP too"); return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            r.stop()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            say(size > 1000 ? "WORKS in app: \(size) bytes" : "FAIL: started but wrote only \(size) bytes")
            try? session.setActive(false)
        } catch {
            say("FAIL: \((error as NSError).code)")
        }

        say("")
        say("NEXT:")
        say("Settings > General > Keyboard > Keyboards")
        say("Add New Keyboard > MicProbe")
        say("Tap MicProbe > Allow Full Access ON")
        say("Notes > hold globe > MicProbe > RUN MATRIX")
    }

    @available(iOS 17.0, *)
    private func describe(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .granted: return "GRANTED"
        case .denied: return "DENIED"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }
}

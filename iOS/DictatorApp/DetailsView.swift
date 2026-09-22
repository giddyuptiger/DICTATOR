import SwiftUI
import UIKit

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// The builder view: the activity log and the last timing. Off the home screen
/// on purpose. Users say "half a beat", not milliseconds; the numbers live here
/// for when something needs diagnosing.
struct DetailsView: View {
    @ObservedObject var recorder: BackgroundRecorder

    var body: some View {
        List {
            Section {
                ShareLink(item: diagnostics) {
                    Label("Report a problem", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Shares Dictator's version, your device, and the activity log below so a bug can be diagnosed. Send it to yourself or to support.")
            }

            Section("Last dictation") {
                if SharedStore.lastLatencyMS > 0 {
                    LabeledContent("Time", value: Self.friendlyDuration(SharedStore.lastLatencyMS))
                } else {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
            }

            Section {
                if recorder.eventLog.isEmpty {
                    Text("nothing yet").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(recorder.eventLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("The log survives the app being closed, so you can see what happened while you were in another app.")
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { recorder.reloadLog() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") { recorder.clearLog() }
            }
        }
        .onAppear { recorder.reloadLog() }
    }

    /// A plain-text bug report: build, device, OS, and the activity log. The log
    /// can include the first words of a dictation, so this is shared only when
    /// the user taps Report a problem.
    private var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Dictator \(version) (\(build))",
            "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)",
            "Last dictation: \(SharedStore.lastLatencyMS) ms",
            "",
            "Activity:"
        ]
        lines.append(contentsOf: recorder.eventLog)
        // Swipe typing keeps its own log (dictations would push swipes out of
        // the activity log); it goes in the same report.
        let swipes = SharedStore.swipeLogLines
        if !swipes.isEmpty {
            lines.append("")
            lines.append("Swipes (newest first):")
            lines.append(contentsOf: swipes)
        }
        return lines.joined(separator: "\n")
    }

    /// Latency as a person would say it, not raw milliseconds. "0.8s", "3.1s".
    static func friendlyDuration(_ ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000)
    }
}

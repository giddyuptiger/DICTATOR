import SwiftUI

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// The builder view: the activity log and the last timing. Off the home screen
/// on purpose. Users say "half a beat", not milliseconds; the numbers live here
/// for when something needs diagnosing.
struct DetailsView: View {
    @ObservedObject var recorder: BackgroundRecorder

    var body: some View {
        List {
            Section("Last dictation") {
                if SharedStore.lastLatencyMS > 0 {
                    LabeledContent("Time", value: "\(SharedStore.lastLatencyMS) ms")
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
}

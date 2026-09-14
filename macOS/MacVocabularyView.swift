import SwiftUI

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// SwiftUI wrapper over PersonalDictionary for the Mac, synced with the iPhone
/// through iCloud key-value store. Same words on both devices.
@MainActor
final class MacDictionaryStore: ObservableObject {
    @Published private(set) var dictionary: PersonalDictionary

    init() { dictionary = PersonalDictionary.mergeFromCloud() }

    func reload() { dictionary = PersonalDictionary.mergeFromCloud() }

    var entries: [PersonalDictionary.Entry] {
        dictionary.entries.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() }
    }

    func add(canonical: String, misheard: [String]) {
        let word = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let heard = misheard
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var d = dictionary
        d.add(PersonalDictionary.Entry(canonical: word, misheard: heard))
        d.save()
        dictionary = d
    }

    func remove(_ canonical: String) {
        var d = dictionary
        d.remove(canonical: canonical)
        d.save()
        dictionary = d
    }
}

struct MacVocabularyView: View {
    @StateObject private var store = MacDictionaryStore()
    @State private var canonical = ""
    @State private var misheard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names and terms Dictator should spell your way. Synced with your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    TextField("Correct spelling (e.g. Egoscue)", text: $canonical)
                    TextField("What it hears instead (ego skew, ego q)", text: $misheard)
                }
                Button("Add") {
                    store.add(canonical: canonical, misheard: misheard.split(separator: ",").map(String.init))
                    canonical = ""
                    misheard = ""
                }
                .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if store.entries.isEmpty {
                Text("No words yet. Add the ones you correct by hand.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                List {
                    ForEach(store.entries, id: \.canonical) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.canonical)
                                if !entry.misheard.isEmpty {
                                    Text("hears: " + entry.misheard.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                store.remove(entry.canonical)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .onAppear { store.reload() }
    }
}

import SwiftUI

// Note: DictationCore is compiled directly into this target as source
// (see project.yml), not linked as a module, so there is nothing to import.

/// A SwiftUI wrapper over PersonalDictionary, which is a value type with its own
/// App Group + iCloud persistence. This is the missing piece the design flagged:
/// the dictionary biased the decoder and ran a deterministic pass, but no screen
/// let anyone add a word, and nothing called `learn`.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var dictionary: PersonalDictionary

    init() {
        dictionary = PersonalDictionary.mergeFromCloud()
    }

    func reload() {
        dictionary = PersonalDictionary.mergeFromCloud()
    }

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

    /// A correction the user made: they changed `heard` to `corrected`, so record
    /// the mishearing. This is the call the design said nothing made.
    func learn(heard: String, corrected: String) {
        var d = dictionary
        d.learn(misheard: heard, corrected: corrected)
        d.save()
        dictionary = d
    }
}

struct VocabularyView: View {
    @ObservedObject var store: DictionaryStore
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                Text("Names and terms a general model gets wrong. Dictator spells these the way you want and nudges the decoder toward them before it decodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.entries.isEmpty {
                Section {
                    Text("No words yet. Add the ones you correct by hand.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Your words") {
                    ForEach(store.entries, id: \.canonical) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.canonical)
                            if !entry.misheard.isEmpty {
                                Text("hears: " + entry.misheard.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.remove(store.entries[i].canonical) }
                    }
                }
            }
        }
        .navigationTitle("Vocabulary")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add a word", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddWordSheet(store: store)
        }
        .onAppear { store.reload() }
    }
}

struct AddWordSheet: View {
    @ObservedObject var store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var canonical = ""
    @State private var misheard = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("The correct spelling") {
                    TextField("e.g. Egoscue", text: $canonical)
                        .autocorrectionDisabled()
                }
                Section("What it hears instead") {
                    TextField("ego skew, ego q", text: $misheard)
                        .autocorrectionDisabled()
                    Text("Optional. Separate with commas. Dictator replaces these with the correct spelling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add a word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.add(canonical: canonical,
                                  misheard: misheard.split(separator: ",").map(String.init))
                        dismiss()
                    }
                    .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Records a single mishearing: "it heard X, I meant Y". Wired to
/// DictionaryStore.learn, so the same mistake self-heals next time.
struct CorrectionSheet: View {
    @ObservedObject var store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var heard = ""
    @State private var corrected = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("What Dictator wrote") {
                    TextField("what it heard", text: $heard)
                        .autocorrectionDisabled()
                }
                Section("What you meant") {
                    TextField("the right word", text: $corrected)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Fix a word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.learn(heard: heard, corrected: corrected)
                        dismiss()
                    }
                    .disabled(
                        heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

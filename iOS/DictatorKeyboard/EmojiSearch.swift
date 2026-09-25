import Foundation

/// Emoji search: a keyword index built from Unicode's own English names and
/// keywords (scripts/build_emoji_keywords.py → emoji-keywords.txt, one line per
/// emoji in the catalogue: `emoji<TAB>name<TAB>keywords`). About 1,300 entries,
/// so a full scan per keystroke is nothing.
final class EmojiSearch {

    static let shared = EmojiSearch()

    private struct Entry {
        let emoji: String
        let name: [String]      // words of the Unicode name, e.g. ["face", "with", "tears", "of", "joy"]
        let keywords: [String]  // Unicode keywords plus a few everyday synonyms
    }

    private var entries: [Entry] = []
    private var loaded = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "emoji-keywords", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var list: [Entry] = []
        list.reserveCapacity(1400)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let name = parts[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let kws = parts.count > 2 ? parts[2].split(separator: " ", omittingEmptySubsequences: true).map(String.init) : []
            list.append(Entry(emoji: String(parts[0]), name: name, keywords: kws))
        }
        entries = list
    }

    /// Emoji matching every word of `query` (each as a prefix of a name word or a
    /// keyword), best first: name matches outrank keyword matches, and ties keep
    /// catalogue order, which is roughly "most used first" within a category.
    func matches(_ query: String, limit: Int = 40) -> [String] {
        loadIfNeeded()
        let tokens = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(score: Int, order: Int, emoji: String)] = []
        for (order, e) in entries.enumerated() {
            var score = 0
            var all = true
            for t in tokens {
                if e.name.contains(where: { $0 == t }) { score += 4 }
                else if e.name.contains(where: { $0.hasPrefix(t) }) { score += 2 }
                else if e.keywords.contains(where: { $0 == t }) { score += 2 }
                else if e.keywords.contains(where: { $0.hasPrefix(t) }) { score += 1 }
                else { all = false; break }
            }
            if all { scored.append((score, order, e.emoji)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.emoji)
    }
}

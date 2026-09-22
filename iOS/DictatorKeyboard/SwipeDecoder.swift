import Foundation
import CoreGraphics

/// Swipe (glide) typing: turns the path a finger draws across the letter keys
/// into a word, the way QuickPath / Gboard do.
///
/// A keyboard extension has no dictionary API that enumerates words, so a
/// frequency-ranked English list (`swipe-words.txt`, ~20k words from Google's
/// trillion-word corpus, most common first) ships in the bundle. Lines are either
/// a plain word, or `keys=output` for words whose swipe path differs from their
/// spelling (contractions: the finger traces `dont`, the text says "don't").
///
/// Decoding is SHARK2-style shape matching, tuned in simulation (82–84% top-1
/// at realistic noise, all common words correct):
///   - resample the drawn path and each candidate word's "ideal" path (a polyline
///     through its letter centres, repeated letters collapsed) to N points and
///     take the mean point-to-point distance (the shape channel);
///   - weight the START and END points heavily — a person aims precisely at the
///     first and last letters and is sloppy in between, and almost every wrong
///     guess in testing was a neighbour-key confusion at an endpoint;
///   - a location channel: every letter of the candidate must lie near the drawn
///     path (free inside a tunnel, penalised beyond it), so a word cannot win by
///     matching the shape while skipping a letter;
///   - a mild length prior, and a mild frequency prior (log rank) to break ties
///     towards common words.
/// Candidates are first filtered to words whose first and last letters sit near
/// the path's endpoints, so only a few hundred words are scored per swipe.
///
/// Everything here is plain geometry on the main thread; a decode is well under
/// a millisecond. The lexicon loads once, off the main thread, on first use.
final class SwipeDecoder {

    static let shared = SwipeDecoder()

    /// One dictionary word. `keys` are letter indices 0...25 along the swipe path
    /// (repeats collapsed), `output` is what gets typed.
    private struct Entry {
        let keys: [Int]
        let output: String
    }

    /// Resample count for both the drawn path and each candidate's ideal path.
    private static let samples = 40
    /// Candidate filter: first/last letter must be within this many key widths
    /// of the path's first/last point.
    private static let endpointTolerance = 1.4
    /// Score weights (all in key-width units except the shape channel, which is a
    /// mean distance). Re-tuned after the first device feedback against a harder
    /// simulation (real iPhone geometry, corner-cutting between letters, a 27k
    /// lexicon): a wider tunnel and a lighter length prior forgive cut corners,
    /// and a stronger frequency prior lets common words beat look-alikes.
    private static let endpointWeight = 1.2
    private static let locationWeight = 1.0
    private static let locationTunnel = 0.65
    private static let lengthWeight = 0.25
    /// Penalty, in key widths, for a candidate whose first letter is not the key
    /// the touch-down hit-tested to (see `decode(startLetter:)`).
    private static let startKeyPenalty = 0.6
    /// Stronger than the first cut (0.18): on real thumbs the losers were junk
    /// look-alikes ("osu" over "okay"), and the simulator's sweep peaked here.
    private static let frequencyWeight = 0.30

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Indices into `entries`, bucketed by first letter, for the candidate filter.
    private var byFirstLetter: [[Int]] = Array(repeating: [], count: 26)
    private var loaded = false
    private let loadQueue = DispatchQueue(label: "design.irons.dictator.swipe.lexicon", qos: .utility)

    private init() {}

    /// Load the lexicon in the background so the first swipe doesn't pay for it.
    func warmUp() {
        loadQueue.async { self.loadIfNeeded() }
    }

    /// Add the user's own words (the personal dictionary's canonical terms) so a
    /// custom name or product can be swiped. Letters only; anything else is not
    /// swipeable and is skipped. They rank above every bundled word.
    func addUserWords(_ words: [String]) {
        let extra = words.compactMap { Self.parse(line: $0) }
        guard !extra.isEmpty else { return }
        loadQueue.async {
            self.loadIfNeeded()
            self.lock.lock(); defer { self.lock.unlock() }
            // Prepend, and rebuild the buckets since every index shifts.
            let known = Set(self.entries.map(\.output))
            let fresh = extra.filter { !known.contains($0.output) }
            guard !fresh.isEmpty else { return }
            self.entries = fresh + self.entries
            self.rebuildBuckets()
        }
    }

    /// Decode a drawn path into a word.
    /// - Parameters:
    ///   - path: the finger's points, in the same coordinate space as `centers`.
    ///   - centers: the centre of each letter key ("a"..."z") on screen.
    ///   - keyWidth: the width of one letter key, used to scale every tolerance.
    /// - Returns: the best word, or nil if nothing plausible matched.
    ///   - startLetter: the letter of the key the touch-down HIT-TESTED to, if
    ///     known. That is exactly what a tap would have typed, and people are
    ///     calibrated to it, so a candidate starting with any other letter pays a
    ///     penalty. This is what separates "is" from "us" and "feature" from
    ///     "gesture" when the finger lands near a key edge.
    func decode(path: [CGPoint], centers: [Character: CGPoint], keyWidth: CGFloat,
                startLetter: Character? = nil) -> String? {
        decodeRanked(path: path, centers: centers, keyWidth: keyWidth, startLetter: startLetter).first?.word
    }

    /// A ranked candidate: the word and its score in key widths (lower is better).
    struct Candidate {
        let word: String
        let score: Double
    }

    /// The best few candidates, best first. This is what the swipe log records,
    /// so a wrong guess shows whether the right word was a close second — the
    /// difference between a scoring problem and a lexicon problem.
    func decodeRanked(path: [CGPoint], centers: [Character: CGPoint], keyWidth: CGFloat,
                      startLetter: Character? = nil, limit: Int = 3) -> [Candidate] {
        guard path.count >= 2, keyWidth > 0 else { return [] }
        let startIndex = startLetter.flatMap { Self.index(of: $0) }
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return [] }

        let kw = Double(keyWidth)
        var centre = [CGPoint?](repeating: nil, count: 26)
        for (ch, p) in centers {
            if let i = Self.index(of: ch) { centre[i] = p }
        }

        let drawn = Self.resample(path, count: Self.samples)
        let drawnLength = Self.length(of: path)
        guard let first = path.first, let last = path.last else { return [] }

        // Which letters could the path have started / ended on? Always at least
        // the nearest one: a lift that lands a little below the bottom row (over
        // the space bar) or above the top row must still decode, because by now
        // the letter the touch-down typed has been taken back and returning
        // nothing would leave the person with less than they had.
        var firstLetters = [Int](), lastLetters = [Int]()
        var nearestFirst = -1, nearestLast = -1
        var nearestFirstDistance = Double.greatestFiniteMagnitude
        var nearestLastDistance = Double.greatestFiniteMagnitude
        for i in 0..<26 {
            guard let c = centre[i] else { continue }
            let df = Self.distance(c, first), dl = Self.distance(c, last)
            if df <= Self.endpointTolerance * kw { firstLetters.append(i) }
            if dl <= Self.endpointTolerance * kw { lastLetters.append(i) }
            if df < nearestFirstDistance { nearestFirstDistance = df; nearestFirst = i }
            if dl < nearestLastDistance { nearestLastDistance = dl; nearestLast = i }
        }
        if firstLetters.isEmpty, nearestFirst >= 0 { firstLetters = [nearestFirst] }
        if lastLetters.isEmpty, nearestLast >= 0 { lastLetters = [nearestLast] }
        guard !firstLetters.isEmpty, !lastLetters.isEmpty else { return [] }
        let lastSet = Set(lastLetters)

        var scored = [(score: Double, output: String)]()
        for f in firstLetters {
            for rank in byFirstLetter[f] {
                let entry = entries[rank]
                guard let lastKey = entry.keys.last, lastSet.contains(lastKey) else { continue }

                // The word's ideal path through its letter centres. A letter with no
                // key on screen (never happens on the letters plane) disqualifies it.
                var ideal = [CGPoint]()
                ideal.reserveCapacity(entry.keys.count)
                var missing = false
                for k in entry.keys {
                    guard let c = centre[k] else { missing = true; break }
                    ideal.append(c)
                }
                if missing { continue }

                // Shape channel.
                let idealResampled = Self.resample(ideal, count: Self.samples)
                var shape = 0.0
                for i in 0..<Self.samples { shape += Self.distance(drawn[i], idealResampled[i]) }
                shape /= Double(Self.samples)

                // Endpoint channel: start and end are where the person was precise.
                let endpoints = Self.distance(first, ideal[0]) + Self.distance(last, ideal[ideal.count - 1])

                // Location channel: every letter must be visited (within the tunnel).
                var location = 0.0
                for c in ideal {
                    var nearest = Double.greatestFiniteMagnitude
                    for p in drawn { nearest = min(nearest, Self.distance(c, p)) }
                    location += max(0, nearest - Self.locationTunnel * kw)
                }
                location /= Double(ideal.count)

                // Length prior: a path much longer or shorter than the word's is suspect.
                let idealLength = Self.length(of: ideal)
                let lengthPenalty = abs(log((drawnLength + 0.5 * kw) / (idealLength + 0.5 * kw)))

                let startMismatch = (startIndex != nil && startIndex != f) ? Self.startKeyPenalty * kw : 0
                let score = shape
                    + Self.endpointWeight * endpoints
                    + Self.locationWeight * location
                    + startMismatch
                    + Self.lengthWeight * kw * lengthPenalty
                    + Self.frequencyWeight * kw * log10(Double(rank) + 1)

                scored.append((score, entry.output))
            }
        }
        // A few hundred candidates at most; sorting is nothing next to scoring.
        return scored.sorted { $0.score < $1.score }
            .prefix(max(1, limit))
            .map { Candidate(word: $0.output, score: $0.score / kw) }
    }

    // MARK: - Lexicon

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "swipe-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var list = [Entry]()
        list.reserveCapacity(20_500)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let e = Self.parse(line: String(line)) { list.append(e) }
        }
        entries = list
        rebuildBuckets()
    }

    /// Must be called with `lock` held.
    private func rebuildBuckets() {
        var buckets = [[Int]](repeating: [], count: 26)
        for (i, e) in entries.enumerated() {
            if let f = e.keys.first { buckets[f].append(i) }
        }
        byFirstLetter = buckets
    }

    /// Parse one lexicon line: `word` or `keys=output`. The swipe keys must be
    /// letters only and at least two long (a one-letter word is a tap, not a swipe).
    private static func parse(line raw: String) -> Entry? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let keysText: String
        let output: String
        if let eq = line.firstIndex(of: "=") {
            keysText = String(line[..<eq])
            output = String(line[line.index(after: eq)...])
        } else {
            keysText = line
            output = line
        }
        guard keysText.count >= 2, !output.isEmpty else { return nil }
        var keys = [Int]()
        keys.reserveCapacity(keysText.count)
        for ch in keysText.lowercased() {
            guard let i = index(of: ch) else { return nil }   // not a swipeable word
            if keys.last != i { keys.append(i) }             // collapse repeats: "hello" -> h e l o
        }
        guard keys.count >= 1 else { return nil }
        return Entry(keys: keys, output: output)
    }

    private static func index(of ch: Character) -> Int? {
        guard let scalar = ch.lowercased().unicodeScalars.first,
              scalar.value >= 97, scalar.value <= 122 else { return nil }
        return Int(scalar.value) - 97
    }

    // MARK: - Geometry

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func length(of pts: [CGPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += distance(pts[i - 1], pts[i]) }
        return total
    }

    /// `count` points spaced evenly along the polyline's arc length.
    private static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard let firstPoint = pts.first else { return [] }
        guard pts.count > 1 else { return [CGPoint](repeating: firstPoint, count: count) }
        var cumulative = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count { cumulative[i] = cumulative[i - 1] + distance(pts[i - 1], pts[i]) }
        let total = cumulative[pts.count - 1]
        guard total > 0 else { return [CGPoint](repeating: firstPoint, count: count) }

        var out = [CGPoint]()
        out.reserveCapacity(count)
        var seg = 0
        for k in 0..<count {
            let t = total * Double(k) / Double(count - 1)
            while seg < pts.count - 2, cumulative[seg + 1] < t { seg += 1 }
            let segLength = cumulative[seg + 1] - cumulative[seg]
            let f = segLength > 0 ? (t - cumulative[seg]) / segLength : 0
            let a = pts[seg], b = pts[seg + 1]
            out.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(f), y: a.y + (b.y - a.y) * CGFloat(f)))
        }
        return out
    }
}

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
    /// (repeats collapsed), `keysText` the full lowercase letters (the bigram
    /// model's key for the word), `output` is what gets typed.
    private struct Entry {
        let keys: [Int]
        let keysText: String
        let output: String
    }

    // MARK: Context model

    /// Pseudo-word for the start of a field or sentence, matching "<S>" in
    /// Norvig's bigram counts.
    static let sentenceStart = "<s>"
    /// Bigram pairs from `swipe-bigrams.txt` (Norvig's Google web counts, pruned
    /// to our lexicon by scripts/build_swipe_bigrams.py): two flat sorted arrays,
    /// searched by binary search — about 2.4 MB for ~250k pairs, which matters in
    /// a keyboard extension's 48 MB ceiling where a dictionary would cost 4x.
    private var bigramKeys: [UInt64] = []        // (prevID << 32) | wordID
    private var bigramScores: [UInt8] = []       // round(10 * log10(count))
    private var bigramID: [String: UInt32] = [:] // keysText -> id
    private var entryBigramID: [UInt32] = []     // per entry; UInt32.max when unknown
    /// Bonus weight, in key widths per decade of count above the floor. "this is"
    /// (10^8.2) beats "this us" (absent) by about 0.9 key widths: on real thumbs
    /// (0.1.119) context had to carry more, because a lift a full key early is
    /// common and shape alone cannot tell "instead" from "interest" then.
    private static let contextWeight = 0.25
    private static let contextFloor = 4.5
    private static let contextCap = 5.0

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
    ///
    /// Re-tuned again in 0.1.119 against 48 real swipes with known targets (see
    /// BUILD.md): a lighter endpoint weight (a thumb lifts a full key early or
    /// late more often than the simulator assumed) and a lighter frequency
    /// prior, now that the lexicon carries fewer junk look-alikes.
    private static let endpointWeight = 0.6
    private static let locationWeight = 1.0
    private static let locationTunnel = 0.85
    private static let lengthWeight = 0.25
    /// Penalty, in key widths, for a candidate whose first letter is not the key
    /// the touch-down hit-tested to (see `decode(startLetter:)`). Graded: nothing
    /// while the touch-down is within half a key of the candidate's first letter,
    /// the full penalty from a key away. A thumb that lands on the seam between
    /// "t" and "y" meant either.
    private static let startKeyPenalty = 0.6
    private static let frequencyWeight = 0.22
    /// Horizontal reach. A thumb does not stretch to the edge keys: on a real
    /// iPhone the turns meant for "p" (x 417) landed at 384-398 and those meant
    /// for "a" (x 41) at 55-90, a consistent 14% compression about the centre of
    /// the keyboard, while the middle keys were hit where they are. Each word's
    /// ideal path is therefore scored at full width AND compressed to 86%, and
    /// the better fit counts. "swipe" lost to "store" at full width alone: the
    /// user's turn never reached "p", and "store"'s "o" was closer.
    private static let reachScales: [Double] = [0.95, 0.85]

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
    ///   - previousWord: the word before the cursor as swipe keys (lowercase
    ///     letters, apostrophes dropped), or `sentenceStart`; nil for no context.
    func decodeRanked(path: [CGPoint], centers: [Character: CGPoint], keyWidth: CGFloat,
                      startLetter: Character? = nil, previousWord: String? = nil,
                      limit: Int = 3) -> [Candidate] {
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
        let prevID = previousWord.flatMap { bigramID[$0] }

        // The keyboard's horizontal centre, for the reach scales.
        var centreX = 0.0, centreCount = 0.0
        for c in centre { if let c { centreX += Double(c.x); centreCount += 1 } }
        centreX /= max(1, centreCount)

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

                // Geometry, at each reach scale; the best fit counts.
                var geometry = Double.greatestFiniteMagnitude
                for scale in Self.reachScales {
                    let path = scale == 1.0 ? ideal : ideal.map {
                        CGPoint(x: centreX + (Double($0.x) - centreX) * scale, y: Double($0.y))
                    }

                    // Shape channel.
                    let idealResampled = Self.resample(path, count: Self.samples)
                    var shape = 0.0
                    for i in 0..<Self.samples { shape += Self.distance(drawn[i], idealResampled[i]) }
                    shape /= Double(Self.samples)

                    // Endpoint channel: start and end are where the person was precise.
                    let endpoints = Self.distance(first, path[0]) + Self.distance(last, path[path.count - 1])

                    // Location channel: every letter must be visited (within the tunnel).
                    var location = 0.0
                    for c in path {
                        var nearest = Double.greatestFiniteMagnitude
                        for p in drawn { nearest = min(nearest, Self.distance(c, p)) }
                        location += max(0, nearest - Self.locationTunnel * kw)
                    }
                    // Summed, not averaged: averaging let a long word hide one
                    // letter it never went near ("address" over "adds").

                    // Length prior: a path much longer or shorter than the word's is suspect.
                    let idealLength = Self.length(of: path)
                    let lengthPenalty = abs(log((drawnLength + 0.5 * kw) / (idealLength + 0.5 * kw)))

                    geometry = min(geometry, shape
                        + Self.endpointWeight * endpoints
                        + Self.locationWeight * location
                        + Self.lengthWeight * kw * lengthPenalty)
                }

                // Start key, graded by how far the touch-down was from this word's
                // first letter (at full width: the first key is under the thumb).
                var startMismatch = 0.0
                if startIndex != nil, startIndex != f {
                    let d = Self.distance(first, ideal[0]) / kw
                    startMismatch = Self.startKeyPenalty * kw * min(1, max(0, (d - 0.5) / 0.5))
                }

                // Context: how commonly this word follows the previous one.
                var context = 0.0
                if let prevID, rank < entryBigramID.count, entryBigramID[rank] != UInt32.max,
                   let s = bigramScore(prev: prevID, word: entryBigramID[rank]) {
                    context = min(Self.contextCap, max(0, Double(s) / 10 - Self.contextFloor))
                }

                let score = geometry
                    + startMismatch
                    + Self.frequencyWeight * kw * log10(Double(rank) + 1)
                    - Self.contextWeight * kw * context

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
        loadBigrams()
        rebuildBuckets()
    }

    /// Must be called with `lock` held, after the lexicon. Absent or unreadable,
    /// the decoder simply runs without context.
    private func loadBigrams() {
        guard let url = Bundle.main.url(forResource: "swipe-bigrams", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var ids = [String: UInt32]()
        func id(_ s: Substring) -> UInt32 {
            let key = String(s)
            if let i = ids[key] { return i }
            let i = UInt32(ids.count)
            ids[key] = i
            return i
        }
        var pairs = [(key: UInt64, score: UInt8)]()
        pairs.reserveCapacity(270_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let s = UInt8(parts[2]) else { continue }
            pairs.append(((UInt64(id(parts[0])) << 32) | UInt64(id(parts[1])), s))
        }
        pairs.sort { $0.key < $1.key }
        bigramKeys = pairs.map(\.key)
        bigramScores = pairs.map(\.score)
        bigramID = ids
    }

    /// Binary search for a pair's score.
    private func bigramScore(prev: UInt32, word: UInt32) -> UInt8? {
        let target = (UInt64(prev) << 32) | UInt64(word)
        var lo = 0, hi = bigramKeys.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let k = bigramKeys[mid]
            if k == target { return bigramScores[mid] }
            if k < target { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Must be called with `lock` held.
    private func rebuildBuckets() {
        var buckets = [[Int]](repeating: [], count: 26)
        for (i, e) in entries.enumerated() {
            if let f = e.keys.first { buckets[f].append(i) }
        }
        byFirstLetter = buckets
        entryBigramID = entries.map { bigramID[$0.keysText] ?? UInt32.max }
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
        return Entry(keys: keys, keysText: keysText.lowercased(), output: output)
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

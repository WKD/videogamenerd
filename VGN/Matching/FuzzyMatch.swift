import Foundation

/// Fuzzy title scoring in [0, 1] built on the normalisation ladder, plus a
/// `bestMatch` ranker with confidence thresholds. Foundation-only; the string
/// metrics (Levenshtein, Jaro-Winkler) are implemented here.
enum FuzzyMatch {

    // MARK: - Thresholds

    /// Scores at or above this are confident matches (auto-selectable).
    static let confidentThreshold = 0.90
    /// Scores at or above this are plausible (offer to the user).
    static let plausibleThreshold = 0.74

    enum Confidence: Equatable, Sendable {
        case confident, plausible, none
    }

    static func classify(_ score: Double) -> Confidence {
        if score >= confidentThreshold { return .confident }
        if score >= plausibleThreshold { return .plausible }
        return .none
    }

    // MARK: - Scoring

    /// Similarity of two raw titles in [0, 1]. Walks the normalisation ladder:
    /// exact canonical → exact articleless → exact core → fuzzy (token-sort and
    /// edit-distance), taking the best signal. Remaster/HD/etc. are preserved, so
    /// "The Last of Us" vs "The Last of Us Remastered" scores well below confident.
    static func score(_ a: String, _ b: String) -> Double {
        let c1a = TitleNormalizer.normalize(a, level: .canonical)
        let c1b = TitleNormalizer.normalize(b, level: .canonical)
        if !c1a.isEmpty && c1a == c1b { return 1.0 }

        let c2a = TitleNormalizer.normalize(a, level: .articleless)
        let c2b = TitleNormalizer.normalize(b, level: .articleless)
        if !c2a.isEmpty && c2a == c2b { return 0.97 }

        let c3a = TitleNormalizer.normalize(a, level: .core)
        let c3b = TitleNormalizer.normalize(b, level: .core)
        if !c3a.isEmpty && c3a == c3b { return 0.90 }

        // Fuzzy on the articleless form: token-sort (order-insensitive but
        // length-sensitive) and raw edit distance. Jaro-Winkler is deliberately
        // NOT used here — its shared-prefix boost wrongly rewards numbered
        // sequels ("Final Fantasy X" vs "X-2") and remaster suffixes. It stays
        // available as a public utility for callers who want it.
        let ts = tokenSortRatio(c2a, c2b)
        let lev = levenshteinRatio(c2a, c2b)
        return max(ts, lev)
    }

    /// Best score of `query` against any of `names` (alternative titles).
    static func bestScore(query: String, names: [String]) -> Double {
        names.reduce(0.0) { Swift.max($0, score(query, $1)) }
    }

    // MARK: - Ranking

    struct Scored<ID: Sendable>: Sendable {
        var id: ID
        var score: Double
        var confidence: Confidence
        /// The candidate name that produced the best score.
        var matchedName: String
    }

    /// Rank `candidates` (each with one or more names / alternative titles) against
    /// `query`, best first. Ties broken by matched-name order for determinism.
    static func bestMatch<ID: Sendable>(
        query: String,
        candidates: [(id: ID, names: [String])]
    ) -> [Scored<ID>] {
        var scored: [Scored<ID>] = []
        for candidate in candidates {
            var best = 0.0
            var bestName = candidate.names.first ?? ""
            for name in candidate.names {
                let s = score(query, name)
                if s > best { best = s; bestName = name }
            }
            scored.append(Scored(id: candidate.id, score: best, confidence: classify(best), matchedName: bestName))
        }
        return scored.sorted { $0.score > $1.score }
    }

    // MARK: - Token metrics

    /// Sort each string's tokens, rejoin, then compare by edit distance ratio.
    /// Order-insensitive but length-sensitive (an extra token like "remastered"
    /// still costs), which keeps distinct editions apart.
    static func tokenSortRatio(_ a: String, _ b: String) -> Double {
        let sa = a.split(separator: " ").sorted().joined(separator: " ")
        let sb = b.split(separator: " ").sorted().joined(separator: " ")
        return levenshteinRatio(sa, sb)
    }

    // MARK: - Edit distance

    /// Levenshtein distance (iterative two-row, O(n·m) time, O(min) space).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars)
        let y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(
                    prev[j] + 1,          // deletion
                    cur[j - 1] + 1,       // insertion
                    prev[j - 1] + cost    // substitution
                )
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// 1 − distance / maxLen, in [0, 1]. Empty vs empty is 1.
    static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let maxLen = Swift.max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        return 1.0 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    /// Jaro-Winkler similarity in [0, 1], boosting common prefixes (good for short
    /// titles / typos).
    static func jaroWinkler(_ a: String, _ b: String, prefixScale: Double = 0.1) -> Double {
        let s1 = Array(a.unicodeScalars)
        let s2 = Array(b.unicodeScalars)
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let matchDistance = Swift.max(s1.count, s2.count) / 2 - 1
        var s1Matches = [Bool](repeating: false, count: s1.count)
        var s2Matches = [Bool](repeating: false, count: s2.count)
        var matches = 0

        for i in 0..<s1.count {
            let start = Swift.max(0, i - matchDistance)
            let end = Swift.min(i + matchDistance + 1, s2.count)
            if start >= end { continue }
            for j in start..<end where !s2Matches[j] && s1[i] == s2[j] {
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }

        // Transpositions.
        var k = 0
        var transpositions = 0
        for i in 0..<s1.count where s1Matches[i] {
            while !s2Matches[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - Double(transpositions) / 2) / m) / 3

        // Common prefix up to 4.
        var prefix = 0
        for i in 0..<Swift.min(4, Swift.min(s1.count, s2.count)) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * prefixScale * (1 - jaro)
    }
}

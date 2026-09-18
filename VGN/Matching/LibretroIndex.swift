import Foundation

/// An in-memory, per-platform index of libretro-thumbnail filenames built once
/// (thousands of names) for fast fuzzy lookup by IGDB title.
///
/// Build cost is O(n); a lookup buckets by the query's first significant token so
/// only a handful of candidates are scored. The reverse of romlord's forward
/// tag-stripping ladder: romlord had exact DAT names and stripped tags to compare;
/// here we only have an IGDB title, so we normalise both sides to a common
/// "libretro key" and fuzzy-match.
struct LibretroIndex: Sendable {

    /// Region preference, best first. Default: Europe/France → USA → World → Japan.
    static let defaultRegionPreference = ["Europe", "France", "USA", "World", "Japan"]

    struct Entry: Sendable {
        var filename: String
        var parsed: LibretroFilename
        var key: String          // libretro matching key of the title
        var firstToken: String
    }

    struct Match: Equatable, Sendable {
        var filename: String
        var score: Double
        var region: String?
        var disc: Int?
    }

    private let entries: [Entry]
    private let buckets: [String: [Int]]   // firstToken → entry indices
    private let regionRank: [String: Int]

    init(filenames: [String], regionPreference: [String] = LibretroIndex.defaultRegionPreference) {
        var entries: [Entry] = []
        var buckets: [String: [Int]] = [:]
        entries.reserveCapacity(filenames.count)
        for name in filenames {
            let parsed = LibretroFilenameParser.parse(name)
            let key = Self.libretroKey(parsed.title)
            let first = key.split(separator: " ").first.map(String.init) ?? ""
            let idx = entries.count
            entries.append(Entry(filename: name, parsed: parsed, key: key, firstToken: first))
            buckets[first, default: []].append(idx)
        }
        self.entries = entries
        self.buckets = buckets
        var rank: [String: Int] = [:]
        for (i, r) in regionPreference.enumerated() { rank[r] = i }
        self.regionRank = rank
    }

    var count: Int { entries.count }

    /// Best filename for a title (and optional alternative names), or `nil` if
    /// nothing plausible is found. Applies region/disc/prerelease preferences among
    /// equally-scoring title variants.
    func match(title: String, alternativeNames: [String] = []) -> Match? {
        let queries = [title] + alternativeNames
        let queryKeys = queries.map { Self.libretroKey($0) }

        // Collect candidate entry indices from the buckets of every query's first
        // token (plus a light fallback described below).
        var candidateIdx = Set<Int>()
        for qk in queryKeys {
            guard let first = qk.split(separator: " ").first.map(String.init) else { continue }
            if let bucket = buckets[first] { candidateIdx.formUnion(bucket) }
        }
        // Fallback: if the first-token bucket was empty/weak, also consider entries
        // whose first token starts the query (handles numeral/article edge cases).
        if candidateIdx.isEmpty {
            for (token, idxs) in buckets where queryKeys.contains(where: { $0.hasPrefix(token) }) {
                candidateIdx.formUnion(idxs)
            }
        }
        guard !candidateIdx.isEmpty else { return nil }

        // Score each candidate against the best query key.
        struct Ranked { var entry: Entry; var score: Double }
        var ranked: [Ranked] = []
        ranked.reserveCapacity(candidateIdx.count)
        for i in candidateIdx {
            let e = entries[i]
            var best = 0.0
            for qk in queryKeys {
                let s = FuzzyMatch.tokenSortRatio(qk, e.key)
                let lev = FuzzyMatch.levenshteinRatio(qk, e.key)
                best = Swift.max(best, Swift.max(s, lev))
            }
            ranked.append(Ranked(entry: e, score: best))
        }

        guard let topScore = ranked.map(\.score).max(), topScore >= FuzzyMatch.plausibleThreshold else {
            return nil
        }

        // Among the best-scoring title variants, apply selection preferences.
        let epsilon = 1e-9
        let contenders = ranked.filter { $0.score >= topScore - epsilon }
        let chosen = contenders.min { lhs, rhs in
            selectionKey(lhs.entry) < selectionKey(rhs.entry)
        }!
        return Match(
            filename: chosen.entry.filename,
            score: chosen.score,
            region: chosen.entry.parsed.regions.first,
            disc: chosen.entry.parsed.disc
        )
    }

    /// Ordering key for choosing among equal-title variants (smaller = preferred):
    /// prerelease last, then region preference, then Disc 1, then higher revision,
    /// then filename for stability.
    private func selectionKey(_ e: LibretroIndex.Entry) -> SelectionKey {
        let regionR = e.parsed.regions.compactMap { regionRank[$0] }.min() ?? Int.max
        let discPref = (e.parsed.disc ?? 1) == 1 ? 0 : (e.parsed.disc ?? 1)
        // Higher revision preferred → negate a numeric revision, unknown = 0.
        let revScore = -(Int(e.parsed.revision ?? "") ?? 0)
        return SelectionKey(
            prerelease: e.parsed.isPrerelease ? 1 : 0,
            region: regionR,
            disc: discPref,
            revision: revScore,
            filename: e.filename
        )
    }

    private struct SelectionKey: Comparable {
        var prerelease: Int
        var region: Int
        var disc: Int
        var revision: Int
        var filename: String
        static func < (l: SelectionKey, r: SelectionKey) -> Bool {
            if l.prerelease != r.prerelease { return l.prerelease < r.prerelease }
            if l.region != r.region { return l.region < r.region }
            if l.disc != r.disc { return l.disc < r.disc }
            if l.revision != r.revision { return l.revision < r.revision }
            return l.filename < r.filename
        }
    }

    // MARK: - Key

    /// The normalisation used on both sides of a libretro match. It reverses the
    /// libretro character substitution by treating `_` and the substituted
    /// punctuation as separators, and drops articles plus "and" so that
    /// "Ratchet & Clank" (→ "Ratchet _ Clank" in a filename) still matches.
    static func libretroKey(_ raw: String) -> String {
        var s = TitleNormalizer.foldBasics(raw)
        // Treat underscores and libretro-substituted punctuation as spaces.
        for ch in ["_", "&", "*", "/", ":", "`", "<", ">", "?", "\\", "|", "\""] {
            s = s.replacingOccurrences(of: ch, with: " ")
        }
        // Canonicalise (punctuation→space, roman→arabic).
        s = TitleNormalizer.canonicalize(s)
        let drop: Set<String> = TitleNormalizer.leadingArticles.union(["and"])
        let tokens = s.split(separator: " ").map(String.init).filter { !drop.contains($0) }
        return tokens.joined(separator: " ")
    }
}

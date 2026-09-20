import Foundation

/// One IGDB match candidate for a scanned spine.
struct ScanMatch: Sendable, Equatable, Codable {
    var igdbID: Int64
    var name: String
    var releaseYear: Int?
    var coverImageID: String?
    var platformSlugs: [String]
    var score: Double
    var matchedName: String
    /// The IGDB `game_type` of the matched candidate, when known (PLAN §5.1). Carried so
    /// the import review / reconcile can detect a bundle match and expand it into a
    /// compilation. `nil` for matches built before the type was known (e.g. an explicit
    /// inline "Find…" pick) — the caller then re-checks on demand.
    var gameType: IGDBGameType? = nil
    /// When the match is a **port** (11), the id of its parent game (`version_parent` /
    /// `parent_game`), so the sync can fold it onto the original in ONE batched
    /// `games(ids:)` per sync (PLAN §5.1 D4). `nil` when unknown / not a port.
    var foldParentID: Int64? = nil
    /// Set when this match IS a parent game a **port** match was redirected onto — the
    /// review row then shows "links to the original" (PLAN §5.1 D4).
    var resolvedFromPortID: Int64? = nil

    /// The matched candidate is a bundle/pack whose members VGN can expand (PLAN §5.1).
    var isBundle: Bool { gameType?.isCompilation ?? false }
    /// A port with a resolvable parent (PLAN §5.1 D4).
    var isResolvablePort: Bool { gameType == .port && foldParentID != nil }
}

extension ScanMatch {
    /// Build the match a resolvable **port** is redirected onto: its parent game, keeping
    /// the port's score / matched name and remembering the port id (PLAN §5.1 D4).
    init(resolvingPort port: ScanMatch, to parent: IGDBGameMetadata) {
        self.init(
            igdbID: parent.id,
            name: parent.name,
            releaseYear: parent.releaseYear,
            coverImageID: parent.coverImageID,
            platformSlugs: parent.platformSlugs,
            score: port.score,
            matchedName: port.matchedName,
            gameType: parent.gameType,
            foldParentID: nil,
            resolvedFromPortID: port.igdbID)
    }
}

/// Confidence bucket for the review sheet (PLAN §6.2 step 5).
enum ScanConfidenceBucket: String, Sendable, Equatable, Codable {
    case confident, plausible, none
}

/// The outcome of matching one spine: best match + alternatives + bucket.
struct ScanMatchOutcome: Sendable, Equatable, Codable {
    var best: ScanMatch?
    var alternatives: [ScanMatch]
    var bucket: ScanConfidenceBucket
}

/// Pure IGDB match scoring for scanned spines (PLAN §6.2 step 4). Foundation only;
/// takes a pre-fetched candidate list (the pipeline / harness does the network I/O),
/// so it is trivially testable and reusable. Uses the shared `FuzzyMatch` ladder.
enum ScanMatching {

    /// Search queries to try for a spine, in priority order. Printed title first (as
    /// boxed), then the model's normalised guess, then a subtitle-stripped form — a
    /// workaround for IGDB `search` missing alt-name-only French titles (e.g. "Les
    /// Chevaliers de Baphomet"): searching the shorter main title finds the English
    /// game whose `alternative_names` we then match against.
    static func queries(printedTitle: String, normalizedGuess: String?) -> [String] {
        var out: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            if !out.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { out.append(s) }
        }
        add(printedTitle)
        add(normalizedGuess)
        // Subtitle-stripped main title (helps French / long edition titles).
        let core = TitleNormalizer.normalize(printedTitle, level: .core)
        if core.split(separator: " ").count >= 1, core != TitleNormalizer.normalize(printedTitle, level: .canonical) {
            add(core)
        }
        if let normalizedGuess {
            add(TitleNormalizer.normalize(normalizedGuess, level: .core))
        }
        return out
    }

    /// Score `candidates` against a spine and bucket the best.
    /// - Parameters:
    ///   - printedTitle: the title as boxed (primary query).
    ///   - normalizedGuess: the recogniser's canonical guess (secondary).
    ///   - platformSlug: the spine's platform, used only as a deterministic tie-break
    ///     (search is already platform-constrained by the caller when possible).
    static func rank(
        printedTitle: String,
        normalizedGuess: String?,
        platformSlug: String?,
        candidates: [IGDBSearchResult]
    ) -> ScanMatchOutcome {
        guard !candidates.isEmpty else {
            return ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
        }
        let queries = [printedTitle, normalizedGuess].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var scored: [ScanMatch] = []
        for candidate in candidates {
            let names = [candidate.name] + candidate.alternativeNames
            var best = 0.0
            var bestName = candidate.name
            for query in queries {
                for name in names {
                    let s = FuzzyMatch.score(query, name)
                    if s > best { best = s; bestName = name }
                }
            }
            scored.append(ScanMatch(
                igdbID: candidate.id,
                name: candidate.name,
                releaseYear: candidate.releaseYear,
                coverImageID: candidate.coverImageID,
                platformSlugs: candidate.platformSlugs,
                score: best,
                matchedName: bestName,
                gameType: candidate.gameType,
                foldParentID: candidate.foldParentID
            ))
        }

        // Sort by score, breaking ties toward the platform-matching candidate, then id.
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lp = platformSlug.map { lhs.platformSlugs.contains($0) } ?? false
            let rp = platformSlug.map { rhs.platformSlugs.contains($0) } ?? false
            if lp != rp { return lp }
            return lhs.igdbID < rhs.igdbID
        }

        guard let best = sorted.first else {
            return ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
        }
        let bucket = bucket(for: best.score)
        // Alternatives: the next candidates at or above the plausible threshold.
        let alternatives = sorted.dropFirst()
            .filter { $0.score >= FuzzyMatch.plausibleThreshold }
            .prefix(4)
        return ScanMatchOutcome(
            best: bucket == .none ? nil : best,
            alternatives: Array(alternatives),
            bucket: bucket
        )
    }

    static func bucket(for score: Double) -> ScanConfidenceBucket {
        switch FuzzyMatch.classify(score) {
        case .confident: return .confident
        case .plausible: return .plausible
        case .none: return .none
        }
    }
}

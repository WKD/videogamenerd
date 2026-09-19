import Foundation

/// libretro-thumbnails cover provider (PLAN §5.2, source 1). For each platform slug
/// that has a `libretroRepo`, fetch the repo's `Named_Boxarts` listing (once, cached),
/// build a `LibretroIndex`, fuzzy-match the title + alternative names, and emit a
/// `raw.githubusercontent.com/...` URL per match. Only matches at/above
/// `FuzzyMatch.confidentThreshold` are marked confident ("good hit"); merely
/// plausible ones stay as browsable candidates (PLAN §5.2).
struct LibretroCoverProvider: CoverProvider {
    let id = "libretro"
    private let catalog: PlatformCatalog
    private let listing: LibretroRepoListing
    private let rawBase: URL

    init(
        catalog: PlatformCatalog,
        listing: LibretroRepoListing,
        rawBase: URL = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails")!
    ) {
        self.catalog = catalog
        self.listing = listing
        self.rawBase = rawBase
    }

    func candidates(for query: CoverQuery) async -> [CoverCandidate] {
        await probe(for: query).candidates
    }

    /// Distinguishes a genuine miss from an unreachable listing: if a platform has
    /// a repo but its listing cannot be fetched (`listing.listing` returns nil),
    /// that is a transient failure, not "no cover exists" — so the caller must not
    /// write a 7-day negative sentinel (PLAN §5.2 / §9).
    func probe(for query: CoverQuery) async -> CoverProbe {
        var out: [CoverCandidate] = []
        var sawUnreachableRepo = false
        for slug in query.platformSlugs {
            guard let repo = catalog.libretroRepo(forSlug: slug) else { continue }
            guard let resolved = await listing.listing(repo: repo) else {
                sawUnreachableRepo = true       // couldn't fetch the listing → transient
                continue
            }
            guard !resolved.filenames.isEmpty else { continue }

            let index = LibretroIndex(
                filenames: resolved.filenames,
                regionPreference: query.preferredRegions
            )
            guard let match = index.match(
                title: query.title,
                alternativeNames: query.alternativeNames
            ) else { continue }

            guard let url = boxArtURL(repo: repo, branch: resolved.branch, filename: match.filename) else { continue }
            let regionLabel = match.region.map { " · \($0)" } ?? ""
            out.append(CoverCandidate(
                providerID: id,
                remoteURL: url,
                label: "libretro\(regionLabel)",
                score: match.score,
                isConfident: match.score >= FuzzyMatch.confidentThreshold
            ))
        }
        // Best (and confident) first.
        let sorted = out.sorted { ($0.isConfident ? 1 : 0, $0.score) > ($1.isConfident ? 1 : 0, $1.score) }
        // Only a *pure* transient failure (nothing found AND a repo was
        // unreachable) suppresses the sentinel; a found candidate always wins.
        if sorted.isEmpty && sawUnreachableRepo { return .transientFailure }
        return .found(sorted)
    }

    /// **Every** boxart of the best-matching title across regions/discs/revisions —
    /// the browsable set for the "Choose Cover…" sheet (PLAN §5.2 step 4). Unlike
    /// ``candidates(for:)``/``probe(for:)``, which pick a single best file, this keeps
    /// the whole top-score cluster: all variants of one title share the same libretro
    /// key (region/disc/revision tags are stripped), so they score identically and
    /// come through together, while a near but different title (a numbered sequel)
    /// scores lower and is dropped. Best-first, then by region preference;
    /// de-duplicated and capped.
    func allCandidates(for query: CoverQuery) async -> [CoverCandidate] {
        let queryKeys = ([query.title] + query.alternativeNames).map(LibretroIndex.libretroKey)
        var regionRank: [String: Int] = [:]
        for (i, r) in query.preferredRegions.enumerated() { regionRank[r] = i }

        struct Scored { var candidate: CoverCandidate; var score: Double; var regionRank: Int }
        var scored: [Scored] = []
        var seen = Set<String>()

        for slug in query.platformSlugs {
            guard let repo = catalog.libretroRepo(forSlug: slug) else { continue }
            guard let resolved = await listing.listing(repo: repo) else { continue }
            for filename in resolved.filenames {
                let parsed = LibretroFilenameParser.parse(filename)
                let key = LibretroIndex.libretroKey(parsed.title)
                guard !key.isEmpty else { continue }
                var best = 0.0
                for qk in queryKeys where !qk.isEmpty {
                    best = Swift.max(best, Swift.max(
                        FuzzyMatch.tokenSortRatio(qk, key),
                        FuzzyMatch.levenshteinRatio(qk, key)))
                }
                guard best >= FuzzyMatch.plausibleThreshold else { continue }
                guard let url = boxArtURL(repo: repo, branch: resolved.branch, filename: filename),
                      seen.insert(url.absoluteString).inserted else { continue }
                let region = parsed.regions.first
                let regionLabel = region.map { " · \($0)" } ?? ""
                let rank = parsed.regions.compactMap { regionRank[$0] }.min() ?? Int.max
                scored.append(Scored(
                    candidate: CoverCandidate(
                        providerID: id,
                        remoteURL: url,
                        label: "libretro\(regionLabel)",
                        score: best,
                        isConfident: best >= FuzzyMatch.confidentThreshold,
                        region: region),
                    score: best,
                    regionRank: rank))
            }
        }
        // Keep only the top-score cluster — the region/disc/revision variants of the
        // best-matching title — so a near but different title (a sequel) is dropped.
        guard let top = scored.map(\.score).max() else { return [] }
        scored = scored.filter { $0.score >= top - 1e-9 }
        // Best score first, then preferred region, then filename for stability.
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.regionRank != $1.regionRank { return $0.regionRank < $1.regionRank }
            return $0.candidate.remoteURL.absoluteString < $1.candidate.remoteURL.absoluteString
        }
        return Array(scored.prefix(Self.maxBrowsableCandidates).map(\.candidate))
    }

    /// Hard cap on browsable libretro candidates so a loose match on a huge repo
    /// can't flood the sheet with hundreds of tiles.
    static let maxBrowsableCandidates = 60

    /// `…/libretro-thumbnails/<repo>/<branch>/Named_Boxarts/<percent-encoded name>`.
    func boxArtURL(repo: String, branch: String, filename: String) -> URL? {
        var components = URLComponents(url: rawBase, resolvingAgainstBaseURL: false)
        var path = rawBase.path
        if !path.hasSuffix("/") { path += "/" }
        path += "\(repo)/\(branch)/Named_Boxarts/\(filename)"
        // Setting `path` percent-encodes the filename's spaces, commas, parens, etc.
        components?.path = path
        return components?.url
    }
}

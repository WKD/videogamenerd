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
        var out: [CoverCandidate] = []
        for slug in query.platformSlugs {
            guard let repo = catalog.libretroRepo(forSlug: slug) else { continue }
            guard let resolved = await listing.listing(repo: repo), !resolved.filenames.isEmpty else { continue }

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
        return out.sorted { ($0.isConfident ? 1 : 0, $0.score) > ($1.isConfident ? 1 : 0, $1.score) }
    }

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

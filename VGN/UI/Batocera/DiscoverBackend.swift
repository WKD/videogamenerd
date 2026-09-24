import Foundation

/// The data seam the "Discover on your Batocera" row reads through (PLAN §15), behind a
/// protocol so ``DiscoverModel`` is unit-tested against a fake with no database. A `Sendable`
/// value. All reads are of local tables (`rom_catalog`, ranking) — never the share.
protocol DiscoverBackend: Sendable {
    /// The owner's ranked games as the taste profile (tiers → 0…1 scores + traits).
    func rankedGames() async throws -> [RankedGame]
    /// The "From the vault" candidate pool over BOTH sources (PLAN §16): never-played Batocera
    /// ROMs + matched PS Plus entries, not promoted, not dismissed.
    func pool(limit: Int) async throws -> [RomCatalogEntry]
    /// Systems the owner has real play time on (the small affinity nudge).
    func playedSystems() async throws -> Set<String>
    /// Title + tier for each cited exemplar id (for the reason sentences).
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo]
    /// Retire an entry from Discover for good ("Not Interested").
    func setNotInterested(catalogID: Int64) async throws
    /// The taste half of an "Ask Claude" request (tier list + "didn't click") for the vault
    /// second opinion (PLAN §7b). Defaults to empty for fakes that don't care.
    func secondOpinionTaste() async throws -> SecondOpinionTaste
}

extension DiscoverBackend {
    func secondOpinionTaste() async throws -> SecondOpinionTaste { .empty }
}

/// Forwards the Discover seam to the real stores.
struct LiveDiscoverBackend: DiscoverBackend {
    let recommendation: RecommendationStore
    let catalog: RomCatalogStore
    let library: LibraryStore

    func rankedGames() async throws -> [RankedGame] { try await recommendation.rankedGames() }
    func pool(limit: Int) async throws -> [RomCatalogEntry] {
        try await catalog.vaultPool(limit: limit)
    }
    func playedSystems() async throws -> Set<String> { try await catalog.playedSystems() }
    func secondOpinionTaste() async throws -> SecondOpinionTaste {
        try await recommendation.secondOpinionTaste()
    }
    func setNotInterested(catalogID: Int64) async throws {
        try await catalog.setNotInterested(catalogID: catalogID)
    }

    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ExemplarInfo] = [:]
        for id in Set(ids) {
            if let detail = try await library.gameDetail(id: id) {
                out[id] = ExemplarInfo(title: detail.title, tierLetter: detail.tierLetter)
            }
        }
        return out
    }
}

/// An empty backend for previews / non-live modes: no ranked games, no pool — the Discover
/// row stays hidden.
struct InertDiscoverBackend: DiscoverBackend {
    func rankedGames() async throws -> [RankedGame] { [] }
    func pool(limit: Int) async throws -> [RomCatalogEntry] { [] }
    func playedSystems() async throws -> Set<String> { [] }
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] { [:] }
    func setNotInterested(catalogID: Int64) async throws {}
}

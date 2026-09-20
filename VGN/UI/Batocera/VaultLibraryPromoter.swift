import Foundation

/// Adds a PS Plus Vault entry to the library as an **owned-via-subscription** copy (PLAN §16),
/// through the shared staging commit path (the same `ImportStagingStore.commit` the PSN review
/// uses), then links the Vault row to the created game via
/// ``RomCatalogStore/setPromotedByExternalID`` so the browser shows "In Library" and the
/// promotion-on-play bridge is set. Pure I/O over the stores; unit-tested with an in-memory DB.
struct VaultLibraryPromoter: Sendable {
    let staging: ImportStagingStore
    let catalog: RomCatalogStore
    /// Strips ™/®/©/℠ from the display name for the library title (PLAN §16 — reuse the cleaner).
    let cleanTitle: @Sendable (String) -> String

    init(staging: ImportStagingStore, catalog: RomCatalogStore,
         cleanTitle: @escaping @Sendable (String) -> String = { PSNMapping.cleanMatchTitle($0) }) {
        self.staging = staging
        self.catalog = catalog
        self.cleanTitle = cleanTitle
    }

    /// Add one entry. Returns the library game id, or nil if nothing was created (e.g. the entry
    /// was already promoted). `LibraryStore` dedupes a new game by IGDB id, so re-adding a game
    /// already present just attaches the subscription copy.
    @discardableResult
    func addToLibrary(_ entry: RomCatalogEntry) async throws -> Int64? {
        guard entry.vaultSource == .psn else { return nil }
        let spec = ImportNewGameSpec(
            title: cleanTitle(entry.name), igdbID: entry.igdbID, releaseYear: entry.releaseYear)
        let item = ImportCommitItem(
            source: VaultSource.psn.storage, externalID: entry.externalID,
            platformID: entry.platformID ?? entry.system, format: .digital,
            target: .newGame(spec),
            psn: PSNCommit(createProduct: true, subscription: "ps_plus"))
        let result = try await staging.commit([item])
        guard let gameID = result.affectedGameIDs.first else { return nil }
        try await catalog.setPromotedByExternalID(
            source: VaultSource.psn.storage, externalID: entry.externalID, gameID: gameID)
        return gameID
    }

    /// Add several entries (the browser's multi-select "Add to Library…").
    func addToLibrary(ids: [Int64]) async throws {
        let entries = try await catalog.entries(ids: ids)
        for entry in entries { _ = try await addToLibrary(entry) }
    }
}

/// The manual "Find match…" seam for a PS Plus entry (PLAN §16): the IGDB searcher the reconcile
/// link sheet uses, the platform→IGDB-id resolver, and an `apply` that fetches the chosen game's
/// traits / rating / time-to-beat and persists them (``RomCatalogStore/setVaultMatch``),
/// overriding an earlier no-match. Present only when IGDB is configured (nil otherwise).
struct VaultFindMatchSeam: Sendable {
    let searcher: any CatalogSearching
    let platformIGDBIDs: @Sendable (String?) -> [Int]
    /// Fetch traits for `igdbID` and persist the match on the catalogue row `catalogID`.
    let apply: @Sendable (_ catalogID: Int64, _ igdbID: Int64) async -> Void
}

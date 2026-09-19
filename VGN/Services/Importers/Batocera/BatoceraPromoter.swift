import Foundation
import GRDB

/// Commits Batocera promotions through the existing importer commit path and links the
/// catalogue rows to the games they became (PLAN §15). Phase 1 exposes the mechanics; phase 2
/// supplies the IGDB match decisions (which catalogue entry maps to which existing game / a
/// new game, and whether that game already owns a ROM copy).
struct BatoceraPromoter: Sendable {
    let catalog: RomCatalogStore
    let staging: ImportStagingStore
    private let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
        self.catalog = RomCatalogStore(database)
        self.staging = ImportStagingStore(database)
    }

    /// One promotion: a catalogue entry, its resolved commit target, and whether the target
    /// already owns a ROM copy on the same platform (⇒ no second copy, "Already in library").
    struct Plan: Sendable {
        var entry: RomCatalogEntry
        var target: ImportCommitItem.Target
        var alreadyHasROMCopy: Bool

        init(entry: RomCatalogEntry, target: ImportCommitItem.Target, alreadyHasROMCopy: Bool = false) {
            self.entry = entry
            self.target = target
            self.alreadyHasROMCopy = alreadyHasROMCopy
        }
    }

    struct Result: Sendable {
        var commit: ImportCommitResult
        /// Catalogue ids whose `promoted_game_id` was set.
        var promotedCatalogIDs: [Int64]
    }

    /// Commit the plans in one importer transaction, then link each catalogue row to its game.
    @discardableResult
    func promote(_ plans: [Plan]) async throws -> Result {
        guard !plans.isEmpty else { return Result(commit: ImportCommitResult(), promotedCatalogIDs: []) }
        let items = plans.map {
            BatoceraPromotionBuilder.commitItem(for: $0.entry, target: $0.target,
                                                alreadyHasROMCopy: $0.alreadyHasROMCopy)
        }
        let commit = try await staging.commit(items)

        var promoted: [Int64] = []
        for plan in plans {
            let gameID: Int64?
            switch plan.target {
            case .existingGame(let id):
                gameID = id
            case .newGame:
                gameID = try await self.gameID(forExternalID: plan.entry.externalID)
            case .compilation:
                gameID = nil          // Batocera never promotes a compilation.
            }
            if let gameID {
                try await catalog.setPromoted(catalogID: plan.entry.id, gameID: gameID)
                promoted.append(plan.entry.id)
            }
        }
        return Result(commit: commit, promotedCatalogIDs: promoted)
    }

    /// Whether a library game already owns a ROM copy on a platform (the duplicate rule input,
    /// PLAN §15). Phase 2 calls this on the IGDB-matched game before building a ``Plan``.
    func gameHasROMCopy(gameID: Int64, platformID: String) async throws -> Bool {
        try await database.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: """
                SELECT COUNT(*) FROM products p
                JOIN product_games pg ON pg.product_id = p.id
                WHERE pg.game_id = ? AND p.platform_id = ? AND p.format = 'rom'
                """, arguments: [gameID, platformID]) ?? 0) > 0
        }
    }

    /// The library game already carrying an IGDB id (phase 2 promotion review): a new-game
    /// row whose IGDB match is a game already in the library resolves to it, so the duplicate
    /// rule can add play time only instead of a second ROM copy (PLAN §15).
    func existingGameID(igdbID: Int64) async throws -> Int64? {
        try await database.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM games WHERE igdb_id = ? LIMIT 1",
                               arguments: [igdbID])
        }
    }

    private func gameID(forExternalID externalID: String) async throws -> Int64? {
        try await database.dbWriter.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT pg.game_id FROM products p
                JOIN product_games pg ON pg.product_id = p.id
                WHERE p.source = ? AND p.external_id = ? LIMIT 1
                """, arguments: [ImportSourceID.batocera, externalID])
        }
    }
}

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

    /// A bundle expansion for a Batocera promotion (D2, PLAN §5.1): a ROM whose confident IGDB
    /// match is a bundle/pack promotes as a **compilation** `rom` copy with these member games,
    /// like GOG/Delicious. Empty members ⇒ not a usable bundle (falls back to a single).
    struct BundlePromotion: Sendable, Equatable {
        var title: String?
        var members: [CompilationMemberDraft]
    }

    /// One promotion: a catalogue entry, its resolved commit target, and whether the target
    /// already owns a ROM copy on the same platform (⇒ no second copy, "Already in library").
    /// When ``bundle`` is set the entry promotes as a compilation and ``target`` is ignored.
    struct Plan: Sendable {
        var entry: RomCatalogEntry
        var target: ImportCommitItem.Target
        var alreadyHasROMCopy: Bool
        /// A bundle expansion (D2) — the entry becomes a compilation `rom` copy with its members.
        var bundle: BundlePromotion?

        init(entry: RomCatalogEntry, target: ImportCommitItem.Target,
             alreadyHasROMCopy: Bool = false, bundle: BundlePromotion? = nil) {
            self.entry = entry
            self.target = target
            self.alreadyHasROMCopy = alreadyHasROMCopy
            self.bundle = bundle
        }

        /// A compilation promotion (D2): the entry, its bundle title + members. `target` is a
        /// placeholder — the compilation path ignores it.
        static func compilation(entry: RomCatalogEntry, bundle: BundlePromotion) -> Plan {
            Plan(entry: entry,
                 target: .newGame(ImportNewGameSpec(title: entry.name, igdbID: entry.igdbID,
                                                    releaseYear: entry.releaseYear)),
                 bundle: bundle)
        }
    }

    struct Result: Sendable {
        var commit: ImportCommitResult
        /// Catalogue ids whose `promoted_game_id` was set.
        var promotedCatalogIDs: [Int64]
    }

    /// Commit the plans in one importer transaction, then link each catalogue row to its game.
    /// A bundle plan (D2) commits as a `rom` **compilation** whose members are the individual
    /// games; its `promoted_game_id` points at the first member and the ROM's play time / last
    /// played land on that member **only when the bundle resolved to exactly one member** (PLAN
    /// §13.3 — otherwise dropped from games, kept on the catalogue row).
    @discardableResult
    func promote(_ plans: [Plan]) async throws -> Result {
        guard !plans.isEmpty else { return Result(commit: ImportCommitResult(), promotedCatalogIDs: []) }
        let items = plans.map { plan -> ImportCommitItem in
            if let bundle = plan.bundle {
                return BatoceraPromotionBuilder.compilationCommitItem(for: plan.entry, bundle: bundle)
            }
            return BatoceraPromotionBuilder.commitItem(for: plan.entry, target: plan.target,
                                                       alreadyHasROMCopy: plan.alreadyHasROMCopy)
        }
        let commit = try await staging.commit(items)

        var promoted: [Int64] = []
        for plan in plans {
            let gameID: Int64?
            if let bundle = plan.bundle {
                // The compilation's first member is the bridge id (In-Library detection reads
                // `promoted_game_id IS NOT NULL`); a one-member bundle also carries the play data.
                gameID = try await firstCompilationMemberGameID(externalID: plan.entry.externalID)
                if bundle.members.count == 1, let memberID = gameID {
                    try await applyBundlePlayData(entry: plan.entry, gameID: memberID)
                }
            } else {
                switch plan.target {
                case .existingGame(let id):
                    gameID = id
                case .newGame:
                    gameID = try await self.gameID(forExternalID: plan.entry.externalID)
                case .compilation:
                    gameID = try await firstCompilationMemberGameID(externalID: plan.entry.externalID)
                }
            }
            if let gameID {
                try await catalog.setPromoted(catalogID: plan.entry.id, gameID: gameID)
                promoted.append(plan.entry.id)
            }
        }
        return Result(commit: commit, promotedCatalogIDs: promoted)
    }

    /// The first member game of a `rom` compilation keyed by `(source, external_id)` — the id
    /// the catalogue row is promoted to (D2). Ordered by member position.
    private func firstCompilationMemberGameID(externalID: String) async throws -> Int64? {
        try await database.dbWriter.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT pg.game_id FROM products p
                JOIN product_games pg ON pg.product_id = p.id
                WHERE p.source = ? AND p.external_id = ?
                ORDER BY pg.position ASC, pg.game_id ASC LIMIT 1
                """, arguments: [ImportSourceID.batocera, externalID])
        }
    }

    /// Apply the ROM's play data to the sole member of a one-member bundle (D2 / PLAN §13.3):
    /// mark it played + set its Batocera play time (monotonic max, v17) + last-played
    /// date. A no-op when the ROM has no play data (a favourite never launched).
    private func applyBundlePlayData(entry: RomCatalogEntry, gameID: Int64) async throws {
        let played = BatoceraPromotion.isPlayed(gameTimeSeconds: entry.gameTimeSeconds)
        guard played || entry.lastPlayedAt != nil else { return }
        try await database.dbWriter.write { db in
            if played {
                try LibraryStore.markPlayedWithoutCopy(gameID: gameID, platformID: entry.platformID, db: db)
                try LibraryStore.setBatoceraPlaytime(
                    gameID: gameID, seconds: entry.gameTimeSeconds, db: db)
            }
            try LibraryStore.setPSNPlayedDates(gameID: gameID, first: nil, last: entry.lastPlayedAt, db: db)
        }
    }

    /// Reverse an auto-add batch in **one transaction** (PLAN §15 — the banner's Undo): for
    /// each promoted favourite, delete the Batocera ROM copy the batch created (keyed by
    /// `(source, external_id)`), delete any game left neither owned nor played (the newly
    /// created ones — a pre-existing owned game survives), and clear `promoted_game_id`.
    /// Idempotent: running it twice (the banner button *and* the undo manager) is a no-op the
    /// second time. Play-time-only additions to a pre-existing game are left as-is.
    func undoAutoAdd(entries: [RomCatalogEntry]) async throws {
        guard !entries.isEmpty else { return }
        try await database.dbWriter.write { db in
            var affectedGames: [Int64] = []
            for entry in entries {
                if let productID = try LibraryStore.existingImportProductID(
                    sourceRaw: ImportSourceID.batocera, externalID: entry.externalID, db: db) {
                    let members = try Int64.fetchAll(
                        db, sql: "SELECT game_id FROM product_games WHERE product_id = ?",
                        arguments: [productID])
                    try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [productID])
                    affectedGames.append(contentsOf: members)
                }
                try db.execute(sql: "UPDATE rom_catalog SET promoted_game_id = NULL WHERE id = ?",
                               arguments: [entry.id])
            }
            // Delete the games the batch created (now orphaned); pre-existing owned/played
            // games are kept.
            _ = try LibraryStore.resolveOrphans(affectedGames, confirmOrphanDelete: true, db: db)
        }
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

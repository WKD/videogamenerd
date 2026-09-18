import Foundation
import GRDB

/// The write API for the library. Every method is one transaction and enforces
/// the PLAN §4 invariants:
///
///  1. A game must be played or owned. An operation that would leave a game
///     neither returns `.wouldOrphan([ids])` and makes **no** change, rather
///     than silently deleting.
///  2. Only played games can carry a tier / rank. Un-playing clears both.
///
/// `Sendable`; a thin value over ``AppDatabase``. Reads/observations live in
/// `LibraryStore` extensions (see `LibraryStore+Reads.swift`).
struct LibraryStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    // MARK: - Adding games

    /// Add one game (deduping on `igdb_id`). See ``AddOutcome``.
    @discardableResult
    func addGame(_ draft: GameDraft) async throws -> AddOutcome {
        try await dbWriter.write { db in try Self.insert(draft, db) }
    }

    /// Add many games in a single transaction (PLAN §6.2 photo/PSN import).
    @discardableResult
    func addGames(_ drafts: [GameDraft]) async throws -> [AddOutcome] {
        try await dbWriter.write { db in try drafts.map { try Self.insert($0, db) } }
    }

    /// Core insert, dedupe and product/played wiring for one draft.
    static func insert(_ draft: GameDraft, _ db: Database) throws -> AddOutcome {
        let impliesPlayed = draft.played || draft.tierID != nil
        let year = draft.year ?? draft.releaseDate.map(Self.year(of:))

        // Dedupe on igdb_id.
        var existing: GameRecord?
        if let igdbID = draft.igdbID {
            existing = try GameRecord.filter(GameRecord.Columns.igdbID == igdbID).fetchOne(db)
        }

        let gameID: Int64
        let isNew: Bool
        if let found = existing, let id = found.id {
            gameID = id
            isNew = false
            // Merge in "played" upward; a tier on add implies played.
            if impliesPlayed && !found.played {
                try db.execute(sql: "UPDATE games SET played = 1, updated_at = ? WHERE id = ?",
                               arguments: [Date(), id])
            }
            if let tier = draft.tierID {
                try setTierRow(gameID: id, tierID: tier, db: db)
            }
            if let status = draft.status {
                try db.execute(sql: "UPDATE games SET status = ?, updated_at = ? WHERE id = ?",
                               arguments: [status.rawValue, Date(), id])
            }
        } else {
            var record = GameRecord(
                igdbID: draft.igdbID,
                title: draft.title,
                sortTitle: SortTitle.make(from: draft.title),
                altTitles: Self.joinAlt(draft.altTitles),
                releaseDate: draft.releaseDate,
                year: year,
                played: impliesPlayed,
                status: draft.status?.rawValue,
                tierID: draft.tierID
            )
            try record.insert(db)
            gameID = record.id!
            isNew = true
        }

        // game_platforms rows for every listed platform.
        for platformID in draft.platformIDs {
            try ensureGamePlatform(gameID: gameID, platformID: platformID,
                                   played: impliesPlayed, db: db)
        }

        // owned ⇒ a single Product on the primary platform.
        var addedProduct = false
        if draft.owned, let platformID = draft.platformIDs.first {
            // Skip if an identical single product on this platform already
            // exists (idempotent re-add of the same copy).
            let already = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM products p
                    JOIN product_games pg ON pg.product_id = p.id
                    WHERE pg.game_id = ? AND p.platform_id = ? AND p.kind = 'single'
                )
                """, arguments: [gameID, platformID]) ?? false
            if !already {
                try makeSingleProduct(
                    gameID: gameID, platformID: platformID,
                    format: draft.format, source: draft.source, db: db
                )
                addedProduct = true
            }
        }

        if isNew { return .created(gameID: gameID) }
        return addedProduct ? .addedCopy(gameID: gameID) : .alreadyPresent(gameID: gameID)
    }

    // MARK: - Compilations

    /// Create one compilation Product with `members` games (each reused if it
    /// already exists), positions preserved. Ownership of all members is
    /// established by this single product — removing it un-owns them all.
    /// Returns the new product id and a per-member outcome.
    @discardableResult
    func addCompilation(
        product: ProductDraft,
        members: [CompilationMemberDraft]
    ) async throws -> (productID: Int64, members: [AddOutcome]) {
        try await dbWriter.write { db in
            var record = ProductRecord(
                title: product.title,
                platformID: product.platformID,
                kind: .compilation,
                format: product.format,
                edition: product.edition,
                region: product.region,
                igdbID: product.igdbID,
                source: product.source,
                acquiredAt: product.acquiredAt
            )
            try record.insert(db)
            let productID = record.id!

            var outcomes: [AddOutcome] = []
            for member in members {
                let outcome = try Self.upsertCompilationMember(member, productID: productID,
                                                               platformID: product.platformID, db: db)
                outcomes.append(outcome)
            }
            return (productID, outcomes)
        }
    }

    /// Add a member to an existing compilation product.
    @discardableResult
    func addCompilationMember(productID: Int64, _ member: CompilationMemberDraft) async throws -> AddOutcome {
        try await dbWriter.write { db in
            guard let platformID = try String.fetchOne(
                db, sql: "SELECT platform_id FROM products WHERE id = ?", arguments: [productID])
            else { throw LibraryError.notFound }
            return try Self.upsertCompilationMember(member, productID: productID,
                                                    platformID: platformID, db: db)
        }
    }

    /// Remove a member from a compilation — un-owns just that member. If the
    /// member ends up neither owned nor played, returns `.wouldOrphan` (no
    /// change) unless `confirmOrphanDelete` is set.
    @discardableResult
    func removeCompilationMember(
        productID: Int64, gameID: Int64, confirmOrphanDelete: Bool = false
    ) async throws -> WriteOutcome {
        try await writeCatchingOrphan { db in
            try db.execute(sql: "DELETE FROM product_games WHERE product_id = ? AND game_id = ?",
                           arguments: [productID, gameID])
            try Self.purgeEmptyProduct(productID, db)
            return try Self.resolveOrphans([gameID], confirmOrphanDelete: confirmOrphanDelete, db: db)
        }
    }

    /// Set the exact ordered membership of a compilation (reorder + reposition).
    /// Games not already members are ignored; existing members keep ownership.
    func reorderCompilationMembers(productID: Int64, orderedGameIDs: [Int64]) async throws {
        try await dbWriter.write { db in
            for (index, gameID) in orderedGameIDs.enumerated() {
                try db.execute(sql: """
                    UPDATE product_games SET position = ? WHERE product_id = ? AND game_id = ?
                    """, arguments: [index, productID, gameID])
            }
        }
    }

    /// Rename a product (e.g. a compilation title).
    func renameProduct(productID: Int64, title: String?) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE products SET title = ?, updated_at = ? WHERE id = ?",
                           arguments: [title, Date(), productID])
        }
    }

    // MARK: - Ownership

    /// Add a standalone owned copy (single Product) for an existing game.
    @discardableResult
    func addCopy(
        gameID: Int64, platformID: String,
        format: ProductFormat = .physical, source: ProductSource = .manual,
        edition: String? = nil, region: String? = nil
    ) async throws -> Int64 {
        try await dbWriter.write { db in
            try Self.ensureGamePlatform(gameID: gameID, platformID: platformID,
                                        played: false, db: db)
            return try Self.makeSingleProduct(gameID: gameID, platformID: platformID,
                                              format: format, source: source,
                                              edition: edition, region: region, db: db)
        }
    }

    /// Remove a product (any kind). Un-owns every member game; compilation
    /// ownership is therefore all-or-nothing. Members left neither owned nor
    /// played trigger `.wouldOrphan` unless `confirmOrphanDelete` is set.
    @discardableResult
    func removeProduct(_ productID: Int64, confirmOrphanDelete: Bool = false) async throws -> WriteOutcome {
        try await writeCatchingOrphan { db in
            let members = try Int64.fetchAll(
                db, sql: "SELECT game_id FROM product_games WHERE product_id = ?",
                arguments: [productID])
            try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [productID])
            return try Self.resolveOrphans(members, confirmOrphanDelete: confirmOrphanDelete, db: db)
        }
    }

    // MARK: - Played / tier / status

    /// Toggle played for a set of games. Un-playing clears tier + rank + status
    /// (invariant 2) and, for a game that is not owned, would orphan it.
    @discardableResult
    func setPlayed(_ gameIDs: [Int64], _ played: Bool, confirmOrphanDelete: Bool = false) async throws -> WriteOutcome {
        try await writeCatchingOrphan { db in
            if played {
                for id in gameIDs {
                    try db.execute(sql: "UPDATE games SET played = 1, updated_at = ? WHERE id = ?",
                                   arguments: [Date(), id])
                }
                return .ok
            }
            // Un-playing: which of these would be orphaned (not owned)?
            let orphans = try gameIDs.filter { !(try Self.isOwned($0, db)) }
            if !orphans.isEmpty && !confirmOrphanDelete {
                throw RollbackWithOutcome(.wouldOrphan(orphans))
            }
            for id in gameIDs {
                try db.execute(sql: """
                    UPDATE games SET played = 0, tier_id = NULL, rank_key = NULL,
                                     status = NULL, updated_at = ? WHERE id = ?
                    """, arguments: [Date(), id])
            }
            for id in orphans where confirmOrphanDelete {
                try Self.deleteGameRow(id, db)
            }
            return .ok
        }
    }

    /// Set (or clear, with `nil`) the tier for played games. Unplayed games are
    /// skipped and reported. A genuine tier *change* clears the fine-rank key
    /// (→ unplaced); re-setting the tier a game already has is a no-op that keeps
    /// its rank. Delegates to ``RankingStore/applySetTier(_:tierID:_:)`` so this
    /// and the ranking views share one implementation (PLAN §7).
    @discardableResult
    func setTier(_ gameIDs: [Int64], tierID: Int64?) async throws -> SetTierOutcome {
        try await dbWriter.write { db in try RankingStore.applySetTier(gameIDs, tierID: tierID, db) }
    }

    /// Set the optional completion status (PLAN §12). `nil` clears it.
    func setStatus(_ gameIDs: [Int64], _ status: PlayStatus?) async throws {
        try await dbWriter.write { db in
            for id in gameIDs {
                try db.execute(sql: "UPDATE games SET status = ?, updated_at = ? WHERE id = ?",
                               arguments: [status?.rawValue, Date(), id])
            }
        }
    }

    /// Set the user's own playtime in seconds (`nil` clears it). Manual value
    /// wins over PSN in the UI (PLAN §6.4); both are kept.
    func setMyPlaytime(gameID: Int64, seconds: Int?) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET my_playtime_s = ?, updated_at = ? WHERE id = ?",
                           arguments: [seconds, Date(), gameID])
        }
    }

    // MARK: - Metadata (enrichment target)

    /// Apply a metadata patch (what enrichment writes: dates, genres, alt
    /// titles, cover, cover image id, time-to-beat). Non-nil fields are set.
    func updateMetadata(gameID: Int64, _ patch: MetadataPatch) async throws {
        try await dbWriter.write { db in
            if let title = patch.title {
                try db.execute(sql: "UPDATE games SET title = ?, sort_title = ? WHERE id = ?",
                               arguments: [title, SortTitle.make(from: title), gameID])
            }
            try Self.setIf(patch.summary, column: "summary", gameID: gameID, db: db)
            try Self.setIf(patch.releaseDate, column: "release_date", gameID: gameID, db: db)
            if let date = patch.releaseDate, patch.year == nil {
                try db.execute(sql: "UPDATE games SET year = ? WHERE id = ?",
                               arguments: [Self.year(of: date), gameID])
            }
            try Self.setIf(patch.year, column: "year", gameID: gameID, db: db)
            try Self.setIf(patch.coverFile, column: "cover_file", gameID: gameID, db: db)
            try Self.setIf(patch.igdbCoverImageID, column: "igdb_cover_image_id", gameID: gameID, db: db)
            try Self.setIf(patch.igdbID, column: "igdb_id", gameID: gameID, db: db)
            try Self.setIf(patch.ttbHastilyS, column: "ttb_hastily_s", gameID: gameID, db: db)
            try Self.setIf(patch.ttbNormallyS, column: "ttb_normally_s", gameID: gameID, db: db)
            try Self.setIf(patch.ttbCompletelyS, column: "ttb_completely_s", gameID: gameID, db: db)
            try Self.setIf(patch.ttbSource, column: "ttb_source", gameID: gameID, db: db)
            try Self.setIf(patch.igdbRating, column: "igdb_rating", gameID: gameID, db: db)
            try Self.setIf(patch.igdbRatingCount, column: "igdb_rating_count", gameID: gameID, db: db)

            if let traits = patch.traits {
                try Self.setTraits(traits, gameID: gameID, db: db)
            }
            if let altTitles = patch.altTitles {
                // Rewrites alt_titles → triggers keep games_fts in sync.
                try db.execute(sql: "UPDATE games SET alt_titles = ? WHERE id = ?",
                               arguments: [Self.joinAlt(altTitles), gameID])
            }
            if let genres = patch.genres {
                try Self.setGenres(genres, gameID: gameID, db: db)
            }
            try db.execute(sql: "UPDATE games SET updated_at = ? WHERE id = ?",
                           arguments: [Date(), gameID])
        }
    }

    // MARK: - Manual edits (mark user_edited so enrichment never clobbers them)

    /// Import / choose a cover by hand (PLAN §5.2 "Choose cover…" / drag-drop).
    /// Sets `cover_file` and marks the `cover` field user-edited so background
    /// enrichment never replaces it.
    func setUserCover(gameID: Int64, coverFile: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET cover_file = ?, updated_at = ? WHERE id = ?",
                           arguments: [coverFile, Date(), gameID])
            try Self.markUserEdited(.cover, gameID: gameID, db: db)
        }
    }

    /// Edit a game's title by hand — updates `title` + `sort_title` and marks the
    /// `title` field user-edited (protected from enrichment).
    func editTitle(gameID: Int64, _ title: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET title = ?, sort_title = ?, updated_at = ? WHERE id = ?",
                           arguments: [title, SortTitle.make(from: title), Date(), gameID])
            try Self.markUserEdited(.title, gameID: gameID, db: db)
        }
    }

    /// Edit a game's release year by hand — marks the `year` field user-edited.
    func editYear(gameID: Int64, _ year: Int?) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET year = ?, updated_at = ? WHERE id = ?",
                           arguments: [year, Date(), gameID])
            try Self.markUserEdited(.year, gameID: gameID, db: db)
        }
    }

    // MARK: - Deleting

    /// Hard-delete a game and any product left empty by its removal.
    func deleteGame(_ gameID: Int64) async throws {
        try await dbWriter.write { db in try Self.deleteGameRow(gameID, db) }
    }

    // MARK: - App state / ranking sessions

    /// Persist a Codable blob (e.g. the resumable placement session, PLAN §7).
    func saveAppState<T: Encodable & Sendable>(key: String, _ value: T) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await dbWriter.write { db in
            try AppStateRecord(key: key, json: json, updatedAt: Date()).save(db)
        }
    }

    /// Load a Codable blob previously saved with ``saveAppState(key:_:)``.
    func loadAppState<T: Decodable & Sendable>(key: String, as type: T.Type) async throws -> T? {
        try await dbWriter.read { db in
            guard let row = try AppStateRecord.fetchOne(db, key: key) else { return nil }
            return try JSONDecoder().decode(T.self, from: Data(row.json.utf8))
        }
    }
}

/// Errors from the write API.
enum LibraryError: Error, Sendable, Equatable {
    case notFound
}

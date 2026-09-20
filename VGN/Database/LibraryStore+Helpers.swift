import Foundation
import GRDB

/// Thrown to roll a transaction back and carry a ``WriteOutcome`` out to the
/// caller (used for the `.wouldOrphan` "ask before deleting" path).
struct RollbackWithOutcome: Error {
    let outcome: WriteOutcome
    init(_ outcome: WriteOutcome) { self.outcome = outcome }
}

extension LibraryStore {
    /// Run a write that may bail out with `.wouldOrphan`, converting the
    /// rollback back into a normal return value.
    func writeCatchingOrphan(
        _ body: @Sendable @escaping (Database) throws -> WriteOutcome
    ) async throws -> WriteOutcome {
        do {
            return try await dbWriter.write(body)
        } catch let rollback as RollbackWithOutcome {
            return rollback.outcome
        }
    }

    // MARK: - Ownership / played predicates

    static func isOwned(_ gameID: Int64, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM product_games WHERE game_id = ?)",
                          arguments: [gameID]) ?? false
    }

    static func isPlayed(_ gameID: Int64, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT played FROM games WHERE id = ?",
                          arguments: [gameID]) ?? false
    }

    /// For each id, delete the game iff it is now neither owned nor played.
    /// Returns `.wouldOrphan` (rolling back) when that would happen and the
    /// caller did not confirm.
    static func resolveOrphans(
        _ gameIDs: [Int64], confirmOrphanDelete: Bool, db: Database
    ) throws -> WriteOutcome {
        var orphans: [Int64] = []
        for id in gameIDs {
            // The game may already be gone (cascade); skip those.
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)",
                                    arguments: [id]) ?? false else { continue }
            if try !isOwned(id, db) && !isPlayed(id, db) { orphans.append(id) }
        }
        if orphans.isEmpty { return .ok }
        if !confirmOrphanDelete { throw RollbackWithOutcome(.wouldOrphan(orphans)) }
        for id in orphans { try deleteGameRow(id, db) }
        return .ok
    }

    // MARK: - Row mutations

    /// Set a game's tier and clear its fine-rank key (→ unplaced). Assumes the
    /// game is already played (caller checks / draft implies it).
    static func setTierRow(gameID: Int64, tierID: Int64, db: Database) throws {
        try db.execute(sql: """
            UPDATE games SET tier_id = ?, rank_key = NULL, updated_at = ? WHERE id = ?
            """, arguments: [tierID, Date(), gameID])
    }

    /// Insert-or-update a `game_platforms` row. `played` is OR-ed with any
    /// existing value so ownership adds never demote a played flag.
    static func ensureGamePlatform(gameID: Int64, platformID: String, played: Bool, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO game_platforms (game_id, platform_id, played)
            VALUES (?, ?, ?)
            ON CONFLICT(game_id, platform_id)
            DO UPDATE SET played = MAX(played, excluded.played)
            """, arguments: [gameID, platformID, played])
    }

    /// Create a single-game Product on `platformID` and link the game.
    @discardableResult
    static func makeSingleProduct(
        gameID: Int64, platformID: String,
        format: ProductFormat, source: ProductSource,
        edition: String? = nil, region: String? = nil, db: Database
    ) throws -> Int64 {
        var product = ProductRecord(
            platformID: platformID, kind: .single, format: format,
            edition: edition, region: region, source: source
        )
        try product.insert(db)
        let productID = product.id!
        try ProductGameRecord(productID: productID, gameID: gameID, position: 0).insert(db)
        return productID
    }

    /// Reuse-or-create a compilation member game and link it to the product.
    /// `source` is the compilation product's source, recorded as the new member
    /// game's ``GameOrigin`` (set once, at creation).
    static func upsertCompilationMember(
        _ member: CompilationMemberDraft, productID: Int64, platformID: String,
        source: ProductSource = .manual, db: Database
    ) throws -> AddOutcome {
        let year = member.year ?? member.releaseDate.map(year(of:))
        var existing: GameRecord?
        if let igdbID = member.igdbID {
            existing = try GameRecord.filter(GameRecord.Columns.igdbID == igdbID).fetchOne(db)
        }

        let gameID: Int64
        let isNew: Bool
        if let found = existing, let id = found.id {
            gameID = id
            isNew = false
            if member.played && !found.played {
                try db.execute(sql: "UPDATE games SET played = 1, updated_at = ? WHERE id = ?",
                               arguments: [Date(), id])
            }
            if let status = member.status {
                try db.execute(sql: "UPDATE games SET status = ?, revisit = ?, updated_at = ? WHERE id = ?",
                               arguments: [status.dbStatus, status.dbRevisit, Date(), id])
            }
        } else {
            var record = GameRecord(
                igdbID: member.igdbID,
                title: member.title,
                sortTitle: SortTitle.make(from: member.title),
                altTitles: joinAlt(member.altTitles),
                releaseDate: member.releaseDate,
                year: year,
                played: member.played,
                status: member.status?.dbStatus,
                revisit: member.status == .toRevisit,
                origin: source.rawValue
            )
            try record.insert(db)
            gameID = record.id!
            isNew = true
        }

        try ensureGamePlatform(gameID: gameID, platformID: platformID, played: member.played, db: db)
        // Link to the compilation product (idempotent on the composite PK).
        try db.execute(sql: """
            INSERT INTO product_games (product_id, game_id, position)
            VALUES (?, ?, ?)
            ON CONFLICT(product_id, game_id) DO UPDATE SET position = excluded.position
            """, arguments: [productID, gameID, member.position])
        try promoteProductKindIfCompilation(productID, db)

        if isNew { return .created(gameID: gameID) }
        return .addedCopy(gameID: gameID)
    }

    /// Replace a game's genre set: upsert the genre names and rewrite the join.
    static func setGenres(_ names: [String], gameID: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM game_genres WHERE game_id = ?", arguments: [gameID])
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO genres (name) VALUES (?)", arguments: [trimmed])
            let genreID = try Int64.fetchOne(db, sql: "SELECT id FROM genres WHERE name = ?",
                                             arguments: [trimmed])!
            try db.execute(sql: """
                INSERT OR IGNORE INTO game_genres (game_id, genre_id) VALUES (?, ?)
                """, arguments: [gameID, genreID])
        }
    }

    /// Replace a game's IGDB-derived trait set (PLAN §7b). Traits come from a
    /// single IGDB response, so this is a clean replace-all: every existing row is
    /// dropped and the new set inserted (deduped by the composite PK). `similar`
    /// values are IGDB game ids as strings.
    static func setTraits(_ traits: [GameTrait], gameID: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM game_traits WHERE game_id = ?", arguments: [gameID])
        for trait in traits {
            // genre / platform / decade are engine-only features, never persisted.
            guard trait.kind.isPersisted else { continue }
            let value = trait.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            try db.execute(sql: """
                INSERT OR IGNORE INTO game_traits (game_id, kind, value) VALUES (?, ?, ?)
                """, arguments: [gameID, trait.kind.rawValue, value])
        }
    }

    // MARK: - User-edited marker (PLAN §7b)

    /// Read the `games.user_edited` marker set for a game.
    static func userEditedFields(_ gameID: Int64, _ db: Database) throws -> UserEditedFields {
        let raw = try String.fetchOne(db, sql: "SELECT user_edited FROM games WHERE id = ?",
                                      arguments: [gameID]) ?? ""
        return UserEditedFields(raw: raw)
    }

    /// Mark `field` as user-edited on a game (idempotent), so background enrichment
    /// never overwrites it again — not even on an explicit refresh.
    static func markUserEdited(_ field: UserEditedFields.Field, gameID: Int64, db: Database) throws {
        let current = try userEditedFields(gameID, db)
        let updated = current.inserting(field)
        guard updated != current else { return }
        try db.execute(sql: "UPDATE games SET user_edited = ?, updated_at = ? WHERE id = ?",
                       arguments: [updated.raw, Date(), gameID])
    }

    /// Delete a game and any product left with no members afterwards.
    static func deleteGameRow(_ gameID: Int64, _ db: Database) throws {
        // Product ids this game belongs to, so we can garbage-collect empties.
        let productIDs = try Int64.fetchAll(
            db, sql: "SELECT product_id FROM product_games WHERE game_id = ?", arguments: [gameID])
        try db.execute(sql: "DELETE FROM games WHERE id = ?", arguments: [gameID])
        for productID in productIDs { try purgeEmptyProduct(productID, db) }
    }

    /// Demote-or-promote `products.kind` to match the member count (PLAN §5.1 —
    /// converting single ↔ compilation as members go from 1 to n). Used on the
    /// *remove* path, where dropping to a single member should become a `single`.
    static func normalizeProductKind(_ productID: Int64, _ db: Database) throws {
        guard let count = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = ?", arguments: [productID]),
              count > 0 else { return }
        let kind: ProductKind = count > 1 ? .compilation : .single
        try db.execute(sql: "UPDATE products SET kind = ?, updated_at = ? WHERE id = ?",
                       arguments: [kind.rawValue, Date(), productID])
    }

    /// Promote-only: mark a product a `compilation` once it has more than one
    /// member. Never demotes — used on the *add* path so a product explicitly
    /// created as a compilation (even with a single member) keeps its kind, while a
    /// `single` that gains a second member becomes a compilation (PLAN §5.1).
    static func promoteProductKindIfCompilation(_ productID: Int64, _ db: Database) throws {
        guard let count = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = ?", arguments: [productID]),
              count > 1 else { return }
        try db.execute(sql: "UPDATE products SET kind = 'compilation', updated_at = ? WHERE id = ?",
                       arguments: [Date(), productID])
    }

    /// Delete a product if it now has zero member games.
    static func purgeEmptyProduct(_ productID: Int64, _ db: Database) throws {
        let remaining = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = ?",
            arguments: [productID]) ?? 0
        if remaining == 0 {
            try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [productID])
        }
    }

    /// Update `column = value` for a game only when `value` is non-nil.
    static func setIf<V: DatabaseValueConvertible>(
        _ value: V?, column: String, gameID: Int64, db: Database
    ) throws {
        guard let value else { return }
        try db.execute(sql: "UPDATE games SET \(column) = ? WHERE id = ?", arguments: [value, gameID])
    }

    // MARK: - Small utilities

    static func joinAlt(_ alts: [String]) -> String {
        alts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func year(of date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: date)
    }
}

import Foundation
import GRDB

/// Compilation reads + the extra writes the compilation editor and the
/// "Group as compilation" flow need (PLAN §5.1/§8). Adds only — the core
/// compilation writes (`addCompilation`, `addCompilationMember`,
/// `removeCompilationMember`, `reorderCompilationMembers`, `renameProduct`,
/// `removeProduct`) live in `LibraryStore.swift`.
extension LibraryStore {

    // MARK: - Reads

    /// The ordered member games of a product (compilation editor + inspector list).
    /// Empty when the product does not exist. Members keep their own played flag
    /// and tier, which are read here for the inline list (PLAN §8).
    func compilationMembers(productID: Int64) async throws -> [CompilationMemberInfo] {
        try await dbReader.read { db in try Self.fetchCompilationMembers(productID, db) }
    }

    /// Live member list — the editor re-renders itself after each write.
    func compilationMembersObservation(productID: Int64) -> AsyncValueObservation<[CompilationMemberInfo]> {
        ValueObservation.tracking { db in try Self.fetchCompilationMembers(productID, db) }
            .values(in: dbReader)
    }

    static func fetchCompilationMembers(_ productID: Int64, _ db: Database) throws -> [CompilationMemberInfo] {
        try Row.fetchAll(db, sql: """
            SELECT g.id AS id, g.title AS title, pg.position AS position, g.year AS year,
                   g.played AS played, g.cover_file AS cover_file, t.letter AS tier_letter
            FROM product_games pg
            JOIN games g ON g.id = pg.game_id
            LEFT JOIN tiers t ON t.id = g.tier_id
            WHERE pg.product_id = ?
            ORDER BY pg.position, g.sort_title, g.id
            """, arguments: [productID]).map { r in
            CompilationMemberInfo(
                gameID: r["id"], title: r["title"], position: r["position"],
                year: r["year"], played: r["played"],
                tierLetter: r["tier_letter"], coverFile: r["cover_file"])
        }
    }

    /// The full compilation product + members for the editor. `nil` if not found.
    func compilationProduct(id productID: Int64) async throws -> CompilationProductInfo? {
        try await dbReader.read { db in try Self.fetchCompilationProduct(productID, db) }
    }

    func compilationProductObservation(id productID: Int64) -> AsyncValueObservation<CompilationProductInfo?> {
        ValueObservation.tracking { db in try Self.fetchCompilationProduct(productID, db) }
            .values(in: dbReader)
    }

    static func fetchCompilationProduct(_ productID: Int64, _ db: Database) throws -> CompilationProductInfo? {
        guard let p = try ProductRecord.fetchOne(db, key: productID) else { return nil }
        let members = try fetchCompilationMembers(productID, db)
        // The whole-collection play time (PLAN §13.3 / §7b) — the same rule the inspector's
        // compilation copy row uses, keyed by the product's importer `(source, external_id)`.
        var collectionPlaytimeS: Int?
        if let externalID = try String.fetchOne(
            db, sql: "SELECT external_id FROM products WHERE id = ?", arguments: [productID]) {
            collectionPlaytimeS = try collectionPlaytimeSeconds(
                source: p.source, externalID: externalID, db: db)
        }
        return CompilationProductInfo(
            id: productID,
            title: p.title,
            platformID: p.platformID,
            format: ProductFormat(rawValue: p.format) ?? .physical,
            kind: ProductKind(rawValue: p.kind) ?? .compilation,
            edition: p.edition,
            region: p.region,
            igdbID: p.igdbID,
            members: members,
            collectionPlaytimeS: collectionPlaytimeS)
    }

    // MARK: - Writes

    /// Edit a compilation product's descriptive fields (platform, format, edition,
    /// region). Only non-nil arguments are applied. Changing the platform also
    /// updates every member's `game_platforms` row so the games still count for the
    /// product's platform.
    func updateProductDetails(
        productID: Int64,
        platformID: String? = nil,
        format: ProductFormat? = nil,
        edition: String?? = nil,
        region: String?? = nil
    ) async throws {
        try await dbWriter.write { db in
            if let platformID {
                try db.execute(sql: "UPDATE products SET platform_id = ?, updated_at = ? WHERE id = ?",
                               arguments: [platformID, Date(), productID])
                let memberIDs = try Int64.fetchAll(
                    db, sql: "SELECT game_id FROM product_games WHERE product_id = ?", arguments: [productID])
                for gameID in memberIDs {
                    try Self.ensureGamePlatform(gameID: gameID, platformID: platformID, played: false, db: db)
                }
                // No pruning: the OLD platform simply stops showing because the read rule
                // (PLAN §4) sources an owned game's platforms from its copies (∪ played-on rows),
                // and the copy has moved. The stale `game_platforms` row stays, untouched.
            }
            if let format {
                try db.execute(sql: "UPDATE products SET format = ?, updated_at = ? WHERE id = ?",
                               arguments: [format.rawValue, Date(), productID])
            }
            if case let .some(value) = edition {
                try db.execute(sql: "UPDATE products SET edition = ?, updated_at = ? WHERE id = ?",
                               arguments: [value, Date(), productID])
            }
            if case let .some(value) = region {
                try db.execute(sql: "UPDATE products SET region = ?, updated_at = ? WHERE id = ?",
                               arguments: [value, Date(), productID])
            }
        }
    }

    /// Link an **existing** library game (by id) into a compilation product,
    /// reusing it rather than creating a new game — the editor's "add a game
    /// already in my library" path, including manual games that carry no IGDB id
    /// (PLAN §5.1). Idempotent on the composite key; ensures the game counts for
    /// the product's platform.
    func addExistingGameToCompilation(productID: Int64, gameID: Int64, position: Int) async throws {
        try await dbWriter.write { db in
            guard let platformID = try String.fetchOne(
                db, sql: "SELECT platform_id FROM products WHERE id = ?", arguments: [productID])
            else { throw LibraryError.notFound }
            try Self.ensureGamePlatform(gameID: gameID, platformID: platformID, played: false, db: db)
            try db.execute(sql: """
                INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, ?)
                ON CONFLICT(product_id, game_id) DO UPDATE SET position = excluded.position
                """, arguments: [productID, gameID, position])
            try Self.promoteProductKindIfCompilation(productID, db)
        }
    }

    /// Group several existing games into one new compilation product (PLAN §8 —
    /// "Group as compilation…"). Each game is linked in the given order and becomes
    /// owned via the new product. When `mergeExistingSingles` is set, each game's
    /// existing **single** copy on the same platform is removed and folded into the
    /// compilation (its ownership now comes from the compilation). Returns the new
    /// product id and the affected games' ids in order.
    @discardableResult
    func groupAsCompilation(
        gameIDs: [Int64],
        title: String?,
        platformID: String,
        format: ProductFormat = .physical,
        source: ProductSource = .manual,
        mergeExistingSingles: Bool = true
    ) async throws -> Int64 {
        try await dbWriter.write { db in
            var record = ProductRecord(
                title: title, platformID: platformID, kind: .compilation, format: format, source: source)
            try record.insert(db)
            let productID = record.id!

            for (index, gameID) in gameIDs.enumerated() {
                try Self.ensureGamePlatform(gameID: gameID, platformID: platformID, played: false, db: db)
                try db.execute(sql: """
                    INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, ?)
                    ON CONFLICT(product_id, game_id) DO UPDATE SET position = excluded.position
                    """, arguments: [productID, gameID, index])

                if mergeExistingSingles {
                    // Remove any single-game product on the same platform (merge it in).
                    let singles = try Int64.fetchAll(db, sql: """
                        SELECT p.id FROM products p
                        JOIN product_games pg ON pg.product_id = p.id
                        WHERE pg.game_id = ? AND p.platform_id = ? AND p.kind = 'single' AND p.id != ?
                        """, arguments: [gameID, platformID, productID])
                    for single in singles {
                        try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [single])
                    }
                }
            }
            return productID
        }
    }
}

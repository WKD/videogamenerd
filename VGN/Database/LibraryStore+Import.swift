import Foundation
import GRDB

/// Product-side helpers for importer commits (PLAN §14.3). A GOG/PSN Product carries
/// `source` values (`'gog'`) that the `ProductSource` enum does not model yet and an
/// `external_id` the `ProductRecord` does not carry, so these write `products` with raw
/// SQL — keeping the commit idempotent on `(source, external_id)` (the v5 partial unique
/// index) without depending on the enum. Everything else (games, game_platforms,
/// compilation membership) still goes through the existing ``LibraryStore`` helpers, so
/// the §4 invariants hold.
extension LibraryStore {

    /// The product id of an already-committed import Product for `(sourceRaw, externalID)`,
    /// or nil — the idempotency guard: if this exists, the external title was committed
    /// before and nothing new is created (PLAN §14.3).
    static func existingImportProductID(sourceRaw: String, externalID: String, db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM products WHERE source = ? AND external_id = ?",
                           arguments: [sourceRaw, externalID])
    }

    /// Insert one import `products` row (no membership) and return its id. Digital by
    /// default; `kindRaw` is `'single'` or `'compilation'`. `edition` / `acquiredAt` land
    /// on the copy when a file importer supplies them (Delicious, PLAN §5.5).
    @discardableResult
    static func insertImportProductRow(
        platformID: String, format: ProductFormat, sourceRaw: String, externalID: String,
        kindRaw: String = "single", title: String? = nil,
        edition: String? = nil, acquiredAt: Date? = nil, db: Database
    ) throws -> Int64 {
        let now = Date()
        try db.execute(sql: """
            INSERT INTO products
                (title, platform_id, kind, format, edition, source, external_id, acquired_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [title, platformID, kindRaw, format.rawValue, edition,
                             sourceRaw, externalID, acquiredAt, now, now])
        return db.lastInsertedRowID
    }

    /// Idempotently attach a **single-game** import Product for `gameID` (PLAN §14.3).
    /// If a Product for `(sourceRaw, externalID)` already exists, nothing is created and
    /// `created` is false. Ensures the `game_platforms` row too. Games are added *owned,
    /// not played* — this only establishes ownership, never a played flag or tier.
    /// `edition` / `acquiredAt` are recorded on a newly-created copy (Delicious).
    @discardableResult
    static func attachSingleImportProduct(
        gameID: Int64, platformID: String, format: ProductFormat,
        sourceRaw: String, externalID: String,
        edition: String? = nil, acquiredAt: Date? = nil, db: Database
    ) throws -> (productID: Int64, created: Bool) {
        if let existing = try existingImportProductID(sourceRaw: sourceRaw, externalID: externalID, db: db) {
            // Keep the membership consistent (idempotent link) but create nothing new.
            try db.execute(sql: """
                INSERT OR IGNORE INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)
                """, arguments: [existing, gameID])
            return (existing, false)
        }
        try ensureGamePlatform(gameID: gameID, platformID: platformID, played: false, db: db)
        let productID = try insertImportProductRow(
            platformID: platformID, format: format, sourceRaw: sourceRaw, externalID: externalID,
            edition: edition, acquiredAt: acquiredAt, db: db)
        try ProductGameRecord(productID: productID, gameID: gameID, position: 0).insert(db)
        return (productID, true)
    }
}

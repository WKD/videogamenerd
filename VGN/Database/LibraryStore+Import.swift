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
    /// on the copy when a file importer supplies them (Delicious, PLAN §5.5). `subscription`
    /// records a PS Plus / raw membership claim on the copy (PSN, v8/§13.3).
    @discardableResult
    static func insertImportProductRow(
        platformID: String, format: ProductFormat, sourceRaw: String, externalID: String,
        kindRaw: String = "single", title: String? = nil,
        edition: String? = nil, acquiredAt: Date? = nil, subscription: String? = nil, db: Database
    ) throws -> Int64 {
        let now = Date()
        try db.execute(sql: """
            INSERT INTO products
                (title, platform_id, kind, format, edition, source, external_id, subscription,
                 acquired_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [title, platformID, kindRaw, format.rawValue, edition,
                             sourceRaw, externalID, subscription, acquiredAt, now, now])
        return db.lastInsertedRowID
    }

    /// Mark a game **played without creating any copy** (PLAN §13.3 — a trophy title that
    /// is "played, not owned"). Sets `games.played = 1` and the per-platform played flag,
    /// never touching ownership, tier or rank. Idempotent.
    static func markPlayedWithoutCopy(gameID: Int64, platformID: String?, db: Database) throws {
        try db.execute(sql: "UPDATE games SET played = 1, updated_at = ? WHERE id = ?",
                       arguments: [Date(), gameID])
        if let platformID {
            try ensureGamePlatform(gameID: gameID, platformID: platformID, played: true, db: db)
        }
    }

    /// Set the **PSN-sourced** play time (PLAN §6.4). Only ever writes `psn_playtime_s`, so
    /// a manual `my_playtime_s` is never overwritten (the manual value wins at read time).
    /// A nil value is ignored. Idempotent; a changed value updates.
    static func setPSNPlaytime(gameID: Int64, seconds: Int?, db: Database) throws {
        guard let seconds else { return }
        try db.execute(sql: "UPDATE games SET psn_playtime_s = ?, updated_at = ? WHERE id = ?",
                       arguments: [seconds, Date(), gameID])
    }

    /// Store an **imported** play time (Batocera `gametime`, PLAN §15) **without ever
    /// clobbering a real value**: it writes `psn_playtime_s` only when BOTH `my_playtime_s`
    /// (manual) and `psn_playtime_s` are NULL. VGN has no neutral `imported_playtime_s`
    /// column today (the Batocera lane proposes one — see the hand-off); until then this is
    /// the safe interim home. A nil `seconds` is a no-op. Idempotent (re-running with the
    /// same value changes nothing; a later PSN sync still wins because it writes
    /// unconditionally through ``setPSNPlaytime(gameID:seconds:db:)``).
    static func setImportedPlaytimeIfEmpty(gameID: Int64, seconds: Int?, db: Database) throws {
        guard let seconds else { return }
        try db.execute(sql: """
            UPDATE games SET psn_playtime_s = ?, updated_at = ?
            WHERE id = ? AND my_playtime_s IS NULL AND psn_playtime_s IS NULL
            """, arguments: [seconds, Date(), gameID])
    }

    /// Record the earliest / latest known play date on a game (v9, PLAN §13.3). Filled
    /// only by importers (PSN), never typed. Monotonic and NULL-safe:
    ///  - `first_played_at` only ever moves **earlier** (the earliest known date wins);
    ///  - `last_played_at` only ever moves **later** (a re-sync never moves it backwards);
    ///  - a nil `first` / `last` never overwrites a stored value.
    ///
    /// Dates are compared as their GRDB text form (`YYYY-MM-DD HH:MM:SS.SSS`), which sorts
    /// lexically the same as chronologically. A call with both nil is a no-op.
    static func setPSNPlayedDates(gameID: Int64, first: Date?, last: Date?, db: Database) throws {
        guard first != nil || last != nil else { return }
        try db.execute(sql: """
            UPDATE games SET
                first_played_at = CASE
                    WHEN :f IS NULL THEN first_played_at
                    WHEN first_played_at IS NULL OR :f < first_played_at THEN :f
                    ELSE first_played_at END,
                last_played_at = CASE
                    WHEN :l IS NULL THEN last_played_at
                    WHEN last_played_at IS NULL OR :l > last_played_at THEN :l
                    ELSE last_played_at END,
                updated_at = :now
            WHERE id = :id
            """, arguments: ["f": first, "l": last, "now": Date(), "id": gameID])
    }

    /// Pre-fill a completion status **only when the game has none** (PLAN §13.3 — a 100 %
    /// trophy title). Never overwrites an existing status.
    static func prefillStatusIfNone(gameID: Int64, status: PlayStatus, db: Database) throws {
        try db.execute(sql: """
            UPDATE games SET status = ?, updated_at = ? WHERE id = ? AND status IS NULL
            """, arguments: [status.rawValue, Date(), gameID])
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
        edition: String? = nil, acquiredAt: Date? = nil, subscription: String? = nil, db: Database
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
            edition: edition, acquiredAt: acquiredAt, subscription: subscription, db: db)
        try ProductGameRecord(productID: productID, gameID: gameID, position: 0).insert(db)
        return (productID, true)
    }

    /// The play time PSN recorded for a **whole collection** that was NOT routed to a single
    /// member (PLAN §13.3 / D2 — "75 h on the whole collection (PSN)"). Returns the seconds when
    /// an `import_titles` record for `(source, externalID)` carries `play_duration_s` **and** the
    /// play data stayed on the collection — i.e. it was not the exactly-one-member case (which puts
    /// the time on that member). Returns nil when there is no record, no play time, or the time was
    /// routed to a single member (exactly one member is marked played in the persisted `match_json`).
    /// The compilation detail view reads it by the compilation Product's `(source, external_id)`.
    func collectionPlaytimeSeconds(source: String, externalID: String) async throws -> Int? {
        try await dbReader.read { db in try Self.collectionPlaytimeSeconds(source: source, externalID: externalID, db: db) }
    }

    /// The `db`-based core (also called inside the game-detail read so the inspector's compilation
    /// copy row gets the value through the existing detail-loading path — never a read from a `body`).
    static func collectionPlaytimeSeconds(source: String, externalID: String, db: Database) throws -> Int? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT play_duration_s, match_json FROM import_titles
            WHERE source = ? AND external_id = ?
            """, arguments: [source, externalID]) else { return nil }
        guard let seconds: Int = row["play_duration_s"], seconds > 0 else { return nil }
        if let json: String = row["match_json"],
           let match = ImportStagingStore.decodeMatch(json),
           match.bundle?.members.filter(\.played).count == 1 {
            return nil   // routed to the single played member — the member carries it, not the collection
        }
        return seconds
    }

    /// The `(externalID, productID)` of every currently-committed **subscription** copy for
    /// a source (PSN, PLAN §13.3) — the baseline for detecting a Plus claim that has
    /// disappeared on re-sync (proposed for removal, never applied silently).
    static func committedSubscriptionCopies(sourceRaw: String, db: Database) throws -> [(externalID: String, productID: Int64)] {
        try Row.fetchAll(db, sql: """
            SELECT external_id AS eid, id AS pid FROM products
            WHERE source = ? AND subscription IS NOT NULL AND external_id IS NOT NULL
            """, arguments: [sourceRaw]).map { (externalID: $0["eid"], productID: $0["pid"]) }
    }
}

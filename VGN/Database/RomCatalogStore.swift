import Foundation
import GRDB

/// The data side of the Batocera ROM catalogue (PLAN §15). Owns every read and write of
/// `rom_catalog` / `rom_catalog_sync`. The catalogue is a completely separate shelf: this
/// store never touches `games`, and no library query ever reads `rom_catalog` — the only
/// bridge is `promoted_game_id`, set once a ROM is promoted through the importer path.
///
/// Mirrors ``ImportStagingStore``'s shape: a `Sendable` struct over an ``AppDatabase``, all
/// I/O through GRDB's writer, every write one transaction.
struct RomCatalogStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    static let source = "batocera"

    /// The full column list a read selects, in the order ``entry(from:)`` decodes.
    private static let columns = """
        id, source, system, platform_id, relative_path, name, sort_title, normalised_title,
        libretro_key, screenscraper_id, md5, region, lang, genre, family, developer, publisher,
        release_year, rating, players, play_count, game_time_s, last_played_at, favorite,
        image_path, thumbnail_path, first_seen_at, last_seen_at, removed_at, promoted_game_id,
        dismissed_at, not_interested, external_id, cover_url, membership, cross_gen_note,
        igdb_id, length_main_s, length_complete_s, traits_json, igdb_rating, match_state, matched_at,
        owned
        """

    // MARK: - Sync (upsert + removal, one transaction per system)

    /// Reconcile one system's catalogue against a freshly-read, already-folded set of entries
    /// (PLAN §15): new paths are inserted (`first_seen_at`), present paths refresh their
    /// metadata / play data and `last_seen_at` (clearing any `removed_at`), and paths that
    /// vanished from the share get `removed_at` — **never deleted**, even when promoted. The
    /// persisted decisions (`promoted_game_id`, `dismissed_at`, `not_interested`) are kept.
    @discardableResult
    func syncSystem(system: String, entries: [RomCatalogEntry]) async throws -> RomCatalogSyncCounts {
        let src = Self.source
        return try await dbWriter.write { db in
            var counts = RomCatalogSyncCounts()
            let now = Date()

            // Existing rows for this system: relative_path → id.
            var existing: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, relative_path FROM rom_catalog WHERE source = ? AND system = ?
                """, arguments: [src, system]) {
                existing[row["relative_path"]] = row["id"]
            }

            var currentPaths = Set<String>()
            for entry in entries {
                currentPaths.insert(entry.relativePath)
                if let id = existing[entry.relativePath] {
                    try Self.update(entry, id: id, now: now, db: db)
                    counts.updated += 1
                } else {
                    try Self.insert(entry, now: now, db: db)
                    counts.added += 1
                }
            }

            // Vanished rows → removed_at (only those not already removed).
            for (path, id) in existing where !currentPaths.contains(path) {
                try db.execute(sql: """
                    UPDATE rom_catalog SET removed_at = ? WHERE id = ? AND removed_at IS NULL
                    """, arguments: [now, id])
                if db.changesCount > 0 { counts.removed += 1 }
            }
            return counts
        }
    }

    private static func insert(_ e: RomCatalogEntry, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO rom_catalog
                (source, system, platform_id, relative_path, name, sort_title, normalised_title,
                 libretro_key, screenscraper_id, md5, region, lang, genre, family, developer,
                 publisher, release_year, rating, players, play_count, game_time_s, last_played_at,
                 favorite, image_path, thumbnail_path, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                e.source, e.system, e.platformID, e.relativePath, e.name, e.sortTitle,
                e.normalisedTitle, e.libretroKey, e.screenScraperID, e.md5, e.region, e.lang,
                e.genre, e.family, e.developer, e.publisher, e.releaseYear, e.rating, e.players,
                e.playCount, e.gameTimeSeconds, e.lastPlayedAt, e.isFavorite, e.imagePath,
                e.thumbnailPath, now, now,
            ])
    }

    /// Update refreshes metadata + play data + `last_seen_at`, clears `removed_at`, and keeps
    /// `first_seen_at` and the persisted decisions untouched.
    private static func update(_ e: RomCatalogEntry, id: Int64, now: Date, db: Database) throws {
        try db.execute(sql: """
            UPDATE rom_catalog SET
                platform_id = ?, name = ?, sort_title = ?, normalised_title = ?, libretro_key = ?,
                screenscraper_id = ?, md5 = ?, region = ?, lang = ?, genre = ?, family = ?,
                developer = ?, publisher = ?, release_year = ?, rating = ?, players = ?,
                play_count = ?, game_time_s = ?, last_played_at = ?, favorite = ?,
                image_path = ?, thumbnail_path = ?, last_seen_at = ?, removed_at = NULL
            WHERE id = ?
            """, arguments: [
                e.platformID, e.name, e.sortTitle, e.normalisedTitle, e.libretroKey,
                e.screenScraperID, e.md5, e.region, e.lang, e.genre, e.family, e.developer,
                e.publisher, e.releaseYear, e.rating, e.players, e.playCount, e.gameTimeSeconds,
                e.lastPlayedAt, e.isFavorite, e.imagePath, e.thumbnailPath, now, id,
            ])
    }

    // MARK: - Change-detection state

    func syncState(system: String) async throws -> RomCatalogSyncState? {
        try await dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT system, gamelist_mtime, gamelist_size, last_read_at, entry_count
                FROM rom_catalog_sync WHERE source = ? AND system = ?
                """, arguments: [Self.source, system]) else { return nil }
            return RomCatalogSyncState(
                system: row["system"], gamelistMtime: row["gamelist_mtime"],
                gamelistSize: row["gamelist_size"], lastReadAt: row["last_read_at"],
                entryCount: row["entry_count"])
        }
    }

    func setSyncState(system: String, mtime: Date?, size: Int64, entryCount: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog_sync (source, system, gamelist_mtime, gamelist_size,
                                              last_read_at, entry_count)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, system) DO UPDATE SET
                    gamelist_mtime = excluded.gamelist_mtime,
                    gamelist_size  = excluded.gamelist_size,
                    last_read_at   = excluded.last_read_at,
                    entry_count    = excluded.entry_count
                """, arguments: [Self.source, system, mtime, size, Date(), entryCount])
        }
    }

    // MARK: - Promotion

    /// Promotion candidates not yet promoted, still present, not dismissed (PLAN §15 —
    /// `game_time_s > 300` OR favourite). Ordered by most play time then name.
    func promotionCandidates(limit: Int = 5000) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog
                WHERE removed_at IS NULL AND promoted_game_id IS NULL AND not_interested = 0
                  AND (game_time_s > ? OR favorite = 1)
                ORDER BY game_time_s DESC, sort_title ASC
                LIMIT ?
                """, arguments: [BatoceraPromotion.playedThresholdSeconds, limit])
                .map(Self.entry(from:))
        }
    }

    /// The favourites eligible for **automatic** IGDB matching (PLAN §15): present, not
    /// promoted, not dismissed, and **not already staged** for this source — a favourite that
    /// has been through matching once (confident or not) has an `import_titles` row, so it is
    /// never queried again. Ordered by most play time then name (a played favourite first).
    func favouritesNeedingMatch(limit: Int) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog c
                WHERE c.removed_at IS NULL AND c.promoted_game_id IS NULL AND c.not_interested = 0
                  AND c.favorite = 1
                  AND NOT EXISTS (
                      SELECT 1 FROM import_titles it
                      WHERE it.source = ? AND it.external_id = c.system || '/' || c.relative_path
                  )
                ORDER BY c.game_time_s DESC, c.sort_title ASC
                LIMIT ?
                """, arguments: [Self.source, limit]).map(Self.entry(from:))
        }
    }

    /// How many favourites still need automatic matching (the "still to match" figure for the
    /// first-run banner, PLAN §15).
    func favouritesNeedingMatchCount() async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog c
                WHERE c.removed_at IS NULL AND c.promoted_game_id IS NULL AND c.not_interested = 0
                  AND c.favorite = 1
                  AND NOT EXISTS (
                      SELECT 1 FROM import_titles it
                      WHERE it.source = ? AND it.external_id = c.system || '/' || c.relative_path
                  )
                """, arguments: [Self.source]) ?? 0
        }
    }

    /// Link a catalogue row to the library game it was promoted into (PLAN §15). Idempotent.
    func setPromoted(catalogID: Int64, gameID: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE rom_catalog SET promoted_game_id = ? WHERE id = ?",
                           arguments: [gameID, catalogID])
        }
    }

    /// Retire a title from the future Discover row for good ("Not interested", PLAN §15).
    func setNotInterested(catalogID: Int64, _ value: Bool = true) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE rom_catalog SET not_interested = ?, dismissed_at = ? WHERE id = ?
                """, arguments: [value, value ? Date() : nil, catalogID])
        }
    }

    // MARK: - Reads (browser + Discover pool, phase 2)

    func entry(id: Int64) async throws -> RomCatalogEntry? {
        try await dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM rom_catalog WHERE id = ?",
                             arguments: [id]).map(Self.entry(from:))
        }
    }

    func entries(ids: [Int64]) async throws -> [RomCatalogEntry] {
        guard !ids.isEmpty else { return [] }
        return try await dbWriter.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            return try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids)).map(Self.entry(from:))
        }
    }

    /// One system's entries (present only, sorted), paged (PLAN §15 browser).
    func entries(system: String, includeRemoved: Bool = false,
                 limit: Int = 500, offset: Int = 0) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            let removedClause = includeRemoved ? "" : "AND removed_at IS NULL"
            return try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog
                WHERE source = ? AND system = ? \(removedClause)
                ORDER BY sort_title ASC LIMIT ? OFFSET ?
                """, arguments: [Self.source, system, limit, offset]).map(Self.entry(from:))
        }
    }

    /// Present-entry counts per system (PLAN §15/§16 — the browser's per-system totals),
    /// optionally scoped to one Vault source.
    func countsPerSystem(source: String? = nil) async throws -> [String: Int] {
        let args = Self.statementArgs(source.map { [$0] } ?? [])
        let clause = source == nil ? "" : "AND source = ?"
        return try await dbWriter.read { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT system, COUNT(*) AS n FROM rom_catalog
                WHERE removed_at IS NULL \(clause) GROUP BY system
                """, arguments: args) {
                out[row["system"]] = row["n"]
            }
            return out
        }
    }

    /// FTS search over name + normalised title, diacritics-insensitive (PLAN §15). Optionally
    /// scoped to a system. Fast at ~15 000 rows via `rom_catalog_fts`.
    func search(_ query: String, system: String? = nil, limit: Int = 200) async throws -> [RomCatalogEntry] {
        let pattern = FTSPattern.prefixMatch(query)
        guard !pattern.isEmpty else { return [] }
        return try await dbWriter.read { db in
            var sql = """
                SELECT c.* FROM rom_catalog c
                JOIN rom_catalog_fts f ON f.rowid = c.id
                WHERE rom_catalog_fts MATCH ? AND c.removed_at IS NULL
                """
            var args: [DatabaseValueConvertible] = [pattern]
            if let system {
                sql += " AND c.system = ?"
                args.append(system)
            }
            sql += " ORDER BY c.sort_title ASC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.entry(from:))
        }
    }

    /// The "never played" pool for Discover (PLAN §15): present, not promoted, not dismissed,
    /// no recorded play time. Optionally scoped to a system.
    func neverPlayedPool(system: String? = nil, limit: Int = 500) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            var sql = """
                SELECT \(Self.columns) FROM rom_catalog
                WHERE removed_at IS NULL AND promoted_game_id IS NULL AND not_interested = 0
                  AND game_time_s = 0 AND play_count = 0
                """
            var args: [DatabaseValueConvertible] = []
            if let system {
                sql += " AND system = ?"
                args.append(system)
            }
            sql += " ORDER BY sort_title ASC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.entry(from:))
        }
    }

    // MARK: - Browser (paged, filtered, sorted — PLAN §15 sidebar catalogue)

    /// Sort order for the ROM Catalogue browser (PLAN §15).
    enum BrowseSort: String, CaseIterable, Sendable, Identifiable {
        case title, rating, year, recentlyAdded, mostPlayed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .rating: return "Rating"
            case .year: return "Year"
            case .recentlyAdded: return "Recently added"
            case .mostPlayed: return "Most played"
            }
        }
        /// The SQL `ORDER BY` tail (a stable `sort_title, id` tiebreak keeps paging stable).
        var orderBy: String {
            switch self {
            case .title: return "c.sort_title ASC, c.id ASC"
            case .rating: return "c.rating IS NULL, c.rating DESC, c.sort_title ASC, c.id ASC"
            case .year: return "c.release_year IS NULL, c.release_year DESC, c.sort_title ASC, c.id ASC"
            case .recentlyAdded: return "c.first_seen_at DESC, c.id DESC"
            case .mostPlayed: return "c.game_time_s DESC, c.play_count DESC, c.sort_title ASC, c.id ASC"
            }
        }
    }

    /// Filter chips for the browser (PLAN §15).
    enum BrowseFilter: String, CaseIterable, Sendable, Identifiable {
        case all, neverPlayed, played, favourites, inLibrary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .neverPlayed: return "Never played"
            case .played: return "Played"
            case .favourites: return "Favourites"
            case .inLibrary: return "In my library"
            }
        }
        /// The SQL predicate (prefixed with ` AND `), or empty for `.all`.
        var predicate: String {
            switch self {
            case .all: return ""
            case .neverPlayed: return " AND c.game_time_s = 0 AND c.play_count = 0"
            case .played: return " AND c.game_time_s > 0"
            case .favourites: return " AND c.favorite = 1"
            case .inLibrary: return " AND c.promoted_game_id IS NOT NULL"
            }
        }
    }

    /// Build the shared browse SQL (present rows, optional system + filter + FTS search),
    /// returning the SQL body (`FROM … WHERE …`) and its arguments — used by both the paged
    /// read and the count.
    private static func browseBody(source: String?, system: String?, filter: BrowseFilter, search: String)
        -> (from: String, args: [DatabaseValueConvertible]) {
        let pattern = FTSPattern.prefixMatch(search)
        var from = "FROM rom_catalog c"
        var args: [DatabaseValueConvertible] = []
        if !pattern.isEmpty {
            from += " JOIN rom_catalog_fts f ON f.rowid = c.id"
        }
        var where_ = " WHERE c.removed_at IS NULL"
        if !pattern.isEmpty { where_ += " AND rom_catalog_fts MATCH ?"; args.append(pattern) }
        if let source { where_ += " AND c.source = ?"; args.append(source) }
        if let system { where_ += " AND c.system = ?"; args.append(system) }
        where_ += filter.predicate
        return (from + where_, args)
    }

    /// One page of the browser (PLAN §15): present entries on an optional system, filtered
    /// and sorted, with an optional FTS search, never loading the whole catalogue into memory.
    func browse(source: String? = nil, system: String?, filter: BrowseFilter, sort: BrowseSort,
                search: String, limit: Int, offset: Int) async throws -> [RomCatalogEntry] {
        let body = Self.browseBody(source: source, system: system, filter: filter, search: search)
        let args = Self.statementArgs(body.args + [limit, offset])
        let sql = "SELECT c.* \(body.from) ORDER BY \(sort.orderBy) LIMIT ? OFFSET ?"
        return try await dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map(Self.entry(from:))
        }
    }

    /// The total row count for a browse filter (for the paging footer).
    func browseCount(source: String? = nil, system: String?, filter: BrowseFilter, search: String) async throws -> Int {
        let body = Self.browseBody(source: source, system: system, filter: filter, search: search)
        let sql = "SELECT COUNT(*) \(body.from)"
        let args = Self.statementArgs(body.args)
        return try await dbWriter.read { db in
            try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
        }
    }

    /// Build a `StatementArguments` (a `Sendable` value) from a positional-arg array. The
    /// return-type context picks the non-failable initialiser, so the result can be captured
    /// into a GRDB read closure without a non-`Sendable` capture.
    private static func statementArgs(_ values: [DatabaseValueConvertible]) -> StatementArguments {
        StatementArguments(values)
    }

    /// Systems the owner has **real play time** on (any present entry played > 5 min), for
    /// the Discover row's small "systems I actually play" affinity nudge (PLAN §15).
    func playedSystems() async throws -> Set<String> {
        try await dbWriter.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT system FROM rom_catalog
                WHERE removed_at IS NULL AND game_time_s > ?
                """, arguments: [BatoceraPromotion.playedThresholdSeconds])
            return Set(rows)
        }
    }

    /// Total present-entry count (diagnostics / tests).
    func totalCount(includeRemoved: Bool = false) async throws -> Int {
        try await dbWriter.read { db in
            let clause = includeRemoved ? "" : "WHERE removed_at IS NULL"
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog \(clause)") ?? 0
        }
    }

    /// Count of pending promotion candidates (played > 5 min or favourite, present, not
    /// promoted, not dismissed) — the "candidates waiting" figure for Settings + the banner.
    func promotionCandidateCount() async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog
                WHERE removed_at IS NULL AND promoted_game_id IS NULL AND not_interested = 0
                  AND (game_time_s > ? OR favorite = 1)
                """, arguments: [BatoceraPromotion.playedThresholdSeconds]) ?? 0
        }
    }

    /// A status snapshot for Settings ▸ Batocera (total present entries, distinct systems,
    /// candidates waiting). One read, never touches the share.
    func statusSnapshot() async throws -> BatoceraCatalogStatus {
        try await dbWriter.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog WHERE removed_at IS NULL") ?? 0
            let systems = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT system) FROM rom_catalog WHERE removed_at IS NULL
                """) ?? 0
            let candidates = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog
                WHERE removed_at IS NULL AND promoted_game_id IS NULL AND not_interested = 0
                  AND (game_time_s > ? OR favorite = 1)
                """, arguments: [BatoceraPromotion.playedThresholdSeconds]) ?? 0
            return BatoceraCatalogStatus(totalEntries: total, systemsCount: systems,
                                         candidatesWaiting: candidates)
        }
    }

    /// A GRDB observation of the present-entry count (the sidebar "ROM Catalogue" badge +
    /// section visibility). A *separate* observation from the library counts, so a catalogue
    /// write never disturbs the library's sidebar-counts stream (PLAN §15 — the catalogue is
    /// invisible to the library).
    func countObservation() -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog WHERE removed_at IS NULL") ?? 0
            }
            .values(in: dbWriter)
    }

    // MARK: - The Vault: per-source counts (PLAN §16)

    /// Present-entry counts for both Vault sources in **one** read (PLAN §16 deliverable 7 —
    /// the sidebar shows a per-source count and hides a row at 0). A source with no rows is 0.
    func sourceCounts() async throws -> VaultSourceCounts {
        try await dbWriter.read(Self.readSourceCounts)
    }

    /// A single GRDB observation of both sources' present-entry counts (PLAN §16) — the sidebar
    /// section's two rows and their visibility come from one stream, never disturbing the
    /// library's separate sidebar-counts observation.
    func sourceCountsObservation() -> AsyncValueObservation<VaultSourceCounts> {
        ValueObservation.tracking(Self.readSourceCounts).values(in: dbWriter)
    }

    private static func readSourceCounts(_ db: Database) throws -> VaultSourceCounts {
        var out = VaultSourceCounts()
        for row in try Row.fetchAll(db, sql: """
            SELECT source, COUNT(*) AS n FROM rom_catalog WHERE removed_at IS NULL GROUP BY source
            """) {
            let n: Int = row["n"]
            switch VaultSource(storage: row["source"]) {
            case .batocera: out.batocera = n
            case .psn: out.psn = n
            case nil: break
            }
        }
        return out
    }

    // MARK: - The Vault: PS Plus ingestion (PLAN §16)

    /// Reconcile the PS Plus (`source = psn`) slice of the Vault against a freshly-built set of
    /// entries (PLAN §16): new claims are inserted, present ones refresh their name / cover /
    /// membership / note **without disturbing** any IGDB match already made, and a claim that
    /// vanished from the current set gets `removed_at` (it "leaves the Vault silently").
    ///
    /// `presentExternalIDs` is every external id the latest sync still lists as a vaultable PS
    /// Plus claim; an existing row whose external id is absent is removed. An entry that later
    /// crossed the 10-minute gate is simply not in the set (it went to the review sheet as an
    /// owned-via-subscription copy), so it, too, leaves the Vault here (PLAN §16).
    @discardableResult
    func syncPSNVault(entries: [RomCatalogEntry],
                      presentExternalIDs: Set<String>) async throws -> RomCatalogSyncCounts {
        let src = VaultSource.psn.storage
        return try await dbWriter.write { db in
            var counts = RomCatalogSyncCounts()
            let now = Date()

            var existing: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, relative_path FROM rom_catalog WHERE source = ?
                """, arguments: [src]) {
                existing[row["relative_path"]] = row["id"]
            }

            for entry in entries {
                if let id = existing[entry.relativePath] {
                    try db.execute(sql: """
                        UPDATE rom_catalog SET
                            platform_id = ?, name = ?, sort_title = ?, normalised_title = ?,
                            cover_url = ?, membership = ?, cross_gen_note = ?, external_id = ?,
                            last_seen_at = ?, removed_at = NULL
                        WHERE id = ?
                        """, arguments: [
                            entry.platformID, entry.name, entry.sortTitle, entry.normalisedTitle,
                            entry.coverURL, entry.membership, entry.crossGenNote,
                            entry.externalIDColumn ?? entry.relativePath, now, id,
                        ])
                    counts.updated += 1
                } else {
                    try db.execute(sql: """
                        INSERT INTO rom_catalog
                            (source, system, platform_id, relative_path, name, sort_title,
                             normalised_title, cover_url, membership, cross_gen_note, external_id,
                             first_seen_at, last_seen_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            src, entry.system, entry.platformID, entry.relativePath, entry.name,
                            entry.sortTitle, entry.normalisedTitle, entry.coverURL, entry.membership,
                            entry.crossGenNote, entry.externalIDColumn ?? entry.relativePath, now, now,
                        ])
                    counts.added += 1
                }
            }

            // Vanished claims (or ones that crossed the gate) → removed_at.
            for (path, id) in existing where !presentExternalIDs.contains(path) {
                try db.execute(sql: """
                    UPDATE rom_catalog SET removed_at = ? WHERE id = ? AND removed_at IS NULL
                    """, arguments: [now, id])
                if db.changesCount > 0 { counts.removed += 1 }
            }
            return counts
        }
    }

    // MARK: - The Vault: IGDB trait pass (PLAN §16)

    /// The next batch of PS Plus entries needing an IGDB match (present, not retired, not yet
    /// attempted — `match_state IS NULL`), so a matched **or** no-matched entry is never
    /// re-queried. Ordered by name for a stable pass.
    func unmatchedPSN(limit: Int) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog
                WHERE source = ? AND removed_at IS NULL AND not_interested = 0
                  AND match_state IS NULL
                ORDER BY sort_title ASC, id ASC LIMIT ?
                """, arguments: [VaultSource.psn.storage, limit]).map(Self.entry(from:))
        }
    }

    /// Matched / total present PS Plus counts for the Settings status line ("Vault: 212 of 310
    /// matched", PLAN §16). One read.
    func psnMatchProgress() async throws -> (matched: Int, total: Int) {
        try await dbWriter.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog WHERE source = ? AND removed_at IS NULL
                """, arguments: [VaultSource.psn.storage]) ?? 0
            let matched = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog
                WHERE source = ? AND removed_at IS NULL AND match_state = ?
                """, arguments: [VaultSource.psn.storage, VaultMatchState.matched.rawValue]) ?? 0
            return (matched, total)
        }
    }

    /// Persist an IGDB match on a PS Plus Vault entry (PLAN §16): id, traits, time-to-beat,
    /// rating — and mark it matched so it is never re-queried.
    func setVaultMatch(id: Int64, igdbID: Int64, traits: [GameTrait],
                       lengthMainSeconds: Int?, lengthCompleteSeconds: Int?,
                       igdbRating: Double?) async throws {
        let json = RomCatalogEntry.encodeTraits(traits)
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE rom_catalog SET
                    igdb_id = ?, traits_json = ?, length_main_s = ?, length_complete_s = ?,
                    igdb_rating = ?, match_state = ?, matched_at = ?
                WHERE id = ?
                """, arguments: [
                    igdbID, json, lengthMainSeconds, lengthCompleteSeconds, igdbRating,
                    VaultMatchState.matched.rawValue, Date(), id,
                ])
        }
    }

    /// Mark a PS Plus Vault entry as having no IGDB match (PLAN §16) — browsable but never
    /// re-queried and never suggested.
    func setVaultNoMatch(id: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE rom_catalog SET match_state = ?, matched_at = ? WHERE id = ?
                """, arguments: [VaultMatchState.noMatch.rawValue, Date(), id])
        }
    }

    // MARK: - The Vault: promotion + "From the vault" pool (PLAN §16)

    /// Link a Vault row to the library game it was promoted into, by `(source, external id)`
    /// — used when a PS Plus entry is committed as the owned-via-subscription copy (PLAN §16).
    /// Idempotent.
    func setPromotedByExternalID(source: String, externalID: String, gameID: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE rom_catalog SET promoted_game_id = ?
                WHERE source = ? AND (external_id = ? OR relative_path = ?)
                """, arguments: [gameID, source, externalID, externalID])
        }
    }

    /// The "From the vault" candidate pool over **both** sources (PLAN §16): present, not
    /// promoted, not retired, and — for the never-played Batocera rows — no recorded play time;
    /// PS Plus rows are included only when matched to IGDB (`isSuggestable`). Optionally scoped
    /// to skip a set of systems (the Batocera skip list). Returns Batocera + matched PS Plus.
    func vaultPool(skipSystems: Set<String> = [], limit: Int = 2000) async throws -> [RomCatalogEntry] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM rom_catalog
                WHERE removed_at IS NULL AND promoted_game_id IS NULL AND not_interested = 0
                  AND (
                        (source = 'batocera' AND game_time_s = 0 AND play_count = 0)
                     OR (source = 'psn' AND match_state = 'matched')
                  )
                ORDER BY sort_title ASC LIMIT ?
                """, arguments: [limit])
                .map(Self.entry(from:))
                .filter { $0.system.isEmpty || !skipSystems.contains($0.system) }
        }
    }

    /// Link any Vault row of `source` to a library game that now owns a product with the same
    /// `external_id` — the **promotion-on-play** bridge (PLAN §16): after a PS Plus claim crosses
    /// the 10-minute gate and is imported as an owned-via-subscription copy, its Vault row points
    /// at the new game so the browser shows "In Library". Idempotent; only fills empty links.
    func linkPromotedFromProducts(source: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE rom_catalog
                SET promoted_game_id = (
                    SELECT pg.game_id FROM products p
                    JOIN product_games pg ON pg.product_id = p.id
                    WHERE p.source = ? AND p.external_id = rom_catalog.external_id
                    ORDER BY pg.position LIMIT 1)
                WHERE source = ? AND external_id IS NOT NULL AND promoted_game_id IS NULL
                  AND EXISTS (
                    SELECT 1 FROM products p JOIN product_games pg ON pg.product_id = p.id
                    WHERE p.source = ? AND p.external_id = rom_catalog.external_id)
                """, arguments: [source, source, source])
        }
    }

    // MARK: - The Vault: manual "Send to the Vault" (PLAN §16 — three fates)

    /// The result of a manual send, so the review sheet's one-step Undo removes exactly the rows
    /// it created and leaves refreshed ones alone.
    struct VaultSendResult: Sendable, Equatable {
        var insertedIDs: [Int64] = []
        var updatedIDs: [Int64] = []
        var affectedIDs: [Int64] { insertedIDs + updatedIDs }
    }

    /// Upsert entries the owner sent to the Vault by hand (PLAN §16). Keyed by
    /// `(source, system, relative_path)`; a present row refreshes, a new one is inserted. Carries
    /// the `owned` flag (a purchase never gets the PS Plus boost), any IGDB id the review row
    /// already had, `membership`, cover URL and cross-gen note. Never marks anything removed.
    @discardableResult
    func sendToVault(_ entries: [RomCatalogEntry]) async throws -> VaultSendResult {
        guard !entries.isEmpty else { return VaultSendResult() }
        return try await dbWriter.write { db in
            var result = VaultSendResult()
            let now = Date()
            for e in entries {
                let existing = try Int64.fetchOne(db, sql: """
                    SELECT id FROM rom_catalog WHERE source = ? AND system = ? AND relative_path = ?
                    """, arguments: [e.source, e.system, e.relativePath])
                if let id = existing {
                    try db.execute(sql: """
                        UPDATE rom_catalog SET
                            platform_id = ?, name = ?, sort_title = ?, normalised_title = ?,
                            cover_url = ?, membership = ?, cross_gen_note = ?, external_id = ?,
                            igdb_id = COALESCE(?, igdb_id), owned = ?, last_seen_at = ?, removed_at = NULL
                        WHERE id = ?
                        """, arguments: [
                            e.platformID, e.name, e.sortTitle, e.normalisedTitle, e.coverURL,
                            e.membership, e.crossGenNote, e.externalIDColumn ?? e.relativePath,
                            e.igdbID, e.owned, now, id])
                    result.updatedIDs.append(id)
                } else {
                    try db.execute(sql: """
                        INSERT INTO rom_catalog
                            (source, system, platform_id, relative_path, name, sort_title,
                             normalised_title, cover_url, membership, cross_gen_note, external_id,
                             igdb_id, owned, first_seen_at, last_seen_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            e.source, e.system, e.platformID, e.relativePath, e.name, e.sortTitle,
                            e.normalisedTitle, e.coverURL, e.membership, e.crossGenNote,
                            e.externalIDColumn ?? e.relativePath, e.igdbID, e.owned, now, now])
                    result.insertedIDs.append(db.lastInsertedRowID)
                }
            }
            return result
        }
    }

    /// Hard-delete Vault rows (the Undo of a manual "Send to the Vault"). Only used to reverse a
    /// send this session created, so a soft `removed_at` is not enough (the row must not linger).
    func deleteEntries(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await dbWriter.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            try db.execute(sql: "DELETE FROM rom_catalog WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(ids))
        }
    }

    // MARK: - Row decode

    static func entry(from r: Row) -> RomCatalogEntry {
        RomCatalogEntry(
            id: r["id"], source: r["source"], system: r["system"], platformID: r["platform_id"],
            relativePath: r["relative_path"], name: r["name"], sortTitle: r["sort_title"],
            normalisedTitle: r["normalised_title"], libretroKey: r["libretro_key"],
            screenScraperID: r["screenscraper_id"], md5: r["md5"], region: r["region"],
            lang: r["lang"], genre: r["genre"], family: r["family"], developer: r["developer"],
            publisher: r["publisher"], releaseYear: r["release_year"], rating: r["rating"],
            players: r["players"], playCount: r["play_count"], gameTimeSeconds: r["game_time_s"],
            lastPlayedAt: r["last_played_at"], isFavorite: (r["favorite"] as Int64) != 0,
            imagePath: r["image_path"], thumbnailPath: r["thumbnail_path"],
            firstSeenAt: r["first_seen_at"], lastSeenAt: r["last_seen_at"],
            removedAt: r["removed_at"], promotedGameID: r["promoted_game_id"],
            dismissedAt: r["dismissed_at"], notInterested: (r["not_interested"] as Int64) != 0,
            externalIDColumn: r["external_id"], coverURL: r["cover_url"],
            membership: r["membership"], crossGenNote: r["cross_gen_note"],
            igdbID: r["igdb_id"], lengthMainSeconds: r["length_main_s"],
            lengthCompleteSeconds: r["length_complete_s"], traitsJSON: r["traits_json"],
            igdbRating: r["igdb_rating"],
            matchState: (r["match_state"] as String?).flatMap(VaultMatchState.init(rawValue:)),
            matchedAt: r["matched_at"],
            owned: (r["owned"] as Int64? ?? 0) != 0)
    }
}

/// Minimal FTS5 query builder for catalogue search: split into terms, escape each as a
/// quoted token, and prefix-match the last term (so "zel" finds "Zelda" as the user types).
enum FTSPattern {
    static func prefixMatch(_ query: String) -> String {
        let terms = query
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !terms.isEmpty else { return "" }
        var parts: [String] = []
        for (i, term) in terms.enumerated() {
            let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            parts.append(i == terms.count - 1 ? quoted + "*" : quoted)
        }
        return parts.joined(separator: " ")
    }
}

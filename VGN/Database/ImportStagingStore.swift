import Foundation
import GRDB

/// The spec for a **new** game created by an import commit (PLAN §14.3). Games land
/// *owned, not played* (Backlog); no tier/rank/played is ever touched.
struct ImportNewGameSpec: Sendable, Equatable {
    var title: String
    var igdbID: Int64?
    var releaseYear: Int?
    var altTitles: [String]

    init(title: String, igdbID: Int64? = nil, releaseYear: Int? = nil, altTitles: [String] = []) {
        self.title = title
        self.igdbID = igdbID
        self.releaseYear = releaseYear
        self.altTitles = altTitles
    }
}

/// One reviewed row to commit (PLAN §14.3). The `(source, externalID)` pair is the
/// idempotency key: committing the same item twice creates nothing new.
struct ImportCommitItem: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        /// Create a new library game and attach the import Product to it.
        case newGame(ImportNewGameSpec)
        /// Attach the import Product to an existing library game.
        case existingGame(gameID: Int64)
        /// A bundle/pack → a compilation Product with these member games (PLAN §5.1).
        case compilation(title: String?, members: [CompilationMemberDraft])
    }

    var source: String
    var externalID: String
    var platformID: String
    var format: ProductFormat
    var target: Target
    /// Edition to record on the committed copy (Delicious, PLAN §5.5). nil for GOG/PSN.
    var edition: String?
    /// When the copy was acquired, recorded on the committed product. nil for GOG/PSN.
    var acquiredAt: Date?
    /// **(PSN)** Extra outcomes a PSN row commits beyond a plain owned copy (PLAN §13.3 —
    /// played-without-a-copy, PSN play time, a status pre-fill, a PS Plus subscription
    /// flag). nil ⇒ the plain GOG/Delicious path, byte-for-byte unchanged.
    var psn: PSNCommit?

    init(source: String, externalID: String, platformID: String,
         format: ProductFormat = .digital, target: Target,
         edition: String? = nil, acquiredAt: Date? = nil, psn: PSNCommit? = nil) {
        self.source = source
        self.externalID = externalID
        self.platformID = platformID
        self.format = format
        self.target = target
        self.edition = edition
        self.acquiredAt = acquiredAt
        self.psn = psn
    }
}

/// The PSN-specific outcomes one reviewed row commits (PLAN §13.3). Additive — a nil
/// ``ImportCommitItem/psn`` keeps the GOG/Delicious commit path exactly as it was.
struct PSNCommit: Sendable, Equatable {
    /// Create the owned digital Product (a purchase). false = **played-only**, no copy.
    var createProduct: Bool
    /// A PS Plus / raw membership flag on the created product (v8). nil = really owned.
    var subscription: String?
    /// Mark the game **played** (+ per-platform played flag) without requiring a copy.
    var markPlayed: Bool
    /// PSN play time in seconds → `psn_playtime_s` (never overwrites manual `my_playtime_s`).
    var playDurationS: Int?
    /// A completion status to pre-fill **only when the game has none** (100 % title).
    var statusPrefill: PlayStatus?
    /// Earliest / latest known play date (v9, PLAN §13.3). Written monotonically
    /// (`first` only earlier, `last` only later; a nil never overwrites) by
    /// ``LibraryStore/setPSNPlayedDates(gameID:first:last:db:)``.
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?

    init(createProduct: Bool, subscription: String? = nil, markPlayed: Bool = false,
         playDurationS: Int? = nil, statusPrefill: PlayStatus? = nil,
         firstPlayedAt: Date? = nil, lastPlayedAt: Date? = nil) {
        self.createProduct = createProduct
        self.subscription = subscription
        self.markPlayed = markPlayed
        self.playDurationS = playDurationS
        self.statusPrefill = statusPrefill
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
    }
}

/// One PS Plus claim that a committed copy carries but the latest sync no longer lists —
/// **proposed** for removal in the review sheet, never applied silently (PLAN §13.3).
struct ImportSubscriptionRemovalProposal: Sendable, Equatable, Identifiable {
    var productID: Int64
    var externalID: String
    var gameID: Int64?
    var gameTitle: String?
    var subscription: String
    var id: Int64 { productID }
}

/// What a commit changed (PLAN §14.3).
struct ImportCommitResult: Sendable, Equatable {
    var gamesCreated: Int = 0
    var productsAdded: Int = 0
    /// Items skipped because their `(source, external_id)` Product already existed.
    var skippedExisting: Int = 0
    var affectedGameIDs: [Int64] = []
}

/// The staging side of every importer (PLAN §14.3): upsert `import_titles` rows while
/// **preserving earlier decisions** (`matched_game_id`, `ignored`), read the review
/// buckets, record decisions, and `commit` a reviewed set in **one** transaction —
/// digital Products keyed `(source, external_id)` for idempotency, games created
/// *owned, not played*, compilations via the existing store API, never touching a
/// played flag, tier or rank.
struct ImportStagingStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    // MARK: - Upsert (decisions preserved)

    /// Upsert one batch of staging rows. First insert of a noise row is `ignored = 1`
    /// (ignored by default, PLAN §14.3); on re-sync the refreshed metadata is written
    /// but `matched_game_id` and `ignored` are **kept** (the persisted decision wins).
    func upsert(_ rows: [ImportStagingRow]) async throws {
        guard !rows.isEmpty else { return }
        try await dbWriter.write { db in
            for row in rows { try Self.upsertOne(row, db) }
        }
    }

    static func upsertOne(_ row: ImportStagingRow, _ db: Database) throws {
        let ignoredDefault = row.ignoreReason != nil
        try db.execute(sql: """
            INSERT INTO import_titles
                (source, external_id, name, platform, signals,
                 play_duration_s, first_played_at, last_played_at, matched_game_id, ignored)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            ON CONFLICT(source, external_id) DO UPDATE SET
                name            = excluded.name,
                platform        = excluded.platform,
                signals         = excluded.signals,
                play_duration_s = excluded.play_duration_s,
                first_played_at = excluded.first_played_at,
                last_played_at  = excluded.last_played_at
            """, arguments: [
                row.source, row.externalID, row.name, row.platform,
                row.signals.storageString, row.playDurationS,
                row.firstPlayedAt, row.lastPlayedAt, ignoredDefault,
            ])
    }

    // MARK: - Owned-copy snapshot (duplicate rule)

    /// One owned copy already in the library, keyed by IGDB id + platform + format, for
    /// the Delicious "discard duplicate copies" rule (PLAN §5.5). The owner catalogued
    /// his shelf by photo scan, so a Delicious row whose match already has an owned copy
    /// of the **same format on the same platform** is a duplicate and is never re-added.
    struct OwnedCopy: Sendable, Hashable {
        var igdbID: Int64
        var platform: String
        var format: ProductFormat
        var gameID: Int64
    }

    /// Every owned single/compilation copy tied to a game that carries an IGDB id.
    func ownedCopies() async throws -> [OwnedCopy] {
        try await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.igdb_id AS igdb_id, p.platform_id AS platform_id,
                       p.format AS format, g.id AS game_id
                FROM games g
                JOIN product_games pg ON pg.game_id = g.id
                JOIN products p ON p.id = pg.product_id
                WHERE g.igdb_id IS NOT NULL
                """).compactMap { row in
                guard let format = ProductFormat(rawValue: row["format"]) else { return nil }
                return OwnedCopy(igdbID: row["igdb_id"], platform: row["platform_id"],
                                 format: format, gameID: row["game_id"])
            }
        }
    }

    // MARK: - Reads (review buckets)

    /// Every staged title for a source, as review-sheet projections.
    func titles(source: String) async throws -> [ImportStagedTitle] {
        try await dbWriter.read { db in
            try ImportTitleRecord
                .filter(ImportTitleRecord.Columns.source == source)
                .order(ImportTitleRecord.Columns.name)
                .fetchAll(db)
                .map(Self.staged(from:))
        }
    }

    /// The review buckets for a source (PLAN §14.3 — *New / Already matched / Ignored*).
    func buckets(source: String) async throws -> [ImportReviewBucket: [ImportStagedTitle]] {
        let all = try await titles(source: source)
        return Dictionary(grouping: all, by: \.bucket)
    }

    static func staged(from r: ImportTitleRecord) -> ImportStagedTitle {
        ImportStagedTitle(
            id: r.id ?? 0, source: r.source, externalID: r.externalID, name: r.name,
            platform: r.platform, signals: ImportSignals(storageString: r.signals),
            matchedGameID: r.matchedGameID, ignored: r.ignored)
    }

    // MARK: - Decisions

    /// Record a decision on one staged title (PLAN §14.3 — persisted so re-sync only
    /// surfaces new titles).
    func setDecision(source: String, externalID: String, _ decision: ImportDecision) async throws {
        try await dbWriter.write { db in
            switch decision {
            case .match(let gameID):
                try db.execute(sql: """
                    UPDATE import_titles SET matched_game_id = ?, ignored = 0
                    WHERE source = ? AND external_id = ?
                    """, arguments: [gameID, source, externalID])
            case .unmatch:
                try db.execute(sql: """
                    UPDATE import_titles SET matched_game_id = NULL
                    WHERE source = ? AND external_id = ?
                    """, arguments: [source, externalID])
            case .ignore:
                try db.execute(sql: "UPDATE import_titles SET ignored = 1 WHERE source = ? AND external_id = ?",
                               arguments: [source, externalID])
            case .restore:
                try db.execute(sql: "UPDATE import_titles SET ignored = 0 WHERE source = ? AND external_id = ?",
                               arguments: [source, externalID])
            }
        }
    }

    // MARK: - Commit (one transaction)

    /// Commit a reviewed set in a single transaction (PLAN §14.3). Idempotent: an item
    /// whose `(source, external_id)` Product already exists is skipped. New games are
    /// created *owned, not played*; existing library games get the Product added;
    /// bundles become compilation Products. Played/tier/rank are never touched. Also
    /// records `matched_game_id` on the staging row so a later sync sees the title as
    /// already matched.
    @discardableResult
    func commit(_ items: [ImportCommitItem]) async throws -> ImportCommitResult {
        guard !items.isEmpty else { return ImportCommitResult() }
        return try await dbWriter.write { db in
            var result = ImportCommitResult()
            for item in items {
                // PSN rows take an additive path (played-only, playtime, status, PS Plus,
                // idempotent updates); everything else is byte-for-byte the old behaviour.
                if item.psn != nil {
                    try Self.commitPSNItem(item, db: db, result: &result)
                    continue
                }
                // Idempotency guard: already committed?
                if try LibraryStore.existingImportProductID(
                    sourceRaw: item.source, externalID: item.externalID, db: db) != nil {
                    result.skippedExisting += 1
                    continue
                }
                switch item.target {
                case .existingGame(let gameID):
                    let (_, created) = try LibraryStore.attachSingleImportProduct(
                        gameID: gameID, platformID: item.platformID, format: item.format,
                        sourceRaw: item.source, externalID: item.externalID,
                        edition: item.edition, acquiredAt: item.acquiredAt, db: db)
                    if created { result.productsAdded += 1 }
                    result.affectedGameIDs.append(gameID)
                    try Self.markMatched(source: item.source, externalID: item.externalID,
                                         gameID: gameID, db: db)

                case .newGame(let spec):
                    // The game's origin is the importer's source (owner request):
                    // pass it as the draft source so `insert` tags it, even though
                    // the owned Product is attached separately below.
                    let draft = GameDraft(
                        title: spec.title, igdbID: spec.igdbID, year: spec.releaseYear,
                        altTitles: spec.altTitles, platformIDs: [item.platformID],
                        owned: false, played: false,
                        source: ProductSource(rawValue: item.source) ?? .manual)
                    let outcome = try LibraryStore.insert(draft, db)
                    let gameID = outcome.gameID
                    if case .created = outcome { result.gamesCreated += 1 }
                    let (_, created) = try LibraryStore.attachSingleImportProduct(
                        gameID: gameID, platformID: item.platformID, format: item.format,
                        sourceRaw: item.source, externalID: item.externalID,
                        edition: item.edition, acquiredAt: item.acquiredAt, db: db)
                    if created { result.productsAdded += 1 }
                    result.affectedGameIDs.append(gameID)
                    try Self.markMatched(source: item.source, externalID: item.externalID,
                                         gameID: gameID, db: db)

                case .compilation(let title, let members):
                    let productID = try LibraryStore.insertImportProductRow(
                        platformID: item.platformID, format: item.format,
                        sourceRaw: item.source, externalID: item.externalID,
                        kindRaw: "compilation", title: title,
                        edition: item.edition, acquiredAt: item.acquiredAt, db: db)
                    result.productsAdded += 1
                    let memberSource = ProductSource(rawValue: item.source) ?? .manual
                    for member in members {
                        let outcome = try LibraryStore.upsertCompilationMember(
                            member, productID: productID, platformID: item.platformID,
                            source: memberSource, db: db)
                        if case .created = outcome { result.gamesCreated += 1 }
                        result.affectedGameIDs.append(outcome.gameID)
                    }
                }
            }
            return result
        }
    }

    // MARK: - PSN commit (additive, PLAN §13.3)

    /// Commit one PSN row: resolve/create the game, optionally attach an owned digital
    /// Product (with a PS Plus flag), optionally mark it played without a copy, set the
    /// PSN play time, and pre-fill a status if none — all idempotent. Unlike the plain
    /// path it does **not** early-skip an already-committed product, so a changed play time
    /// or a newly-launched title updates on re-sync.
    private static func commitPSNItem(_ item: ImportCommitItem, db: Database,
                                      result: inout ImportCommitResult) throws {
        guard let psn = item.psn else { return }

        // Resolve the game id.
        let gameID: Int64
        switch item.target {
        case .existingGame(let id):
            gameID = id
        case .newGame(let spec):
            let draft = GameDraft(
                title: spec.title, igdbID: spec.igdbID, year: spec.releaseYear,
                altTitles: spec.altTitles, platformIDs: [item.platformID],
                owned: false, played: psn.markPlayed, source: .psn)
            let outcome = try LibraryStore.insert(draft, db)
            gameID = outcome.gameID
            if case .created = outcome { result.gamesCreated += 1 }
        case .compilation:
            return   // PSN never commits a compilation.
        }

        // Owned digital copy (a purchase) — idempotent; carries the PS Plus flag.
        if psn.createProduct {
            let (_, created) = try LibraryStore.attachSingleImportProduct(
                gameID: gameID, platformID: item.platformID, format: item.format,
                sourceRaw: item.source, externalID: item.externalID,
                subscription: psn.subscription, db: db)
            if created { result.productsAdded += 1 }
        }

        // Played without a copy (a trophy title).
        if psn.markPlayed {
            try LibraryStore.markPlayedWithoutCopy(gameID: gameID, platformID: item.platformID, db: db)
        }
        // PSN play time (never overwrites a manual value).
        try LibraryStore.setPSNPlaytime(gameID: gameID, seconds: psn.playDurationS, db: db)
        // Earliest / latest known play date (monotonic; nil never overwrites).
        try LibraryStore.setPSNPlayedDates(gameID: gameID, first: psn.firstPlayedAt,
                                           last: psn.lastPlayedAt, db: db)
        // Status pre-fill only when the game has none.
        if let status = psn.statusPrefill {
            try LibraryStore.prefillStatusIfNone(gameID: gameID, status: status, db: db)
        }

        result.affectedGameIDs.append(gameID)
        try markMatched(source: item.source, externalID: item.externalID, gameID: gameID, db: db)
    }

    /// Every committed subscription (PS Plus) copy whose claim is **absent** from the
    /// current sync's external ids — proposed for removal in the review sheet, never
    /// applied here (PLAN §13.3). `currentExternalIDs` are the external ids the latest
    /// fetch produced (from ``PSNMapping``).
    func proposedSubscriptionRemovals(source: String,
                                      currentExternalIDs: Set<String>) async throws -> [ImportSubscriptionRemovalProposal] {
        try await dbWriter.read { db in
            try LibraryStore.committedSubscriptionCopies(sourceRaw: source, db: db).compactMap { copy in
                guard !currentExternalIDs.contains(copy.externalID) else { return nil }
                let sub: String = (try String.fetchOne(db, sql: "SELECT subscription FROM products WHERE id = ?",
                                                        arguments: [copy.productID])) ?? ""
                let gameRow = try Row.fetchOne(db, sql: """
                    SELECT g.id AS gid, g.title AS title FROM games g
                    JOIN product_games pg ON pg.game_id = g.id WHERE pg.product_id = ? LIMIT 1
                    """, arguments: [copy.productID])
                return ImportSubscriptionRemovalProposal(
                    productID: copy.productID, externalID: copy.externalID,
                    gameID: gameRow?["gid"], gameTitle: gameRow?["title"], subscription: sub)
            }
        }
    }

    /// Apply the owner-confirmed subscription-copy removals (PLAN §13.3 — a PS Plus claim
    /// the latest sync no longer lists, removed only after an explicit confirm in the review
    /// sheet). One transaction: delete each product, then delete any game left neither owned
    /// nor played (a lapsed claim never played is gone). A game still played (its trophy
    /// record) survives as *played, not owned*. Returns the number of products removed.
    @discardableResult
    func applySubscriptionRemovals(_ productIDs: [Int64]) async throws -> Int {
        guard !productIDs.isEmpty else { return 0 }
        return try await dbWriter.write { db in
            var removed = 0
            for pid in productIDs {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM products WHERE id = ?)",
                                        arguments: [pid]) ?? false else { continue }
                let members = try Int64.fetchAll(
                    db, sql: "SELECT game_id FROM product_games WHERE product_id = ?", arguments: [pid])
                try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [pid])
                _ = try LibraryStore.resolveOrphans(members, confirmOrphanDelete: true, db: db)
                removed += 1
            }
            return removed
        }
    }

    private static func markMatched(source: String, externalID: String, gameID: Int64, db: Database) throws {
        try db.execute(sql: """
            UPDATE import_titles SET matched_game_id = ? WHERE source = ? AND external_id = ?
            """, arguments: [gameID, source, externalID])
    }
}

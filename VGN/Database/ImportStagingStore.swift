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

    init(source: String, externalID: String, platformID: String,
         format: ProductFormat = .digital, target: Target) {
        self.source = source
        self.externalID = externalID
        self.platformID = platformID
        self.format = format
        self.target = target
    }
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
                        sourceRaw: item.source, externalID: item.externalID, db: db)
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
                        sourceRaw: item.source, externalID: item.externalID, db: db)
                    if created { result.productsAdded += 1 }
                    result.affectedGameIDs.append(gameID)
                    try Self.markMatched(source: item.source, externalID: item.externalID,
                                         gameID: gameID, db: db)

                case .compilation(let title, let members):
                    let productID = try LibraryStore.insertImportProductRow(
                        platformID: item.platformID, format: item.format,
                        sourceRaw: item.source, externalID: item.externalID,
                        kindRaw: "compilation", title: title, db: db)
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

    private static func markMatched(source: String, externalID: String, gameID: Int64, db: Database) throws {
        try db.execute(sql: """
            UPDATE import_titles SET matched_game_id = ? WHERE source = ? AND external_id = ?
            """, arguments: [gameID, source, externalID])
    }
}

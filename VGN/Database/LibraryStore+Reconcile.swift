import Foundation
import GRDB

// MARK: - Reconcile value types (PLAN §5.1 "Reconciling unlinked games")

/// Errors specific to linking a game to an IGDB entry / merging games.
enum ReconcileError: Error, Sendable, Equatable {
    case notFound
    /// The requested IGDB id already belongs to a *different* library game
    /// (`games.igdb_id` is `UNIQUE`) — the caller should MERGE into that game
    /// instead of setting the id (which would violate the constraint).
    case alreadyLinked(existingGameID: Int64)
}

/// One owned copy of a game as it matters to a merge decision (a slim read of a
/// `products ⋈ product_games` row). Pure value — the merge planner is testable.
struct ReconcileCopy: Sendable, Hashable, Identifiable {
    var productID: Int64
    var platformID: String
    var format: ProductFormat
    var source: ProductSource
    var externalID: String?
    var edition: String?
    var region: String?
    var acquiredAt: Date?
    var psnEntitlement: String?
    /// The product has more than one member game (a compilation) — never collapsed;
    /// merging only re-points this game's membership.
    var isCompilation: Bool
    // TODO(PSN merge): once `products.subscription` lands (PSN lane), carry it here and
    // never collapse a subscription copy into a non-subscription one (rule 4).

    var id: Int64 { productID }
}

/// What happens to one copy of the game being merged in, decided against the target's
/// copies (owner rules, 2026-09-19 — see the merge confirmation sheet).
enum CopyMergeOutcome: Sendable, Equatable {
    /// Different platform/format (rule 1), or a same-platform digital copy from another
    /// store (rule 3, different licences), or a compilation membership → kept on the
    /// merged game (its product_games row is re-pointed to the target).
    case keep
    /// Same platform + same format as a target copy → collapsed into it. The target
    /// copy survives and is enriched (edition / region / acquired date / entitlement,
    /// keeping the earliest acquired date). `keepBothAllowed` is true for a
    /// physical/ROM copy from a *different source* (rule 3): the owner can override to
    /// keep both; false for the very same imported copy (rule 2, silent).
    case collapse(into: Int64, keepBothAllowed: Bool)
}

/// A resolved decision for one source copy, plus the owner's keep-both override. The
/// UI builds these from ``MergePlanner`` defaults and lets the owner flip the toggle.
struct CopyMergeDecision: Sendable, Equatable, Identifiable {
    let sourceProductID: Int64
    let platformID: String
    let format: ProductFormat
    let source: ProductSource
    let outcome: CopyMergeOutcome
    /// Owner override for a `collapse(keepBothAllowed: true)` row — keep both copies.
    var keepBoth: Bool = false

    var id: Int64 { sourceProductID }

    /// The outcome after applying the keep-both override.
    var effectiveOutcome: CopyMergeOutcome {
        if case .collapse(_, let allowed) = outcome, allowed, keepBoth { return .keep }
        return outcome
    }

    init(copy: ReconcileCopy, outcome: CopyMergeOutcome, keepBoth: Bool = false) {
        self.sourceProductID = copy.productID
        self.platformID = copy.platformID
        self.format = copy.format
        self.source = copy.source
        self.outcome = outcome
        self.keepBoth = keepBoth
    }
}

/// Pure per-copy merge policy (owner rules 1–4, 2026-09-19). Foundation only — no DB.
enum MergePlanner {
    /// Default decisions for merging `source`'s copies into a game whose copies are
    /// `target`. Rule 4 (never collapse a subscription copy) is a TODO until the
    /// `products.subscription` column lands.
    static func plan(source: [ReconcileCopy], target: [ReconcileCopy]) -> [CopyMergeDecision] {
        source.map { decide($0, against: target) }
    }

    static func decide(_ sc: ReconcileCopy, against target: [ReconcileCopy]) -> CopyMergeDecision {
        // A compilation membership is always kept (re-pointed) — never collapsed.
        if sc.isCompilation {
            return CopyMergeDecision(copy: sc, outcome: .keep)
        }
        // Rule 1: no target copy on the same platform + format → keep both.
        guard let tc = target.first(where: {
            $0.platformID == sc.platformID && $0.format == sc.format && !$0.isCompilation
        }) else {
            return CopyMergeDecision(copy: sc, outcome: .keep)
        }
        // Rule 2: literally the same imported copy → collapse silently.
        if let ext = sc.externalID, let text = tc.externalID, sc.source == tc.source, ext == text {
            return CopyMergeDecision(copy: sc, outcome: .collapse(into: tc.productID, keepBothAllowed: false))
        }
        // Rule 3.
        switch sc.format {
        case .digital:
            // Different stores = different licences → keep both.
            return CopyMergeDecision(copy: sc, outcome: .keep)
        case .physical, .rom:
            // Almost certainly the same physical object catalogued twice → default keep
            // one (enriched), with an owner override to keep both.
            return CopyMergeDecision(copy: sc, outcome: .collapse(into: tc.productID, keepBothAllowed: true))
        }
    }
}

/// Everything the merge confirmation sheet needs: the two titles, both copy sets, the
/// default per-copy plan, and the human-readable "Game details" outcome lines.
struct MergeInputs: Sendable {
    var sourceGameID: Int64
    var targetGameID: Int64
    var sourceTitle: String
    var targetTitle: String
    var sourceCopies: [ReconcileCopy]
    var targetCopies: [ReconcileCopy]
    var decisions: [CopyMergeDecision]
    /// "Game details" lines (played / status / playtime / tier outcome).
    var detailLines: [String]
    /// Both games are ranked — the target's tier/rank is kept and this is called out.
    var bothRanked: Bool
}

/// An in-memory, row-level snapshot of everything a link / merge / relink touched, so
/// the operation is exactly reversible (`UndoManager` — restore the rows verbatim).
/// Captured *inside* the write transaction, held by ``LibraryActions`` for undo.
struct ReconcileUndo: Sendable {
    var actionName: String
    /// The game ids whose rows (and their products/joins/history) the snapshot covers.
    var gameIDs: [Int64]
    var snapshot: ReconcileSnapshot
}

/// The captured rows. Records are `Sendable`; the snapshot crosses the actor hop to the
/// `@MainActor` undo target.
struct ReconcileSnapshot: Sendable {
    var games: [GameRecord]
    /// Products are snapshotted as raw column dictionaries (not ``ProductRecord``, which
    /// does not map the v5 `external_id` / any later column) so undo restores every
    /// product column verbatim — including `external_id`, keeping importer idempotency.
    var products: [ReconcileProductRow]
    /// Full membership of every involved product (not just the snapshotted games'), so
    /// a product shared with other games is restored without dropping them.
    var productGames: [ProductGameRecord]
    var platforms: [GamePlatformRecord]
    var genres: [GameGenreRecord]
    var traits: [ReconcileTraitRow]
    var comparisons: [ComparisonRecord]
    var feedback: [ReconcileFeedbackRow]
    var importTitles: [ImportTitleRecord]
    var jobs: [EnrichmentJobRecord]
}

/// A raw `products` row as a column → value map, so **every** column round-trips
/// through undo regardless of which are mapped by ``ProductRecord`` (`external_id`, and
/// any column a later lane adds such as `subscription`). `DatabaseValue` is `Sendable`.
struct ReconcileProductRow: Sendable {
    var columns: [String: DatabaseValue]
    var id: Int64? { columns["id"].flatMap(Int64.fromDatabaseValue) }
}

/// GRDB record for `game_traits` (no shared record exists) — snapshot/restore only.
struct ReconcileTraitRow: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var gameID: Int64
    var kind: String
    var value: String
    static let databaseTableName = "game_traits"
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case gameID = "game_id"; case kind; case value
    }
    typealias Columns = CodingKeys
}

/// GRDB record for `rec_feedback` (no shared record exists) — snapshot/restore only.
struct ReconcileFeedbackRow: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var gameID: Int64
    var action: String
    var createdAt: Date
    static let databaseTableName = "rec_feedback"
    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id; case gameID = "game_id"; case action; case createdAt = "created_at"
    }
    typealias Columns = CodingKeys
}

// MARK: - Reconcile writes

extension LibraryStore {

    /// Every library game that carries an IGDB id → its game id. Used to mark search
    /// results "already in your library" and to route a chosen target to LINK vs MERGE.
    func igdbLinkIndex() async throws -> [Int64: Int64] {
        try await dbReader.read { db in
            var out: [Int64: Int64] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, igdb_id FROM games WHERE igdb_id IS NOT NULL")
            for row in rows { out[row["igdb_id"]] = row["id"] }
            return out
        }
    }

    /// The library game already holding `igdbID`, if any (excluding `excluding`).
    func existingGameID(forIGDBID igdbID: Int64, excluding: Int64? = nil) async throws -> Int64? {
        try await dbReader.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM games WHERE igdb_id = ? AND id != ?",
                               arguments: [igdbID, excluding ?? -1])
        }
    }

    /// LINK an unlinked game to an IGDB entry that is **not** already in the library
    /// (PLAN §5.1). Sets `igdb_id`; if the title is not user-edited, adopts the IGDB
    /// title and pushes the owner's old title into `alt_titles` (so search still finds
    /// it); clears a non-user-chosen cover so enrichment fetches the IGDB one. Never
    /// touches played / status / tier / rank / copies. Returns an undo snapshot.
    func linkGameToIGDB(gameID: Int64, igdbID: Int64, igdbTitle: String?) async throws -> ReconcileUndo {
        try await dbWriter.write { db in
            if let other = try Int64.fetchOne(
                db, sql: "SELECT id FROM games WHERE igdb_id = ? AND id != ?", arguments: [igdbID, gameID]) {
                throw ReconcileError.alreadyLinked(existingGameID: other)
            }
            guard var g = try GameRecord.fetchOne(db, key: gameID) else { throw ReconcileError.notFound }
            let snapshot = try Self.captureSnapshot([gameID], db)
            let edited = UserEditedFields(raw: g.userEdited)
            g.igdbID = igdbID
            Self.applyTitleAdopt(&g, igdbTitle: igdbTitle, edited: edited)
            if !edited.contains(.cover) { g.coverFile = nil; g.igdbCoverImageID = nil }
            g.updatedAt = Date()
            try g.update(db)
            return ReconcileUndo(actionName: "Link to IGDB", gameIDs: [gameID], snapshot: snapshot)
        }
    }

    /// RE-LINK an already-linked game to a *different* IGDB entry that is not in the
    /// library (PLAN §5.1). Replaces `igdb_id`, clears IGDB-sourced metadata that is not
    /// `user_edited` (so stale genre / year / ttb / cover / rating / traits do not
    /// survive), and re-applies the title-adopt rule. The caller resets the cover
    /// negative cache and re-enqueues enrichment. Returns an undo snapshot.
    func relinkGameInPlace(gameID: Int64, igdbID: Int64, igdbTitle: String?) async throws -> ReconcileUndo {
        try await dbWriter.write { db in
            if let other = try Int64.fetchOne(
                db, sql: "SELECT id FROM games WHERE igdb_id = ? AND id != ?", arguments: [igdbID, gameID]) {
                throw ReconcileError.alreadyLinked(existingGameID: other)
            }
            guard var g = try GameRecord.fetchOne(db, key: gameID) else { throw ReconcileError.notFound }
            let snapshot = try Self.captureSnapshot([gameID], db)
            let edited = UserEditedFields(raw: g.userEdited)
            if !edited.contains(.summary) { g.summary = nil }
            if !edited.contains(.year) { g.year = nil; g.releaseDate = nil }
            if !edited.contains(.rating) { g.igdbRating = nil; g.igdbRatingCount = nil }
            if !edited.contains(.cover) { g.coverFile = nil; g.igdbCoverImageID = nil }
            if !edited.contains(.genres) {
                try db.execute(sql: "DELETE FROM game_genres WHERE game_id = ?", arguments: [gameID])
            }
            if !edited.contains(.traits) {
                try db.execute(sql: "DELETE FROM game_traits WHERE game_id = ?", arguments: [gameID])
            }
            // Time-to-beat has no user_edited field — clear unless hand-edited.
            if g.ttbSource != "edited", g.ttbSource != "user" {
                g.ttbHastilyS = nil; g.ttbNormallyS = nil; g.ttbCompletelyS = nil; g.ttbSource = nil
            }
            if !edited.contains(.altTitles) { g.altTitles = "" }
            g.igdbID = igdbID
            Self.applyTitleAdopt(&g, igdbTitle: igdbTitle, edited: edited)
            g.updatedAt = Date()
            try g.update(db)
            return ReconcileUndo(actionName: "Change IGDB Match", gameIDs: [gameID], snapshot: snapshot)
        }
    }

    /// Read the two games' copies + a default merge plan + the "Game details" outcome
    /// lines for the merge confirmation sheet (pure over ``MergePlanner``).
    func mergeInputs(sourceGameID: Int64, targetGameID: Int64) async throws -> MergeInputs {
        try await dbReader.read { db in
            guard let source = try GameRecord.fetchOne(db, key: sourceGameID),
                  let target = try GameRecord.fetchOne(db, key: targetGameID)
            else { throw ReconcileError.notFound }
            let sourceCopies = try Self.copies(of: sourceGameID, db)
            let targetCopies = try Self.copies(of: targetGameID, db)
            let decisions = MergePlanner.plan(source: sourceCopies, target: targetCopies)
            let (lines, bothRanked) = Self.detailOutcomeLines(source: source, target: target, db)
            return MergeInputs(
                sourceGameID: sourceGameID, targetGameID: targetGameID,
                sourceTitle: source.title, targetTitle: target.title,
                sourceCopies: sourceCopies, targetCopies: targetCopies,
                decisions: decisions, detailLines: lines, bothRanked: bothRanked)
        }
    }

    /// MERGE `sourceGameID` into `targetGameID` (the game already holding the chosen
    /// IGDB id) in one transaction, applying `decisions` per copy (PLAN §5.1, owner
    /// rules 2026-09-19). The target survives; the source is deleted. Returns an undo
    /// snapshot restoring both games exactly.
    func mergeGame(sourceGameID: Int64, into targetGameID: Int64,
                   decisions: [CopyMergeDecision]) async throws -> ReconcileUndo {
        try await dbWriter.write { db in
            try Self.performMerge(source: sourceGameID, target: targetGameID, decisions: decisions, db)
        }
    }

    /// Undo a link / merge / relink by restoring its captured rows verbatim.
    func restoreReconcile(_ undo: ReconcileUndo) async throws {
        try await dbWriter.write { db in
            try Self.applySnapshot(undo.snapshot, gameIDs: undo.gameIDs, db)
        }
    }

    // MARK: - Merge implementation

    private static func performMerge(
        source sourceGameID: Int64, target targetGameID: Int64,
        decisions: [CopyMergeDecision], _ db: Database
    ) throws -> ReconcileUndo {
        guard var target = try GameRecord.fetchOne(db, key: targetGameID),
              let source = try GameRecord.fetchOne(db, key: sourceGameID)
        else { throw ReconcileError.notFound }
        let snapshot = try captureSnapshot([sourceGameID, targetGameID], db)

        // --- Game details: played = either; keep the target's scalar when set, else the
        // source's; carry the source's tier/rank only when the target is unranked.
        target.played = target.played || source.played
        target.status = target.status ?? source.status
        target.myPlaytimeS = target.myPlaytimeS ?? source.myPlaytimeS
        target.psnPlaytimeS = target.psnPlaytimeS ?? source.psnPlaytimeS
        target.year = target.year ?? source.year
        target.releaseDate = target.releaseDate ?? source.releaseDate
        target.summary = target.summary ?? source.summary
        target.ttbHastilyS = target.ttbHastilyS ?? source.ttbHastilyS
        target.ttbNormallyS = target.ttbNormallyS ?? source.ttbNormallyS
        target.ttbCompletelyS = target.ttbCompletelyS ?? source.ttbCompletelyS
        target.ttbSource = target.ttbSource ?? source.ttbSource
        target.hltbID = target.hltbID ?? source.hltbID
        if target.coverFile == nil, source.coverFile != nil {
            target.coverFile = source.coverFile
            target.igdbCoverImageID = target.igdbCoverImageID ?? source.igdbCoverImageID
        }
        if target.tierID == nil, let sourceTier = source.tierID {
            target.tierID = sourceTier          // played is already 1 (invariant 2 holds)
            target.rankKey = source.rankKey
        }
        // user_edited: protect any field either game had hand-edited.
        var edited = UserEditedFields(raw: target.userEdited)
        for field in UserEditedFields.Field.allCases where UserEditedFields(raw: source.userEdited).contains(field) {
            edited = edited.inserting(field)
        }
        target.userEdited = edited.raw
        target.updatedAt = Date()
        try target.update(db)

        // --- game_platforms union (OR-ing played).
        for gp in try GamePlatformRecord.filter(Column("game_id") == sourceGameID).fetchAll(db) {
            try ensureGamePlatform(gameID: targetGameID, platformID: gp.platformID, played: gp.played, db: db)
        }
        // --- genres / traits: re-point (conflicts ignored; leftovers cascade on delete).
        try db.execute(sql: "UPDATE OR IGNORE game_genres SET game_id = ? WHERE game_id = ?",
                       arguments: [targetGameID, sourceGameID])
        try db.execute(sql: "UPDATE OR IGNORE game_traits SET game_id = ? WHERE game_id = ?",
                       arguments: [targetGameID, sourceGameID])
        // --- duel history: re-point both sides, drop any self-comparison it creates.
        try db.execute(sql: "UPDATE comparisons SET winner_id = ? WHERE winner_id = ?",
                       arguments: [targetGameID, sourceGameID])
        try db.execute(sql: "UPDATE comparisons SET loser_id = ? WHERE loser_id = ?",
                       arguments: [targetGameID, sourceGameID])
        try db.execute(sql: "DELETE FROM comparisons WHERE winner_id = loser_id")
        // --- recommendation feedback + importer links.
        try db.execute(sql: "UPDATE rec_feedback SET game_id = ? WHERE game_id = ?",
                       arguments: [targetGameID, sourceGameID])
        try db.execute(sql: "UPDATE import_titles SET matched_game_id = ? WHERE matched_game_id = ?",
                       arguments: [targetGameID, sourceGameID])
        // --- enrichment jobs (target may already have same-kind rows → ignore).
        try db.execute(sql: "UPDATE OR IGNORE enrichment_jobs SET game_id = ? WHERE game_id = ?",
                       arguments: [targetGameID, sourceGameID])

        // --- copies, per decision.
        let byProduct = Dictionary(decisions.map { ($0.sourceProductID, $0) }, uniquingKeysWith: { a, _ in a })
        let sourceProductIDs = try Int64.fetchAll(
            db, sql: "SELECT product_id FROM product_games WHERE game_id = ?", arguments: [sourceGameID])
        for pid in sourceProductIDs {
            let outcome = byProduct[pid]?.effectiveOutcome ?? .keep     // unknown copy → keep (safe)
            switch outcome {
            case .keep:
                try db.execute(sql: """
                    UPDATE OR IGNORE product_games SET game_id = ? WHERE product_id = ? AND game_id = ?
                    """, arguments: [targetGameID, pid, sourceGameID])
            case .collapse(let into, _):
                try collapseCopy(survivorID: into, droppedID: pid, db: db)
            }
        }

        // --- delete the emptied source game (its memberships are re-pointed/collapsed).
        try deleteGameRow(sourceGameID, db)
        return ReconcileUndo(actionName: "Merge Games", gameIDs: [sourceGameID, targetGameID], snapshot: snapshot)
    }

    /// Collapse the dropped copy into the surviving one: enrich the survivor with what
    /// the dropped copy knows and it lacks (keeping the earliest acquired date), delete
    /// the dropped product, then preserve the dropped `(source, external_id)` identity
    /// when the survivor has none — so a re-import still recognises it (idempotency).
    private static func collapseCopy(survivorID: Int64, droppedID: Int64, db: Database) throws {
        // Raw SQL: `external_id` (v5) and any later column are not on ``ProductRecord``.
        guard let dropped = try Row.fetchOne(db, sql: """
            SELECT edition, region, psn_entitlement, acquired_at, source, external_id
            FROM products WHERE id = ?
            """, arguments: [droppedID]) else { return }
        let dEdition: String? = dropped["edition"]
        let dRegion: String? = dropped["region"]
        let dEntitlement: String? = dropped["psn_entitlement"]
        let dAcquired: Date? = dropped["acquired_at"]
        let dSource: String = dropped["source"]
        let dExternal: String? = dropped["external_id"]
        // Delete the dropped product FIRST so adopting its `(source, external_id)` below
        // can never clash with the partial UNIQUE(source, external_id) index.
        try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [droppedID])

        guard let survivor = try Row.fetchOne(db, sql: """
            SELECT edition, region, psn_entitlement, acquired_at, external_id FROM products WHERE id = ?
            """, arguments: [survivorID]) else { return }
        let edition = (survivor["edition"] as String?) ?? dEdition
        let region = (survivor["region"] as String?) ?? dRegion
        let entitlement = (survivor["psn_entitlement"] as String?) ?? dEntitlement
        let acquired = earliest(survivor["acquired_at"], dAcquired)

        if (survivor["external_id"] as String?) == nil, let ext = dExternal {
            // Preserve the dropped copy's importer identity so a re-import recognises it.
            try db.execute(sql: """
                UPDATE products SET edition = ?, region = ?, psn_entitlement = ?, acquired_at = ?,
                       source = ?, external_id = ?, updated_at = ? WHERE id = ?
                """, arguments: [edition, region, entitlement, acquired, dSource, ext, Date(), survivorID])
        } else {
            try db.execute(sql: """
                UPDATE products SET edition = ?, region = ?, psn_entitlement = ?, acquired_at = ?,
                       updated_at = ? WHERE id = ?
                """, arguments: [edition, region, entitlement, acquired, Date(), survivorID])
        }
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    // MARK: - Title adopt

    /// Adopt the IGDB title (unless the owner hand-edited the title), pushing the old
    /// title into `alt_titles` so search still finds it.
    static func applyTitleAdopt(_ g: inout GameRecord, igdbTitle: String?, edited: UserEditedFields) {
        guard !edited.contains(.title) else { return }
        let newTitle = igdbTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newTitle.isEmpty, newTitle.caseInsensitiveCompare(g.title) != .orderedSame else { return }
        var alts = g.altTitles.split(separator: "\n").map(String.init)
        if !alts.contains(where: { $0.caseInsensitiveCompare(g.title) == .orderedSame }) {
            alts.append(g.title)
        }
        g.altTitles = alts.joined(separator: "\n")
        g.title = newTitle
        g.sortTitle = SortTitle.make(from: newTitle)
    }

    // MARK: - Copy reads / detail lines

    static func copies(of gameID: Int64, _ db: Database) throws -> [ReconcileCopy] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.id AS id, p.platform_id AS platform_id, p.format AS format, p.source AS source,
                   p.external_id AS external_id, p.edition AS edition, p.region AS region,
                   p.acquired_at AS acquired_at, p.psn_entitlement AS psn_entitlement,
                   (SELECT COUNT(*) FROM product_games pg2 WHERE pg2.product_id = p.id) AS member_count
            FROM products p JOIN product_games pg ON pg.product_id = p.id
            WHERE pg.game_id = ?
            ORDER BY p.id
            """, arguments: [gameID])
        return rows.map { row in
            let members: Int = row["member_count"]
            return ReconcileCopy(
                productID: row["id"], platformID: row["platform_id"],
                format: ProductFormat(rawValue: row["format"]) ?? .physical,
                source: ProductSource(rawValue: row["source"]) ?? .manual,
                externalID: row["external_id"], edition: row["edition"], region: row["region"],
                acquiredAt: row["acquired_at"], psnEntitlement: row["psn_entitlement"],
                isCompilation: members > 1)
        }
    }

    private static func detailOutcomeLines(
        source: GameRecord, target: GameRecord, _ db: Database
    ) -> (lines: [String], bothRanked: Bool) {
        var lines: [String] = []
        if target.played || source.played { lines.append("Played") }
        let status = target.status ?? source.status
        if let status, let s = PlayStatus(rawValue: status) { lines.append("Status: \(s.label)") }
        if (target.myPlaytimeS ?? source.myPlaytimeS) != nil { lines.append("Playtime kept") }
        let bothRanked = target.tierID != nil && source.tierID != nil
        if target.tierID != nil {
            lines.append(bothRanked ? "Tier & rank: kept \u{201C}\(target.title)\u{201D}'s (both were ranked)"
                                    : "Tier & rank kept")
        } else if source.tierID != nil {
            lines.append("Tier & rank carried over")
        }
        return (lines, bothRanked)
    }

    // MARK: - Snapshot / restore (undo)

    static func captureSnapshot(_ gameIDs: [Int64], _ db: Database) throws -> ReconcileSnapshot {
        let idList = gameIDs.map(String.init).joined(separator: ",")
        let productIDs = try Int64.fetchAll(
            db, sql: "SELECT DISTINCT product_id FROM product_games WHERE game_id IN (\(idList))")
        let productList = productIDs.map(String.init).joined(separator: ",")

        let games = try GameRecord.filter(keys: gameIDs).fetchAll(db)
        let products: [ReconcileProductRow] = productIDs.isEmpty ? []
            : try Row.fetchAll(db, sql: "SELECT * FROM products WHERE id IN (\(productList))").map { row in
                var dict: [String: DatabaseValue] = [:]
                for (col, value) in row { dict[col] = value }
                return ReconcileProductRow(columns: dict)
            }
        let productGames = productIDs.isEmpty ? []
            : try ProductGameRecord.fetchAll(db, sql: "SELECT * FROM product_games WHERE product_id IN (\(productList))")
        let platforms = try GamePlatformRecord.fetchAll(db, sql: "SELECT * FROM game_platforms WHERE game_id IN (\(idList))")
        let genres = try GameGenreRecord.fetchAll(db, sql: "SELECT * FROM game_genres WHERE game_id IN (\(idList))")
        let traits = try ReconcileTraitRow.fetchAll(db, sql: "SELECT * FROM game_traits WHERE game_id IN (\(idList))")
        let comparisons = try ComparisonRecord.fetchAll(
            db, sql: "SELECT * FROM comparisons WHERE winner_id IN (\(idList)) OR loser_id IN (\(idList))")
        let feedback = try ReconcileFeedbackRow.fetchAll(db, sql: "SELECT * FROM rec_feedback WHERE game_id IN (\(idList))")
        let importTitles = try ImportTitleRecord.fetchAll(db, sql: "SELECT * FROM import_titles WHERE matched_game_id IN (\(idList))")
        let jobs = try EnrichmentJobRecord.fetchAll(db, sql: "SELECT * FROM enrichment_jobs WHERE game_id IN (\(idList))")

        return ReconcileSnapshot(
            games: games, products: products, productGames: productGames, platforms: platforms,
            genres: genres, traits: traits, comparisons: comparisons, feedback: feedback,
            importTitles: importTitles, jobs: jobs)
    }

    static func applySnapshot(_ snap: ReconcileSnapshot, gameIDs: [Int64], _ db: Database) throws {
        let idList = gameIDs.map(String.init).joined(separator: ",")

        // Products fully owned by the snapshotted games (safe to delete + re-create);
        // shared products keep their row and only have this game's membership restored.
        let membersByProduct = Dictionary(grouping: snap.productGames, by: \.productID)
        let gameIDSet = Set(gameIDs)
        var exclusiveProductIDs: [Int64] = []
        var sharedProductIDs: [Int64] = []
        for product in snap.products {
            guard let pid = product.id else { continue }
            let members = membersByProduct[pid] ?? []
            if members.allSatisfy({ gameIDSet.contains($0.gameID) }) { exclusiveProductIDs.append(pid) }
            else { sharedProductIDs.append(pid) }
        }

        // 1. Tear down the current (post-op) rows for these games.
        try db.execute(sql: "DELETE FROM comparisons WHERE winner_id IN (\(idList)) OR loser_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM rec_feedback WHERE game_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM enrichment_jobs WHERE game_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM game_platforms WHERE game_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM game_genres WHERE game_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM game_traits WHERE game_id IN (\(idList))")
        try db.execute(sql: "DELETE FROM product_games WHERE game_id IN (\(idList))")
        for pid in exclusiveProductIDs {
            try db.execute(sql: "DELETE FROM products WHERE id = ?", arguments: [pid])
        }
        // Also clear this game's membership from shared products before re-inserting it.
        for pid in sharedProductIDs {
            try db.execute(sql: "DELETE FROM product_games WHERE product_id = ? AND game_id IN (\(idList))",
                           arguments: [pid])
        }
        try db.execute(sql: "DELETE FROM games WHERE id IN (\(idList))")   // import_titles → NULL

        // 2. Re-create games first (FK parents).
        for game in snap.games { var g = game; try g.insert(db) }

        // 3. Products: exclusive re-created whole; shared already exist (untouched row).
        let exclusiveSet = Set(exclusiveProductIDs)
        for product in snap.products where exclusiveSet.contains(product.id ?? -1) {
            let cols = Array(product.columns.keys)
            let placeholders = cols.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "INSERT INTO products (\(cols.joined(separator: ", "))) VALUES (\(placeholders))",
                arguments: StatementArguments(cols.map { product.columns[$0] ?? .null }))
        }
        for pg in snap.productGames {
            // Skip a membership whose product is shared but the member is outside our
            // games (that row was never removed).
            if exclusiveSet.contains(pg.productID) || gameIDSet.contains(pg.gameID) {
                try pg.insert(db)
            }
        }

        // 4. Joins + history.
        for row in snap.platforms { try row.insert(db) }
        for row in snap.genres { try row.insert(db) }
        for row in snap.traits { try row.insert(db) }
        for c in snap.comparisons { var r = c; try r.insert(db) }
        for f in snap.feedback { try f.insert(db) }
        for job in snap.jobs { var r = job; try r.insert(db) }

        // 5. Re-point importer links back (rows still exist; matched_game_id went NULL).
        for title in snap.importTitles {
            guard let id = title.id else { continue }
            try db.execute(sql: "UPDATE import_titles SET matched_game_id = ? WHERE id = ?",
                           arguments: [title.matchedGameID, id])
        }
    }
}

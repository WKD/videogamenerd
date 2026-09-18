import Foundation
import GRDB

/// The write/read API for the *data side of ranking* (PLAN §7). A thin, `Sendable`
/// value over ``AppDatabase`` — the mirror image of ``LibraryStore`` for the tier
/// / duel machinery.
///
/// Every mutating operation is **one transaction** that: reads a ``RankSnapshot``
/// from SQL, calls the pure engine in `VGN/Ranking/` (which returns
/// `[RankMutation]`), applies those mutations back to SQL, and logs any duel
/// comparisons. The engine is never bypassed, so the SQL store reproduces exactly
/// the semantics that `MockRankStore` (the reference applier) is tested against.
///
/// Duel state (the resumable placement session and the undo horizon) lives in the
/// database, in the `app_state` blob under ``duelStateKey`` — see
/// `RankingStore+Duels.swift`. Observations live in `RankingStore+Reads.swift`.
struct RankingStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }
    var dbReader: any DatabaseReader { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    // MARK: - Snapshot loading

    /// Build a ``RankSnapshot`` from SQL. Includes a slice for **every** tier
    /// (empty ones too, matching `MockRankStore`), so `slice(for:)` is always
    /// defined for a valid tier id.
    ///
    /// - placed games: `rank_key IS NOT NULL`, ordered by `rank_key` ascending.
    /// - unplaced games: `rank_key IS NULL`, in a deterministic, stable order —
    ///   `updated_at` then `id`. This is the duel queue order for a tier: a game
    ///   re-queued (its key cleared, or its tier changed) gets a fresh
    ///   `updated_at` and so drops to the back of its tier's queue.
    static func loadSnapshot(_ db: Database) throws -> RankSnapshot {
        var sortByTier: [Int64: Int] = [:]
        var tierOrder: [Int64] = []
        for row in try Row.fetchAll(db, sql: "SELECT id, sort FROM tiers ORDER BY sort, id") {
            let id: Int64 = row["id"]
            sortByTier[id] = row["sort"]
            tierOrder.append(id)
        }

        var placed: [Int64: [RankedItem]] = [:]
        var unplaced: [Int64: [GameID]] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, tier_id, rank_key FROM games
            WHERE played = 1 AND tier_id IS NOT NULL
            ORDER BY tier_id, (rank_key IS NULL), rank_key, updated_at, id
            """)
        for row in rows {
            let tier: Int64 = row["tier_id"]
            if let key = row["rank_key"] as RankKey? {
                placed[tier, default: []].append(RankedItem(id: row["id"], key: key))
            } else {
                unplaced[tier, default: []].append(row["id"])
            }
        }

        let slices = tierOrder.map { tier in
            TierSlice(tier: tier, sort: sortByTier[tier] ?? 0,
                      placed: placed[tier] ?? [], unplaced: unplaced[tier] ?? [])
        }
        return RankSnapshot(tiers: slices)
    }

    /// The full comparison log as engine values (PLAN §7), oldest first. A stored
    /// `context` of `refine` covers both within-tier refine duels and border
    /// duels (PLAN §4 defines the column as `placement | refine`; the engine's
    /// `.border` context is only meaningful in memory, so it is persisted as
    /// `refine` and read back as `.refine`).
    static func loadLog(_ db: Database) throws -> [Comparison] {
        try Row.fetchAll(db, sql: """
            SELECT winner_id, loser_id, context, created_at
            FROM comparisons ORDER BY created_at, id
            """).map { row in
            let date = (row["created_at"] as Date).timeIntervalSince1970
            let context = Comparison.Context(rawValue: row["context"]) ?? .refine
            return Comparison(winner: row["winner_id"], loser: row["loser_id"],
                              date: date, context: context)
        }
    }

    // MARK: - Mutation applier (faithful SQL image of MockRankStore.apply)

    /// Apply a batch of engine ``RankMutation``s to SQL. Never violates the v1
    /// CHECK constraints mid-statement (a key is only ever written to a row that
    /// still carries a tier). There is deliberately **no** unique index on
    /// `(tier_id, rank_key)`, so a `renumber` can rewrite a tier's keys one row
    /// at a time without a transient-uniqueness conflict.
    static func applyMutations(_ mutations: [RankMutation], _ db: Database) throws {
        let now = Date()
        for mutation in mutations {
            switch mutation {
            case let .setKey(id, key):
                try db.execute(sql: """
                    UPDATE games SET rank_key = ?, updated_at = ?
                    WHERE id = ? AND tier_id IS NOT NULL
                    """, arguments: [key, now, id])

            case let .clearKey(id):
                try db.execute(sql: "UPDATE games SET rank_key = NULL, updated_at = ? WHERE id = ?",
                               arguments: [now, id])

            case let .setTier(id, tier, key):
                if let tier {
                    try db.execute(sql: "UPDATE games SET tier_id = ?, rank_key = ?, updated_at = ? WHERE id = ?",
                                   arguments: [tier, key, now, id])
                } else {
                    try db.execute(sql: "UPDATE games SET tier_id = NULL, rank_key = NULL, updated_at = ? WHERE id = ?",
                                   arguments: [now, id])
                }

            case let .renumber(_, items):
                // Items all already carry `tier`; rewrite their keys. The guard
                // keeps the CHECK safe even if a row lost its tier concurrently.
                for item in items {
                    try db.execute(sql: """
                        UPDATE games SET rank_key = ?, updated_at = ?
                        WHERE id = ? AND tier_id IS NOT NULL
                        """, arguments: [item.key, now, item.id])
                }
            }
        }
    }

    // MARK: - Tier operations (usable from anywhere in the UI)

    /// Set (or clear, with `nil`) the tier for many games — the multi-selection
    /// `S`…`F` / `0` path (PLAN §7). Consistent with the old `LibraryStore.setTier`
    /// but with two ranking-correct refinements:
    ///
    /// - **unplayed games are skipped and reported** (invariant 2);
    /// - **setting the tier a game already has is a no-op** — it keeps its
    ///   fine-rank key instead of dropping the game back to the unplaced tail.
    ///   Only an actual tier *change* clears the key (PLAN §7).
    ///
    /// `LibraryStore.setTier` delegates here, so both entry points behave alike.
    static func applySetTier(_ gameIDs: [Int64], tierID: Int64?, _ db: Database) throws -> SetTierOutcome {
        var applied: [Int64] = []
        var skipped: [Int64] = []
        let now = Date()
        for id in gameIDs {
            if let tierID {
                guard try LibraryStore.isPlayed(id, db) else { skipped.append(id); continue }
                let current = try Int64.fetchOne(db, sql: "SELECT tier_id FROM games WHERE id = ?", arguments: [id])
                if current == tierID { applied.append(id); continue } // no-op, keep key
                try db.execute(sql: "UPDATE games SET tier_id = ?, rank_key = NULL, updated_at = ? WHERE id = ?",
                               arguments: [tierID, now, id])
            } else {
                try db.execute(sql: "UPDATE games SET tier_id = NULL, rank_key = NULL, updated_at = ? WHERE id = ?",
                               arguments: [now, id])
            }
            applied.append(id)
        }
        return SetTierOutcome(applied: applied, skippedUnplayed: skipped)
    }

    /// Multi-selection tier set (one transaction). See ``applySetTier(_:tierID:_:)``.
    @discardableResult
    func setTier(_ gameIDs: [Int64], tierID: Int64?) async throws -> SetTierOutcome {
        try await dbWriter.write { db in try Self.applySetTier(gameIDs, tierID: tierID, db) }
    }

    /// Clear a single game's tier entirely (no tier, no rank). Undoable in the
    /// ranking views (⌘Z).
    func clearTier(_ gameID: Int64) async throws {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            try Self.applyStructural(RankMoves.clearTier(gameID), comparisonIDs: [], kind: "clearTier",
                                     &state, db)
            try Self.saveDuelState(state, db)
        }
    }

    /// "Re-place" a game (PLAN §7): keep its tier, drop its fine-rank key, re-queue
    /// it for duels. Undoable in the ranking views (⌘Z).
    func rePlace(_ gameID: Int64) async throws {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            try Self.applyStructural(RankMoves.rePlace(gameID), comparisonIDs: [], kind: "rePlace",
                                     &state, db)
            try Self.saveDuelState(state, db)
        }
    }

    // MARK: - Drag / drop overrides

    /// Move a game to `toTier` at an exact position (Tier Board + The Top drag).
    ///
    /// - `atIndex == nil` drops it into the **unplaced tail** of `toTier`
    ///   (= `setTierUnplaced`): tier set, key cleared, re-queued for duels.
    /// - `atIndex != nil` inserts it at that slot among the *other* placed games
    ///   of `toTier` (0 = top). Works within a tier (reorder) and across tiers,
    ///   renumbering the target tier when integer gaps run out.
    ///
    /// Undoable in the ranking views (⌘Z).
    func move(gameID: Int64, toTier: Int64, atIndex: Int?) async throws {
        try await dbWriter.write { db in
            let snapshot = try Self.loadSnapshot(db)
            guard let slice = snapshot.slice(for: toTier) else { throw LibraryError.notFound }
            let mutations: [RankMutation]
            if let atIndex {
                mutations = RankMoves.moveAcrossTiers(gameID, into: slice, insertIndex: atIndex)
            } else {
                mutations = RankMoves.setTierUnplaced(gameID, tier: toTier)
            }
            var state = try Self.loadDuelState(db)
            try Self.applyStructural(mutations, comparisonIDs: [], kind: "move", &state, db)
            try Self.saveDuelState(state, db)
        }
    }

    /// Apply several drag/drop moves as **one transaction and one undo step**
    /// (PLAN §7 — a multi-select drop onto the Tier Board). Moves are resolved
    /// **in order** against the evolving board (so `move(F[i], toTier, i)` settles a
    /// block left-to-right), exactly as N separate ``move(gameID:toTier:atIndex:)``
    /// calls would — but ⌘Z reverses the whole batch at once. Prior `(tier, key)`
    /// state is captured lazily, before each id is first touched, so the single
    /// history entry restores the pre-batch state faithfully even when a move
    /// renumbers a tier.
    func move(_ moves: [(gameID: Int64, toTier: Int64, atIndex: Int?)]) async throws {
        guard !moves.isEmpty else { return }
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            var priorByID: [Int64: GameRankState] = [:]
            for move in moves {
                let snapshot = try Self.loadSnapshot(db)
                guard let slice = snapshot.slice(for: move.toTier) else { continue }
                let mutations: [RankMutation]
                if let atIndex = move.atIndex {
                    mutations = RankMoves.moveAcrossTiers(move.gameID, into: slice, insertIndex: atIndex)
                } else {
                    mutations = RankMoves.setTierUnplaced(move.gameID, tier: move.toTier)
                }
                for id in Self.touchedIDs(mutations) where priorByID[id] == nil {
                    if let captured = try Self.captureStates([id], db).first { priorByID[id] = captured }
                }
                try Self.applyMutations(mutations, db)
            }
            Self.pushHistory(
                CompletedAction(priorStates: Array(priorByID.values), comparisonIDs: [], kind: "batchMove"),
                &state)
            try Self.saveDuelState(state, db)
        }
    }

    // MARK: - Integrity

    /// Run `Consistency.checkInvariants` over the loaded snapshot (PLAN §7). Empty
    /// = healthy. Cheap enough to assert in DEBUG after a batch of operations.
    func verifyInvariants() async throws -> [Consistency.Violation] {
        try await dbReader.read { db in Consistency.checkInvariants(try Self.loadSnapshot(db)) }
    }

    /// Preference cycles (A>B>C>A) in the comparison log — the "disputes to settle"
    /// (PLAN §7), via `Consistency.detectContradictions`.
    func contradictions() async throws -> [Consistency.Dispute] {
        try await dbReader.read { db in Consistency.detectContradictions(try Self.loadLog(db)) }
    }

    // MARK: - Shared low-level helpers

    /// Capture the current `(tier, key)` of each id, so an operation can be undone
    /// by restoring them (see `RankingStore+Duels.swift`).
    static func captureStates(_ ids: [Int64], _ db: Database) throws -> [GameRankState] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, tier_id, rank_key FROM games WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: StatementArguments(ids))
        return rows.map { GameRankState(gameID: $0["id"], tier: $0["tier_id"], key: $0["rank_key"]) }
    }

    /// Restore captured `(tier, key)` states (undo).
    static func restoreStates(_ states: [GameRankState], _ db: Database) throws {
        let now = Date()
        for state in states {
            try db.execute(sql: "UPDATE games SET tier_id = ?, rank_key = ?, updated_at = ? WHERE id = ?",
                           arguments: [state.tier, state.key, now, state.gameID])
        }
    }

    /// Insert one comparison row, returning its id. `context` is `placement` or
    /// `refine` (border duels are logged as `refine`, see ``loadLog(_:)``).
    @discardableResult
    static func insertComparison(winner: Int64, loser: Int64, context: String, _ db: Database) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO comparisons (winner_id, loser_id, context, created_at) VALUES (?, ?, ?, ?)
            """, arguments: [winner, loser, context, Date()])
        return db.lastInsertedRowID
    }

    static func deleteComparison(_ id: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM comparisons WHERE id = ?", arguments: [id])
    }

    /// The game ids a mutation batch touches (for capture/restore).
    static func touchedIDs(_ mutations: [RankMutation]) -> [Int64] {
        var ids: Set<Int64> = []
        for mutation in mutations {
            switch mutation {
            case let .setKey(id, _), let .clearKey(id): ids.insert(id)
            case let .setTier(id, _, _): ids.insert(id)
            case let .renumber(_, items): for item in items { ids.insert(item.id) }
            }
        }
        return Array(ids)
    }
}

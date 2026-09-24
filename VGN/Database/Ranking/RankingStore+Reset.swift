import Foundation
import GRDB

/// **Reset duels** (PLAN §7, owner request 2026-09-25): forget the fine-rank placements and
/// the duel log, keeping every game in its tier. An explicit, confirmed, undoable owner action
/// — never automatic (PLAN §4 inv. 5).
///
/// One transaction:
///  - clears `rank_key` on the games in scope (they stay in their tiers, now **unplaced** — The
///    Top shows tier midpoints, Duel offers to place them, the taste model reads tier bands);
///  - deletes the `comparisons` rows in scope (both `placement` and `refine`);
///  - clears the resumable duel state (`app_state` key ``RankingStore/duelStateKey``,
///    `ranking.duel` — the ONLY duel-related `app_state` key: session, per-answer log, one-step
///    undo history, dismissed borders, enqueued pairs all live in that one blob). A tier reset
///    trims that blob instead of deleting it (see ``resetDuels(_:snapshotDirectory:)``).
///
/// Untouched: tiers, played, status, holds_up, `rec_feedback`, `updated_at` (so the unplaced
/// queue order is not reshuffled and undo is exact).
extension RankingStore {

    /// What a reset covers.
    enum DuelResetScope: Hashable, Sendable {
        /// Every placement and every comparison ("Reset All Duels").
        case all
        /// One tier's placements and every comparison touching one of its games
        /// ("Reset Duels in Tier…").
        case tier(Int64)
    }

    /// The real counts a confirmation names ("Forget 126 duels and un-place 34 games?").
    struct DuelResetCounts: Hashable, Sendable {
        /// `comparisons` rows that would be deleted.
        var comparisons: Int
        /// Games that currently have a `rank_key` and would become unplaced.
        var placedGames: Int
        /// Whether a resumable duel state would be cleared (only for "all" — a tier reset
        /// trims the blob, which alone is not "something to reset").
        var hasDuelState: Bool

        var isEmpty: Bool { comparisons == 0 && placedGames == 0 && !hasDuelState }
    }

    /// One captured comparison row, restored verbatim by the undo.
    struct CapturedComparison: Hashable, Sendable, Codable {
        var id: Int64
        var winnerID: Int64
        var loserID: Int64
        var context: String
        var createdAt: String?
    }

    /// One captured placement, restored by the undo.
    struct CapturedPlacement: Hashable, Sendable, Codable {
        var gameID: Int64
        var tierID: Int64
        var rankKey: RankKey
    }

    /// Everything the "Reset All Duels" undo step needs to restore the exact prior state.
    struct DuelResetUndo: Hashable, Sendable {
        var scope: DuelResetScope
        var placements: [CapturedPlacement]
        var comparisons: [CapturedComparison]
        /// The raw `ranking.duel` blob before the reset (nil = there was none).
        var duelStateJSON: String?
        /// The automatic pre-reset snapshot, when one was written.
        var snapshotURL: URL?
    }

    // MARK: - Counts

    /// The counts a reset of `scope` would affect — read-only.
    func duelResetCounts(_ scope: DuelResetScope) async throws -> DuelResetCounts {
        try await dbReader.read { db in try Self.fetchDuelResetCounts(scope, db) }
    }

    static func fetchDuelResetCounts(_ scope: DuelResetScope, _ db: Database) throws -> DuelResetCounts {
        switch scope {
        case .all:
            let hasState = try AppStateRecord.fetchOne(db, key: duelStateKey) != nil
            return DuelResetCounts(
                comparisons: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comparisons") ?? 0,
                placedGames: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE rank_key IS NOT NULL") ?? 0,
                hasDuelState: hasState)
        case .tier(let tierID):
            return DuelResetCounts(
                comparisons: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM comparisons c
                    WHERE c.winner_id IN (SELECT id FROM games WHERE tier_id = ?)
                       OR c.loser_id  IN (SELECT id FROM games WHERE tier_id = ?)
                    """, arguments: [tierID, tierID]) ?? 0,
                placedGames: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM games WHERE tier_id = ? AND rank_key IS NOT NULL
                    """, arguments: [tierID]) ?? 0,
                // A tier reset only trims the duel-state blob; it alone is nothing to reset.
                hasDuelState: false)
        }
    }

    // MARK: - Reset

    /// Reset duels in `scope` — see the type comment. When `snapshotDirectory` is given, a
    /// `VACUUM INTO` copy named `before-duel-reset-<stamp>.sqlite` is written there **first**
    /// (outside the transaction; a failed snapshot aborts the reset). Those files do not match
    /// the `vgn-*.sqlite` rotation pattern, so they are never rotated away. Returns the undo
    /// token (exact inverse via ``undoDuelReset(_:)``).
    func resetDuels(_ scope: DuelResetScope, snapshotDirectory: URL?) async throws -> DuelResetUndo {
        let snapshot = try snapshotDirectory.map { try Self.writeResetSnapshot(database, into: $0) }
        var undo = try await dbWriter.write { db in try Self.applyDuelReset(scope, db) }
        undo.snapshotURL = snapshot
        return undo
    }

    /// Restore a reset exactly: the captured rank keys (only onto games still in the same
    /// tier and still unplaced, and never onto a key a later placement took — a later move is
    /// never overwritten), the deleted comparison
    /// rows with their original ids (only where both games still exist), and the duel-state
    /// blob. One transaction.
    func undoDuelReset(_ undo: DuelResetUndo) async throws {
        try await dbWriter.write { db in try Self.applyDuelResetUndo(undo, db) }
    }

    static func applyDuelReset(_ scope: DuelResetScope, _ db: Database) throws -> DuelResetUndo {
        let placementSQL: String
        let comparisonWhere: String
        let args: StatementArguments
        switch scope {
        case .all:
            placementSQL = "SELECT id, tier_id, rank_key FROM games WHERE rank_key IS NOT NULL ORDER BY id"
            comparisonWhere = "1"
            args = []
        case .tier(let tierID):
            placementSQL = "SELECT id, tier_id, rank_key FROM games WHERE tier_id = \(tierID) AND rank_key IS NOT NULL ORDER BY id"
            comparisonWhere = """
                winner_id IN (SELECT id FROM games WHERE tier_id = ?)
                OR loser_id IN (SELECT id FROM games WHERE tier_id = ?)
                """
            args = [tierID, tierID]
        }

        // 1. Capture (for the exact undo).
        let placements = try Row.fetchAll(db, sql: placementSQL).map {
            CapturedPlacement(gameID: $0["id"], tierID: $0["tier_id"], rankKey: $0["rank_key"])
        }
        let comparisons = try Row.fetchAll(db, sql: """
            SELECT id, winner_id, loser_id, context, CAST(created_at AS TEXT) AS created_at
            FROM comparisons WHERE \(comparisonWhere) ORDER BY id
            """, arguments: args).map {
            CapturedComparison(id: $0["id"], winnerID: $0["winner_id"], loserID: $0["loser_id"],
                               context: $0["context"], createdAt: $0["created_at"])
        }
        let stateJSON = try AppStateRecord.fetchOne(db, key: duelStateKey)?.json

        // 2. Un-place (tier kept; updated_at untouched so the queue order is stable).
        for p in placements {
            try db.execute(sql: "UPDATE games SET rank_key = NULL WHERE id = ?", arguments: [p.gameID])
        }
        // 3. Forget the duels.
        try db.execute(sql: "DELETE FROM comparisons WHERE \(comparisonWhere)", arguments: args)
        // 4. The resumable duel state.
        switch scope {
        case .all:
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [duelStateKey])
        case .tier(let tierID):
            if stateJSON != nil {
                let tierGames = Set(try Int64.fetchAll(db, sql: "SELECT id FROM games WHERE tier_id = ?",
                                                       arguments: [tierID]))
                var state = try loadDuelState(db)
                // A session placing a game of this tier is dropped; the one-step undo history is
                // cleared (its entries may reference keys/comparisons that no longer exist); pairs
                // and dismissed borders touching the tier go too. Everything else is kept.
                if let session = state.session, tierGames.contains(session.gameID) {
                    state.session = nil
                    state.sessionLog = []
                    state.completionPriorStates = nil
                }
                state.history = []
                state.enqueuedPairs.removeAll { tierGames.contains($0.a) || tierGames.contains($0.b) }
                state.dismissedBorders.removeAll { tierGames.contains($0.a) || tierGames.contains($0.b) }
                try saveDuelState(state, db)
            }
        }
        return DuelResetUndo(scope: scope, placements: placements, comparisons: comparisons,
                             duelStateJSON: stateJSON, snapshotURL: nil)
    }

    static func applyDuelResetUndo(_ undo: DuelResetUndo, _ db: Database) throws {
        for p in undo.placements {
            // Skipped when the game moved since (other tier / placed again) or when a game
            // placed since already holds that exact key in the tier (keys stay distinct).
            try db.execute(sql: """
                UPDATE games SET rank_key = ?
                WHERE id = ? AND tier_id = ? AND rank_key IS NULL AND played = 1
                  AND NOT EXISTS (SELECT 1 FROM games o WHERE o.tier_id = ? AND o.rank_key = ?)
                """, arguments: [p.rankKey, p.gameID, p.tierID, p.tierID, p.rankKey])
        }
        for c in undo.comparisons {
            try db.execute(sql: """
                INSERT OR IGNORE INTO comparisons (id, winner_id, loser_id, context, created_at)
                SELECT ?, ?, ?, ?, COALESCE(?, CURRENT_TIMESTAMP)
                WHERE EXISTS (SELECT 1 FROM games WHERE id = ?) AND EXISTS (SELECT 1 FROM games WHERE id = ?)
                """, arguments: [c.id, c.winnerID, c.loserID, c.context, c.createdAt, c.winnerID, c.loserID])
        }
        if let json = undo.duelStateJSON {
            try AppStateRecord(key: duelStateKey, json: json, updatedAt: Date()).save(db)
        } else {
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [duelStateKey])
        }
    }

    // MARK: - Snapshot

    /// `before-duel-reset-<stamp>.sqlite` via `VACUUM INTO` (consistent, WAL-safe).
    static func writeResetSnapshot(_ database: AppDatabase, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = AppDatabase.timestampFormatter.string(from: Date())
        var url = directory.appendingPathComponent("\(resetSnapshotPrefix)\(stamp).sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(resetSnapshotPrefix)\(stamp)-\(UUID().uuidString.prefix(6)).sqlite")
        }
        try database.dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        return url
    }

    static let resetSnapshotPrefix = "before-duel-reset-"
}

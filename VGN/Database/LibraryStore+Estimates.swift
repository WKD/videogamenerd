import Foundation
import GRDB

/// Suspicious-estimate support (PLAN §5.3, owner request 2026-09-20): the persisted
/// "Estimate Looks Right" dismissals, the "replace from HowLongToBeat" write, and the
/// list of currently-flagged games. The dismissals live in `app_state` as a JSON id
/// array, exactly like `reconcile.notBundle` — no schema change.
extension LibraryStore {

    /// `app_state` key holding the JSON array of game ids the owner marked **"Estimate
    /// Looks Right"** — games whose suspicious-looking times are actually correct, so they
    /// leave the Suspicious-Estimate filter and their raw completionist is used again for
    /// planning (PLAN §5.3). Read by ``LibraryQuery`` (SQL) and by the inspector.
    static let estimateLooksRightStateKey = "estimate.looksRight"

    /// The dismissed ("looks right") game ids.
    func dismissedEstimateIDs() async throws -> Set<Int64> {
        try await dbReader.read(Self.readDismissedEstimateIDs)
    }

    static func readDismissedEstimateIDs(_ db: Database) throws -> Set<Int64> {
        guard let json = try String.fetchOne(
                db, sql: "SELECT json FROM app_state WHERE key = ?", arguments: [estimateLooksRightStateKey]),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Mark a game's estimate as "looks right" (`dismissed = true`) or flag it again
    /// (`dismissed = false`) — the inspector toggle (PLAN §5.3). Idempotent; one
    /// transaction. Writing `app_state` re-runs every observation that reads it (the
    /// grid's Suspicious facet, the length shelves, Stats).
    func setEstimateLooksRight(gameID: Int64, dismissed: Bool) async throws {
        try await dbWriter.write { db in
            var ids = try Self.readDismissedEstimateIDs(db)
            if dismissed { ids.insert(gameID) } else { ids.remove(gameID) }
            let json = (try? JSONEncoder().encode(ids.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try db.execute(sql: """
                INSERT INTO app_state (key, json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
                """, arguments: [Self.estimateLooksRightStateKey, json, Date()])
        }
    }

    /// The ids of every game currently flagged by the suspicious-estimate rule
    /// (``EstimateSanity``), ordered by sort title for a stable bulk run — the default
    /// scope of "Refresh Time Estimates from HowLongToBeat…" when nothing is selected
    /// (PLAN §5.3, "typically the filtered suspicious ones").
    func suspiciousEstimateGameIDs() async throws -> [Int64] {
        try await dbReader.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM games g
                WHERE \(LibraryQuery.suspiciousEstimatePredicate())
                ORDER BY sort_title, id
                """)
        }
    }

    /// **Replace** a game's time-to-beat estimates from a HowLongToBeat candidate
    /// (PLAN §5.3 — the bulk "Refresh Time Estimates from HowLongToBeat…"): unlike the
    /// gap-filling ``applyHLTBTimes(gameID:candidate:)``, this overwrites all three
    /// `ttb_*_s` columns with HLTB's values, stamps `ttb_source = 'hltb'` and stores the
    /// HLTB id — so the game becomes the reference and leaves the Suspicious filter. When
    /// HLTB has **no** usable time for the game (`hasAnyTime == false`) nothing is written
    /// (the game stays flagged; the owner can dismiss it). The owner's own **playtime**
    /// (`my_playtime_s` / `psn_playtime_s`) is a different set of columns and is never
    /// touched. Returns the previous values so the caller can offer one batch Undo.
    @discardableResult
    func replaceHLTBTimes(gameID: Int64, candidate: HLTBCandidate) async throws -> HLTBFillResult {
        try await dbWriter.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source, hltb_id
                FROM games WHERE id = ?
                """, arguments: [gameID]) else { throw LibraryError.notFound }

            let prev = HLTBTimeSnapshot(
                hastily: row["ttb_hastily_s"], normally: row["ttb_normally_s"],
                completely: row["ttb_completely_s"], source: row["ttb_source"],
                hltbID: row["hltb_id"])
            var result = HLTBFillResult(gameID: gameID, previous: prev)

            // HLTB doesn't really know this game → leave it untouched (and flagged).
            guard candidate.hasAnyTime else { return result }

            try db.execute(sql: """
                UPDATE games
                   SET ttb_hastily_s = ?, ttb_normally_s = ?, ttb_completely_s = ?,
                       ttb_source = ?, hltb_id = ?, updated_at = ?
                 WHERE id = ?
                """, arguments: [candidate.mainSeconds, candidate.mainExtraSeconds,
                                 candidate.completionistSeconds, HLTBSource.id,
                                 candidate.id, Date(), gameID])
            result.wroteHastily = true
            result.wroteNormally = true
            result.wroteCompletely = true
            result.setSource = true
            result.setHLTBID = true
            return result
        }
    }

    /// Restore several games' time-to-beat columns in one transaction — the inverse of a
    /// batch "Refresh from HowLongToBeat" for **one** Undo step (PLAN §5.3, D4).
    /// Headless-safe (no `UndoManager.undo()` needed to exercise it).
    func restoreTimeToBeatBatch(_ snapshots: [Int64: HLTBTimeSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        try await dbWriter.write { db in
            for (gameID, snapshot) in snapshots {
                try db.execute(sql: """
                    UPDATE games
                       SET ttb_hastily_s = ?, ttb_normally_s = ?, ttb_completely_s = ?,
                           ttb_source = ?, hltb_id = ?, updated_at = ?
                     WHERE id = ?
                    """, arguments: [snapshot.hastily, snapshot.normally, snapshot.completely,
                                     snapshot.source, snapshot.hltbID, Date(), gameID])
            }
        }
    }
}

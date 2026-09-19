import Foundation
import GRDB

/// A snapshot of a game's time-to-beat columns, for undo (PLAN §5.3 — the HLTB fill
/// is Undo-able).
struct HLTBTimeSnapshot: Sendable, Equatable {
    var hastily: Int?
    var normally: Int?
    var completely: Int?
    var source: String?
    var hltbID: Int64?
}

/// What a HLTB fill changed (PLAN §5.3). `didWrite` is false when every target field
/// was already set (or HLTB had no usable value) — nothing was written and no source
/// / id was touched.
struct HLTBFillResult: Sendable, Equatable {
    var gameID: Int64
    var wroteHastily: Bool = false
    var wroteNormally: Bool = false
    var wroteCompletely: Bool = false
    var setSource: Bool = false
    var setHLTBID: Bool = false
    /// The pre-fill column values, so the caller can offer Undo.
    var previous: HLTBTimeSnapshot = HLTBTimeSnapshot()

    var didWrite: Bool { wroteHastily || wroteNormally || wroteCompletely }
}

extension LibraryStore {

    /// Fill a game's time-to-beat gaps from a HowLongToBeat candidate (PLAN §5.3), in
    /// one transaction:
    ///  - **Only empty fields are filled** — an IGDB or hand-typed value is never
    ///    overwritten (Main → `ttb_hastily_s`, Main+Extra → `ttb_normally_s`,
    ///    Completionist → `ttb_completely_s`).
    ///  - a zero / missing HLTB value is not written.
    ///  - `ttb_source = 'hltb'` **only** when at least one value was written *and* the
    ///    game had no prior source (a game that already carried IGDB times keeps its
    ///    `igdb` label; the newly-filled field just joins it).
    ///  - the HLTB game id is persisted when at least one value was written, so
    ///    "Open on HowLongToBeat" opens the exact page.
    ///
    /// Returns what changed (with the previous values, for Undo).
    @discardableResult
    func applyHLTBTimes(gameID: Int64, candidate: HLTBCandidate) async throws -> HLTBFillResult {
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

            // Fill only-empty fields with positive HLTB values.
            if prev.hastily == nil, let v = candidate.mainSeconds, v > 0 {
                try db.execute(sql: "UPDATE games SET ttb_hastily_s = ? WHERE id = ?", arguments: [v, gameID])
                result.wroteHastily = true
            }
            if prev.normally == nil, let v = candidate.mainExtraSeconds, v > 0 {
                try db.execute(sql: "UPDATE games SET ttb_normally_s = ? WHERE id = ?", arguments: [v, gameID])
                result.wroteNormally = true
            }
            if prev.completely == nil, let v = candidate.completionistSeconds, v > 0 {
                try db.execute(sql: "UPDATE games SET ttb_completely_s = ? WHERE id = ?", arguments: [v, gameID])
                result.wroteCompletely = true
            }

            guard result.didWrite else { return result }

            // Source: only claim 'hltb' when the game had no prior source.
            if prev.source == nil {
                try db.execute(sql: "UPDATE games SET ttb_source = ? WHERE id = ?",
                               arguments: [HLTBSource.id, gameID])
                result.setSource = true
            }
            // Keep the exact HLTB page reachable.
            try db.execute(sql: "UPDATE games SET hltb_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [candidate.id, Date(), gameID])
            result.setHLTBID = true
            return result
        }
    }

    /// Restore a game's time-to-beat columns to a snapshot — the inverse of
    /// ``applyHLTBTimes(gameID:candidate:)`` for Undo (headless-safe, PLAN §5.3).
    func restoreTimeToBeat(gameID: Int64, _ snapshot: HLTBTimeSnapshot) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE games
                   SET ttb_hastily_s = ?, ttb_normally_s = ?, ttb_completely_s = ?,
                       ttb_source = ?, hltb_id = ?, updated_at = ?
                 WHERE id = ?
                """, arguments: [snapshot.hastily, snapshot.normally, snapshot.completely,
                                 snapshot.source, snapshot.hltbID, Date(), gameID])
        }
    }

    /// The ids of every game with **no time estimate at all** — all three
    /// `ttb_*_s` columns NULL (PLAN §5.3 bulk scope / §8 "No Estimate"). Ordered by
    /// sort title for a stable bulk run.
    func gameIDsWithNoTimeEstimate() async throws -> [Int64] {
        try await dbReader.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM games
                WHERE ttb_hastily_s IS NULL AND ttb_normally_s IS NULL AND ttb_completely_s IS NULL
                ORDER BY sort_title, id
                """)
        }
    }

    /// Slim per-game facts the HLTB fill flow needs (title + year for matching, the
    /// current times to decide whether a Fetch button should appear).
    func timeToBeatFacts(gameIDs: [Int64]) async throws -> [Int64: HLTBGameFacts] {
        guard !gameIDs.isEmpty else { return [:] }
        return try await dbReader.read { db in
            let placeholders = gameIDs.map { _ in "?" }.joined(separator: ",")
            var out: [Int64: HLTBGameFacts] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, title, year, ttb_hastily_s, ttb_normally_s, ttb_completely_s
                FROM games WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(gameIDs)) {
                let id: Int64 = row["id"]
                out[id] = HLTBGameFacts(
                    id: id, title: row["title"], year: row["year"],
                    hastily: row["ttb_hastily_s"], normally: row["ttb_normally_s"],
                    completely: row["ttb_completely_s"])
            }
            return out
        }
    }
}

/// A game's matching + gap facts for the HLTB fill flow (Foundation-only value).
struct HLTBGameFacts: Sendable, Equatable, Identifiable {
    var id: Int64
    var title: String
    var year: Int?
    var hastily: Int?
    var normally: Int?
    var completely: Int?

    /// A game whose every time is empty — the bulk-scope target.
    var hasNoEstimate: Bool { hastily == nil && normally == nil && completely == nil }
    /// At least one time is empty — the inspector Fetch button is shown.
    var hasAnyGap: Bool { hastily == nil || normally == nil || completely == nil }
}

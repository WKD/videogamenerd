import Foundation
import GRDB

/// What ``LibraryStore/setHoldsUp(_:for:)`` did. Setting the mark on an unplayed game is
/// **refused** (reported, never thrown): only a played game can be judged "today"
/// (PLAN §7b; the invariant-2 pattern of the tier).
struct SetHoldsUpOutcome: Sendable, Equatable {
    /// Played games whose mark was written (even when unchanged).
    var applied: [Int64]
    /// Unplayed (or unknown) games that were left untouched.
    var skippedUnplayed: [Int64]
    /// Each applied game's mark **before** the write — the exact inverse for the
    /// "Holds Up Today?" undo step (``LibraryStore/restoreHoldsUp(_:)``).
    var previous: [Int64: HoldsUp?]
}

extension LibraryStore {
    // MARK: - "Holds up today?" (PLAN §7b, v16)

    /// Set (or clear, with `nil`) the "Holds up today?" mark on played games, in **one
    /// transaction**. Unplayed games are refused and reported in
    /// ``SetHoldsUpOutcome/skippedUnplayed`` (no throw, no change to them). The previous
    /// values are captured in the same transaction so the caller's undo is exact.
    ///
    /// Never inferred, never written by any background path: this is the only writer
    /// besides ``restoreHoldsUp(_:)`` (undo) and the un-play paths, which clear it.
    @discardableResult
    func setHoldsUp(_ value: HoldsUp?, for gameIDs: [Int64]) async throws -> SetHoldsUpOutcome {
        guard !gameIDs.isEmpty else { return SetHoldsUpOutcome(applied: [], skippedUnplayed: [], previous: [:]) }
        return try await dbWriter.write { db in
            try Self.applySetHoldsUp(value, for: gameIDs, db)
        }
    }

    /// Restore a captured `[gameID: mark]` map — the inverse of ``setHoldsUp(_:for:)``, one
    /// transaction. Games that are no longer played are skipped (a mark never lands on an
    /// unplayed game, even through undo). Returns the values it replaced (for redo).
    @discardableResult
    func restoreHoldsUp(_ previous: [Int64: HoldsUp?]) async throws -> [Int64: HoldsUp?] {
        guard !previous.isEmpty else { return [:] }
        return try await dbWriter.write { db in
            var replaced: [Int64: HoldsUp?] = [:]
            for (id, value) in previous.sorted(by: { $0.key < $1.key }) {
                let outcome = try Self.applySetHoldsUp(value, for: [id], db)
                for (k, v) in outcome.previous { replaced[k] = v }
            }
            return replaced
        }
    }

    /// Core write, inside an open transaction.
    static func applySetHoldsUp(_ value: HoldsUp?, for gameIDs: [Int64], _ db: Database) throws -> SetHoldsUpOutcome {
        var applied: [Int64] = []
        var skipped: [Int64] = []
        var previous: [Int64: HoldsUp?] = [:]
        let now = Date()
        for id in gameIDs {
            guard let row = try Row.fetchOne(db, sql: "SELECT played, holds_up FROM games WHERE id = ?",
                                             arguments: [id]),
                  (row["played"] as Bool) else {
                skipped.append(id)
                continue
            }
            let prior = HoldsUp(dbValue: row["holds_up"])
            previous[id] = prior
            applied.append(id)
            guard prior != value else { continue }   // re-setting the same mark is a no-op
            try db.execute(sql: "UPDATE games SET holds_up = ?, updated_at = ? WHERE id = ?",
                           arguments: [value?.dbValue, now, id])
        }
        return SetHoldsUpOutcome(applied: applied, skippedUnplayed: skipped, previous: previous)
    }
}

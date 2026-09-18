import Foundation
import GRDB

/// The outcome of a divider move (PLAN §7 extension): the games that crossed the
/// boundary and the new placed counts on each side (for the UI's live preview).
struct DividerMoveOutcome: Sendable, Equatable {
    var movedIDs: [Int64]
    var upperPlaced: Int
    var lowerPlaced: Int
}

/// Movable tier dividers + rank-derived scores (PLAN §7 extension). Both build on
/// the same `RankSnapshot` the rest of `RankingStore` uses; scores are computed on
/// demand and never persisted.
extension RankingStore {

    // MARK: - Movable dividers

    /// Move the boundary between two adjacent tiers by `k` placed games
    /// (`k > 0` downward, `k < 0` upward — see ``TierDividerMove``). One
    /// transaction, exactly **one** undo step (`applyStructural`), invariants hold
    /// afterwards. Undoable in the ranking views (⌘Z).
    @discardableResult
    func moveDivider(between upperTierID: Int64, and lowerTierID: Int64, by k: Int) async throws -> DividerMoveOutcome {
        try await dbWriter.write { db in
            let snapshot = try Self.loadSnapshot(db)
            let moved = TierDividerMove.movedIDs(snapshot: snapshot,
                                                 upperTier: upperTierID, lowerTier: lowerTierID, by: k)
            let mutations = TierDividerMove.mutations(snapshot: snapshot,
                                                      upperTier: upperTierID, lowerTier: lowerTierID, by: k)
            if !mutations.isEmpty {
                var state = try Self.loadDuelState(db)
                try Self.applyStructural(mutations, comparisonIDs: [], kind: "moveDivider", &state, db)
                try Self.saveDuelState(state, db)
            }
            let after = try Self.loadSnapshot(db)
            return DividerMoveOutcome(
                movedIDs: moved,
                upperPlaced: after.slice(for: upperTierID)?.placed.count ?? 0,
                lowerPlaced: after.slice(for: lowerTierID)?.placed.count ?? 0)
        }
    }

    // MARK: - Derived scores (output only)

    /// Every tiered game's 1–10 derived score, computed from the current snapshot.
    func allDerivedScores() async throws -> [Int64: DerivedScoreValue] {
        try await dbReader.read { db in DerivedScore.scores(try Self.loadSnapshot(db)) }
    }

    /// One game's derived score (for the inspector — see the handoff for the call).
    func derivedScore(for gameID: Int64) async -> DerivedScoreValue? {
        let value = try? await dbReader.read { db in
            DerivedScore.score(for: gameID, in: try Self.loadSnapshot(db))
        }
        return value ?? nil
    }
}

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

    /// The full inspector ranking line for one game (score + overall/tier position),
    /// or `nil` when the game is not tiered (PLAN §7). One-shot.
    func scoreLine(for gameID: Int64) async -> DerivedScoreLine? {
        let value = try? await dbReader.read { db in try Self.fetchScoreLine(gameID, db) }
        return value ?? nil
    }

    /// Live ranking line — the inspector subscribes so "#4 overall" updates itself
    /// after any duel / drag / divider move (PLAN §7).
    func scoreLineObservation(for gameID: Int64) -> AsyncValueObservation<DerivedScoreLine?> {
        ValueObservation.tracking { db in try Self.fetchScoreLine(gameID, db) }.values(in: dbReader)
    }

    static func fetchScoreLine(_ gameID: Int64, _ db: Database) throws -> DerivedScoreLine? {
        let snapshot = try loadSnapshot(db)
        guard let score = DerivedScore.score(for: gameID, in: snapshot) else { return nil }
        let letters = try Row.fetchAll(db, sql: "SELECT id, letter FROM tiers")
            .reduce(into: [Int64: String]()) { $0[$1["id"] as Int64] = $1["letter"] }
        let overallTotal = snapshot.orderedTiers.reduce(0) { $0 + $1.placed.count }
        var runningGlobal = 0
        for slice in snapshot.orderedTiers {
            let letter = letters[slice.tier] ?? "?"
            for (i, item) in slice.placed.enumerated() {
                runningGlobal += 1
                if item.id == gameID {
                    return DerivedScoreLine(
                        score: score, tierLetter: letter, tierPosition: i + 1,
                        tierTotalPlaced: slice.placed.count, overallPosition: runningGlobal,
                        overallTotalPlaced: overallTotal, isPlaced: true)
                }
            }
            if slice.unplaced.contains(gameID) {
                return DerivedScoreLine(
                    score: score, tierLetter: letter, tierPosition: nil,
                    tierTotalPlaced: slice.placed.count, overallPosition: nil,
                    overallTotalPlaced: overallTotal, isPlaced: false)
            }
        }
        return nil
    }
}

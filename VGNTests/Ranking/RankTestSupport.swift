import Foundation
@testable import VGN

/// Deterministic RNG (SplitMix64) for reproducible random-operation tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A tiny in-memory model of the ranking tables that applies `RankMutation`s the
/// way the DB lane will, so tests can drive the engine end to end and re-check
/// invariants. Deterministic throughout.
struct MockRankStore {
    /// tier id → sort value.
    var tierSorts: [TierID: Int]
    /// game id → (tier, key?). key == nil means unplaced. Absent means no tier.
    private var placement: [GameID: (tier: TierID, key: RankKey?)] = [:]
    /// insertion sequence for deterministic unplaced ordering.
    private var seq: [GameID: Int] = [:]
    private var nextSeq = 0

    init(tierSorts: [TierID: Int]) { self.tierSorts = tierSorts }

    mutating func add(game: GameID, tier: TierID, key: RankKey?) {
        placement[game] = (tier, key)
        if seq[game] == nil { seq[game] = nextSeq; nextSeq += 1 }
    }

    var allGames: [GameID] { placement.keys.sorted() }

    func tier(of game: GameID) -> TierID? { placement[game]?.tier }
    func key(of game: GameID) -> RankKey? { placement[game]?.key ?? nil }
    func hasTier(_ game: GameID) -> Bool { placement[game] != nil }

    func snapshot() -> RankSnapshot {
        var byTier: [TierID: (placed: [RankedItem], unplaced: [(GameID, Int)])] = [:]
        for (game, p) in placement {
            var entry = byTier[p.tier] ?? (placed: [], unplaced: [])
            if let k = p.key {
                entry.placed.append(RankedItem(id: game, key: k))
            } else {
                entry.unplaced.append((game, seq[game] ?? 0))
            }
            byTier[p.tier] = entry
        }
        var slices: [TierSlice] = []
        for (tier, sort) in tierSorts {
            let entry = byTier[tier] ?? (placed: [], unplaced: [])
            let placed = entry.placed.sorted { $0.key < $1.key }
            let unplaced = entry.unplaced.sorted { $0.1 < $1.1 }.map { $0.0 }
            slices.append(TierSlice(tier: tier, sort: sort, placed: placed, unplaced: unplaced))
        }
        slices.sort { $0.sort != $1.sort ? $0.sort < $1.sort : $0.tier < $1.tier }
        return RankSnapshot(tiers: slices)
    }

    mutating func apply(_ mutations: [RankMutation]) {
        for m in mutations {
            switch m {
            case .setKey(let id, let key):
                if let p = placement[id] { placement[id] = (p.tier, key) }
            case .clearKey(let id):
                if let p = placement[id] { placement[id] = (p.tier, nil) }
            case .setTier(let id, let tier, let key):
                if let tier {
                    placement[id] = (tier, key)
                    if seq[id] == nil { seq[id] = nextSeq; nextSeq += 1 }
                } else {
                    placement[id] = nil
                }
            case .renumber(let tier, let items):
                for item in items { placement[item.id] = (tier, item.key) }
            }
        }
    }

    /// The global order of placed game ids (tier sort, then key).
    func globalOrder() -> [GameID] {
        GlobalRank.chart(snapshot()).map(\.id)
    }
}

/// Drive a placement session with a perfect oracle: the game's true insertion
/// index is `truePosition` among `session.opponents` (which are in true order).
/// The candidate wins iff it should sort at or above the opponent's index.
func driveOracle(_ session: inout PlacementSession, truePosition p: Int) {
    while let opponent = session.nextOpponent {
        guard let m = session.opponents.firstIndex(where: { $0.id == opponent }) else { break }
        session.answer(p <= m ? .candidateWins : .opponentWins)
    }
}

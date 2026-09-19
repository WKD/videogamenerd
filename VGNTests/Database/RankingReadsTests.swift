import Foundation
import Testing
import GRDB
@testable import VGN

/// Tier Board / The Top / stats reads and observations.
@Suite struct RankingReadsTests {

    // MARK: - Tier Board

    @Test func tierBoardGroupsPlacedAndUnplaced() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a0 = try await RankTestDB.addGame(lib, title: "A0", tier: 1)
        let a1 = try await RankTestDB.addGame(lib, title: "A1", tier: 1)
        try await RankTestDB.setKey(rank, a0, 100)
        try await RankTestDB.setKey(rank, a1, 200)
        let u0 = try await RankTestDB.addGame(lib, title: "U0", tier: 1)   // unplaced tail

        let board = try await rank.tierBoardOnce()
        #expect(board.map(\.tier.letter) == ["S", "A", "B", "C", "D", "F"])
        let s = try #require(board.first)
        #expect(s.placed.map(\.id) == [a0, a1])
        #expect(s.unplaced.map(\.id) == [u0])
        #expect(board.dropFirst().allSatisfy { $0.isEmpty })
    }

    // MARK: - The Top with filters (derived vs global)

    /// Build a small ranked library across PS2 + PC and various years.
    private func buildTop(_ lib: LibraryStore, _ rank: RankingStore)
        async throws -> (g1: Int64, g2: Int64, g3: Int64, g4: Int64, g5: Int64) {
        func add(_ title: String, _ platform: String, _ year: Int, _ tier: Int64) async throws -> Int64 {
            try await lib.addGame(GameDraft(title: title, year: year, platformIDs: [platform],
                                            owned: true, tierID: tier)).gameID
        }
        let g1 = try await add("G1", "ps2", 2001, 1)
        let g2 = try await add("G2", "pc", 2010, 1)
        let g3 = try await add("G3", "ps2", 1999, 2)
        let g4 = try await add("G4", "ps2", 2005, 2)
        let g5 = try await add("G5", "ps2", 2003, 2)   // stays unplaced
        try await RankTestDB.setKey(rank, g1, 1_000)
        try await RankTestDB.setKey(rank, g2, 2_000)
        try await RankTestDB.setKey(rank, g3, 1_000)
        try await RankTestDB.setKey(rank, g4, 2_000)
        return (g1, g2, g3, g4, g5)
    }

    @Test func theTopAllHasGlobalPositions() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await buildTop(lib, rank)
        let rows = try await rank.theTopOnce(filter: LibraryFilter(scope: .all))
        let placed = rows.filter(\.isPlaced)
        #expect(placed.map(\.id) == [g.g1, g.g2, g.g3, g.g4])
        #expect(placed.map(\.globalPosition) == [1, 2, 3, 4])
        #expect(placed.map(\.derivedPosition) == [1, 2, 3, 4])
        // Unplaced g5 present, unnumbered, at the end of its tier (after g4).
        let g5row = try #require(rows.first { $0.id == g.g5 })
        #expect(g5row.globalPosition == nil && g5row.derivedPosition == nil)
        #expect(rows.map(\.id).firstIndex(of: g.g5)! > rows.map(\.id).firstIndex(of: g.g4)!)
    }

    @Test func theTopPlatformFilterRenumbersDerivedKeepsGlobal() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await buildTop(lib, rank)
        let rows = try await rank.theTopOnce(filter: LibraryFilter(platform: "ps2"))
        let placed = rows.filter(\.isPlaced)
        #expect(placed.map(\.id) == [g.g1, g.g3, g.g4])          // pc g2 excluded
        #expect(placed.map(\.derivedPosition) == [1, 2, 3])       // renumbered within PS2
        #expect(placed.map(\.globalPosition) == [1, 3, 4])        // true standing preserved
    }

    @Test func theTopPlatformAndDecadeFilter() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await buildTop(lib, rank)
        // PS2 AND 2000s: g1 (2001) and g4 (2005); g3 (1999) excluded.
        let rows = try await rank.theTopOnce(filter: LibraryFilter(decades: [2000], platform: "ps2"))
        let placed = rows.filter(\.isPlaced)
        #expect(placed.map(\.id) == [g.g1, g.g4])
        #expect(placed.map(\.derivedPosition) == [1, 2])
        #expect(placed.map(\.globalPosition) == [1, 4])
    }

    // MARK: - Duel queue count agrees with the sidebar

    @Test func duelQueueCountAgreesWithSidebar() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        _ = try await RankTestDB.addGame(lib, title: "U1", tier: 1)
        _ = try await RankTestDB.addGame(lib, title: "U2", tier: 2)
        let placed = try await RankTestDB.addGame(lib, title: "P", tier: 1)
        try await RankTestDB.setKey(rank, placed, 100)

        let count = try await rank.duelQueueCountOnce()
        let sidebar = try await lib.sidebarCountsOnce()
        #expect(count == 2)
        #expect(count == sidebar.duelQueue)
    }

    // MARK: - Stats

    @Test func rankingStatsPerTier() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        try await RankTestDB.setKey(rank, a, 100)
        _ = try await RankTestDB.addGame(lib, title: "B", tier: 1)   // unplaced
        _ = try await RankTestDB.addGame(lib, title: "C", tier: 2)   // unplaced

        let stats = try await rank.rankingStatsOnce()
        let s = try #require(stats.perTier.first { $0.letter == "S" })
        #expect(s.placed == 1 && s.unplaced == 1)
        #expect(stats.totalPlaced == 1)
        #expect(stats.totalUnplaced == 2)
    }

    // MARK: - Observation emits after a duel answer

    @Test func tierBoardObservationEmitsAfterAnswer() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let anchor = try await RankTestDB.addGame(lib, title: "A0", tier: 1)
        try await RankTestDB.setKey(rank, anchor, 1 << 30)
        let target = try await RankTestDB.addGame(lib, title: "TARGET", tier: 1)

        let queue = DispatchQueue(label: "vgn.test.rank.obs")
        let observation = ValueObservation.tracking { db in try RankingStore.fetchDuelQueueCount(db) }
        var iterator = observation
            .values(in: rank.dbReader, scheduling: .async(onQueue: queue))
            .makeAsyncIterator()

        #expect(try await iterator.next() == 1)   // one unplaced (target)

        // Place the target fully; only the completing answer touches `games`.
        while let prompt = try await rank.currentDuel(), prompt.kind == .placement, prompt.candidate == target {
            _ = try await rank.answer(winner: target)
        }
        #expect(try await iterator.next() == 0)    // observation re-emitted after placement
    }

    // MARK: - Performance at 2000 ranked games

    @Test func performanceAt2000RankedGames() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let tiers: [Int64] = [1, 2, 3, 4, 5, 6]
        var drafts: [GameDraft] = []
        drafts.reserveCapacity(2000)
        for i in 0..<2000 {
            drafts.append(GameDraft(title: "Game \(i)", igdbID: Int64(500_000 + i),
                                    year: 1980 + (i % 45),
                                    platformIDs: [["ps2", "pc"][i % 2]],
                                    owned: true, tierID: tiers[i % tiers.count]))
        }
        let outcomes = try await lib.addGames(drafts)
        // Place every game (per-tier strictly increasing keys via the global index).
        let setKeys: [RankMutation] = outcomes.enumerated().map { i, o in
            .setKey(id: o.gameID, key: RankKey(i + 1) * (1 << 20))
        }
        try await rank.dbWriter.write { db in try RankingStore.applyMutations(setKeys, db) }

        func measure(_ body: () async throws -> Void) async rethrows -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let clock = ContinuousClock()
                let start = clock.now
                try await body()
                best = min(best, Double((clock.now - start).components.attoseconds) / 1e15)
            }
            return best
        }

        let boardMs = try await measure { _ = try await rank.tierBoardOnce() }
        let topMs = try await measure { _ = try await rank.theTopOnce(filter: LibraryFilter(scope: .all)) }

        // One answer on a populous tier.
        let target = try await RankTestDB.addGame(lib, title: "PERF-TARGET", tier: 1)
        _ = try await rank.currentDuel()
        let answerClock = ContinuousClock()
        let answerStart = answerClock.now
        _ = try await rank.answer(winner: target)
        let answerMs = Double((answerClock.now - answerStart).components.attoseconds) / 1e15

        print("PERF ranking(2000): tierBoard=\(String(format: "%.2f", boardMs))ms  " +
              "theTop(.all)=\(String(format: "%.2f", topMs))ms  answer=\(String(format: "%.2f", answerMs))ms")

        // Generous CI bounds; printed numbers are the real figures for the handoff.
        // Printed, never asserted: wall-clock limits flake under parallel load
        // (CLAUDE.md "No wall-clock assertions") — this one failed at 254 ms vs 250.
        _ = (boardMs, topMs, answerMs)
        _ = target
    }
}

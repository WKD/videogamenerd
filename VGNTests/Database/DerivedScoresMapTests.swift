import Foundation
import Testing
import GRDB
@testable import VGN

/// The library-wide derived-scores map behind the grid badge tooltips
/// (`RankingStore.allDerivedScores` / `derivedScoresObservation`, both computed by
/// the pure `DerivedScore` engine over the ranking snapshot — never stored).
struct DerivedScoresMapTests {

    @Test func mapCoversPlacedApproximateAndSkipsUntiered() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        // Tier S(1): two placed games. Tier A(2): one lone placed. Tier B(3): one
        // unplaced. Plus a played-but-untiered game (no tier → no score).
        let s1 = try await RankTestDB.addGame(lib, title: "S First", tier: 1, owned: true)
        let s2 = try await RankTestDB.addGame(lib, title: "S Second", tier: 1, owned: true)
        let aLone = try await RankTestDB.addGame(lib, title: "A Lone", tier: 2, owned: true)
        let bUnplaced = try await RankTestDB.addGame(lib, title: "B Unplaced", tier: 3, owned: true)
        let untiered = try await lib.addGame(GameDraft(title: "Untiered", played: true)).gameID

        try await RankTestDB.setKey(rank, s1, RankKey(100))
        try await RankTestDB.setKey(rank, s2, RankKey(200))
        try await RankTestDB.setKey(rank, aLone, RankKey(100))

        let scores = try await rank.allDerivedScores()

        // Two placed games in the same tier: exact, and the lower key ranks higher.
        #expect(scores[s1]?.isApproximate == false)
        #expect(scores[s2]?.isApproximate == false)
        #expect((scores[s1]?.value ?? 0) > (scores[s2]?.value ?? 0))
        // A lone placed game: the band midpoint, not approximate.
        #expect(scores[aLone]?.isApproximate == false)
        // An unplaced tiered game: the band midpoint, flagged approximate ("~").
        #expect(scores[bUnplaced]?.isApproximate == true)
        // An untiered game carries no score.
        #expect(scores[untiered] == nil)
    }

    @Test func mapUpdatesAfterARankOrTierChange() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "Mover", tier: 3, owned: true)   // tier B, unplaced

        // Unplaced → approximate.
        #expect(try await rank.allDerivedScores()[g]?.isApproximate == true)

        // Rank change: placing it makes the score exact (lone placed = midpoint).
        try await RankTestDB.setKey(rank, g, RankKey(100))
        #expect(try await rank.allDerivedScores()[g]?.isApproximate == false)

        // Tier change: moving it to S shifts the score into the S band.
        let before = try await rank.allDerivedScores()[g]?.value
        _ = try await rank.setTier([g], tierID: 1)
        let after = try await rank.allDerivedScores()[g]?.value
        #expect(before != nil && after != nil)
        #expect(before != after)   // a different band ⇒ a different score
    }
}

#if DEBUG
/// Printed-timing perf case for the scores map at scale (PLAN §9). Asserts
/// correctness only — no wall-clock ceiling (flakes under parallel load).
struct DerivedScoresMapPerfTests {
    @Test func scoresMapCostAt2000Games() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let lib = LibraryStore(db)
        let rank = RankingStore(db)
        await PerfSeeder.seed(into: lib, count: 2000)

        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        var count = 0
        for _ in 0..<3 {
            let start = clock.now
            let scores = try await rank.allDerivedScores()
            best = min(best, Double((clock.now - start).components.attoseconds) / 1e15)
            count = scores.count
        }
        print("VGN perf: derived-scores map @2000 games — \(String(format: "%.2f", best))ms for \(count) scores")
        #expect(count > 0)
    }
}
#endif

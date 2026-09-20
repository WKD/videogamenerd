import Foundation
import Testing
import GRDB
@testable import VGN

/// The "Suspicious Estimate" filter (PLAN §5.3, D2) and the personal-length fallback it
/// drives in the BY LENGTH shelves, Stats and the Play Next input (D5): the facet returns
/// exactly the flagged games, composes with other facets, excludes hltb-sourced and
/// dismissed games, and dismissing a game restores its raw length everywhere.
@Suite struct SuspiciousEstimateFilterTests {

    private let h = 3600

    /// Add an owned game with the three times set, optionally sourced from HLTB.
    @discardableResult
    private func addGame(_ store: LibraryStore, _ title: String, igdb: Int64, platform: String = "pc",
                         rushed: Int? = nil, main: Int? = nil, completionist: Int? = nil,
                         hltb: Bool = false, played: Bool = false) async throws -> Int64 {
        let g = try await store.addGame(GameDraft(title: title, igdbID: igdb, platformIDs: [platform],
                                                  owned: true, played: played))
        try await store.updateMetadata(gameID: g.gameID,
            MetadataPatch(ttbHastilyS: rushed, ttbNormallyS: main, ttbCompletelyS: completionist))
        if hltb {
            try await store.dbWriter.write { db in
                try db.execute(sql: "UPDATE games SET ttb_source = 'hltb' WHERE id = ?", arguments: [g.gameID])
            }
        }
        return g.gameID
    }

    private func filteredIDs(_ store: LibraryStore, _ filter: LibraryFilter) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: filter).map(\.id))
    }

    // MARK: - Filter scope + count

    @Test func filterReturnsExactlyTheFlaggedGames() async throws {
        let store = try await TestDB.makeStore()
        let inflated = try await addGame(store, "LittleBigPlanet", igdb: 1, main: 54 * h, completionist: 1000 * h)
        let unordered = try await addGame(store, "Rushed Over Main", igdb: 2, rushed: 30 * h, main: 10 * h, completionist: 40 * h)
        let ok = try await addGame(store, "Ordered", igdb: 3, main: 10 * h, completionist: 20 * h)
        let refreshed = try await addGame(store, "HLTB", igdb: 4, main: 10 * h, completionist: 1000 * h, hltb: true)
        let none = try await addGame(store, "No Times", igdb: 5)

        let flagged = try await filteredIDs(store, LibraryFilter(includeSuspiciousEstimate: true, scope: .all))
        #expect(flagged == [inflated, unordered])
        #expect(!flagged.contains(ok))
        #expect(!flagged.contains(refreshed))   // hltb is the reference — never flagged
        #expect(!flagged.contains(none))

        // The store's own list (the refresh default scope) matches the filter.
        let ids = Set(try await store.suspiciousEstimateGameIDs())
        #expect(ids == flagged)
    }

    @Test func filterComposesWithOtherFacets() async throws {
        let store = try await TestDB.makeStore()
        let pc = try await addGame(store, "PC Bad", igdb: 1, platform: "pc", main: 10 * h, completionist: 100 * h)
        _ = try await addGame(store, "PS5 Bad", igdb: 2, platform: "ps5", main: 10 * h, completionist: 100 * h)

        // Suspicious AND platform = pc.
        let f = LibraryFilter(includeSuspiciousEstimate: true, platforms: ["pc"], scope: .all)
        #expect(try await filteredIDs(store, f) == [pc])
        // Suspicious AND search text.
        let f2 = LibraryFilter(searchText: "ps5", includeSuspiciousEstimate: true, scope: .all)
        #expect(try await filteredIDs(store, f2).count == 1)
    }

    // MARK: - Dismissal

    @Test func dismissLeavesTheFilterAndFlagAgainReturns() async throws {
        let store = try await TestDB.makeStore()
        let g = try await addGame(store, "Fishy", igdb: 1, main: 10 * h, completionist: 100 * h)
        let filter = LibraryFilter(includeSuspiciousEstimate: true, scope: .all)
        #expect(try await filteredIDs(store, filter) == [g])

        try await store.setEstimateLooksRight(gameID: g, dismissed: true)
        #expect(try await filteredIDs(store, filter).isEmpty)
        #expect(try await store.dismissedEstimateIDs() == [g])

        try await store.setEstimateLooksRight(gameID: g, dismissed: false)   // Flag again
        #expect(try await filteredIDs(store, filter) == [g])
        #expect(try await store.dismissedEstimateIDs().isEmpty)
    }

    // MARK: - Personal-length fallback: shelves (D5)

    @Test func flaggedCompletionistFallsBackInShelvesUntilDismissed() async throws {
        let store = try await TestDB.makeStore()
        // main 10 h, completionist 100 h (≥ 4× main → flagged). At Completionist style the
        // raw length is 100 h (Epic); the fallback is 10 h × 1.5 = 15 h (A Few Weeks).
        let g = try await addGame(store, "Inflated", igdb: 1, main: 10 * h, completionist: 100 * h)
        func shelfIDs(_ shelf: LengthShelf) async throws -> Set<Int64> {
            try await filteredIDs(store, LibraryFilter(scope: .length(shelf), playStyle: .completionist))
        }
        #expect(try await shelfIDs(.fewWeeks) == [g])
        #expect(try await shelfIDs(.epic).isEmpty)

        // Dismiss → raw length (100 h) → Epic.
        try await store.setEstimateLooksRight(gameID: g, dismissed: true)
        #expect(try await shelfIDs(.epic) == [g])
        #expect(try await shelfIDs(.fewWeeks).isEmpty)
    }

    // MARK: - Personal-length fallback: Play Next input (D5)

    @Test func recommendationInputUsesTheFallbackCompletionist() async throws {
        let store = try await TestDB.makeStore()
        let g = try await addGame(store, "Inflated", igdb: 1, main: 10 * h, completionist: 100 * h, played: false)

        let flagged = try await store.dbReader.read { db in
            try RecommendationStore.loadCandidates(db: db).first { $0.id == g }
        }
        #expect(flagged?.estimateSeconds == 10 * h)
        #expect(flagged?.completionistSeconds == Int((Double(10 * h) * PlayStyle.sidesRatio).rounded())) // 15 h

        try await store.setEstimateLooksRight(gameID: g, dismissed: true)
        let dismissed = try await store.dbReader.read { db in
            try RecommendationStore.loadCandidates(db: db).first { $0.id == g }
        }
        #expect(dismissed?.completionistSeconds == 100 * h)   // raw again
    }

    // MARK: - Printed-timing perf for the new facet (no wall-clock assert)

    #if DEBUG
    @Test func gridQueryPerfAt2000WithAndWithoutSuspiciousFacet() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let store = LibraryStore(db)
        await PerfSeeder.seed(into: store, count: 2000)

        func best(_ filter: LibraryFilter) async throws -> Double {
            let clock = ContinuousClock()
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let start = clock.now
                _ = try await store.gamesOnce(filter: filter)
                best = min(best, Double((clock.now - start).components.attoseconds) / 1e15)
            }
            return best
        }
        let plain = try await best(LibraryFilter(scope: .all))
        let suspicious = try await best(LibraryFilter(includeSuspiciousEstimate: true, scope: .all))
        print("VGN grid @2000 — plain: \(String(format: "%.2f", plain))ms · +Suspicious Estimate facet: \(String(format: "%.2f", suspicious))ms")
        #expect(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).count == 2000)
    }
    #endif
}

import Foundation
import Testing
import GRDB
@testable import VGN

/// Data-layer tests for the full Library Stats dashboard report (PLAN §6.4). Every
/// section, scope variants, empty library, NULL fields, compilations not
/// double-counted, and the derived-score groupings (which reuse the pure
/// ``DerivedScore`` engine over the ranking snapshot).
@Suite struct LibraryStatsReportTests {

    private let h = 3600

    /// Raw PSN playtime write (no public setter — PSN import owns that column).
    private func setPSN(_ store: LibraryStore, gameID: Int64, seconds: Int) async throws {
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET psn_playtime_s = ? WHERE id = ?",
                           arguments: [seconds, gameID])
        }
    }

    // MARK: - Overview, formats, compilations

    @Test func overviewFormatsAndCompilations() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)

        // g1 owned physical + played + tier S; g2 owned digital; g3 owned ROM;
        // g4 played but not owned; g5 owned physical, unplayed (backlog).
        _ = try await store.addGame(GameDraft(title: "G1", igdbID: 1, platformIDs: ["pc"],
                                              owned: true, played: true, tierID: 1))
        _ = try await store.addGame(GameDraft(title: "G2", igdbID: 2, platformIDs: ["ps4"],
                                              owned: true, format: .digital))
        _ = try await store.addGame(GameDraft(title: "G3", igdbID: 3, platformIDs: ["ps4"],
                                              owned: true, format: .rom))
        _ = try await store.addGame(GameDraft(title: "G4", igdbID: 4, platformIDs: ["pc"],
                                              owned: false, played: true))
        _ = try await store.addGame(GameDraft(title: "G5", igdbID: 5, platformIDs: ["ps2"], owned: true))
        // A compilation of two member games on SNES (owned physical), unplayed.
        _ = try await store.addCompilation(
            product: ProductDraft(platformID: "snes", format: .physical),
            members: [CompilationMemberDraft(title: "M1", igdbID: 6, position: 0),
                      CompilationMemberDraft(title: "M2", igdbID: 7, position: 1)])

        let r = try await stats.report(scope: .all)
        #expect(r.totalGames == 7)
        #expect(r.ownedGames == 6)          // all but G4
        #expect(r.playedGames == 2)         // G1, G4
        #expect(r.backlogGames == 5)        // G2, G3, G5, M1, M2
        #expect(r.playedNotOwned == 1)      // G4
        #expect(r.compilations == 1)

        // Copies by format: physical G1 + G5 + compilation = 3; digital 1; rom 1.
        let fmt = Dictionary(uniqueKeysWithValues: r.copiesByFormat.map { ($0.format, $0.count) })
        #expect(fmt[.physical] == 3)
        #expect(fmt[.digital] == 1)
        #expect(fmt[.rom] == 1)

        // Compilation members counted once each, not doubled by the product.
        let snes = r.platformBreakdown.first { $0.platformID == "snes" }
        #expect(snes?.total == 2)
        #expect(snes?.owned == 2)
    }

    // MARK: - Playtime sections

    @Test func playtimeSections() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)

        let g1 = try await store.addGame(GameDraft(title: "PC Epic", igdbID: 1, year: 2015,
                                                   platformIDs: ["pc"], owned: true, played: true, tierID: 1))
        try await store.setMyPlaytime(gameID: g1.gameID, seconds: 40 * h)
        try await store.updateMetadata(gameID: g1.gameID, MetadataPatch(ttbNormallyS: 30 * h))

        let g4 = try await store.addGame(GameDraft(title: "PS4 Short", igdbID: 4, year: 2005,
                                                   platformIDs: ["ps4"], owned: false, played: true))
        try await setPSN(store, gameID: g4.gameID, seconds: 10 * h)   // PSN only → effective 10 h
        try await store.updateMetadata(gameID: g4.gameID, MetadataPatch(ttbNormallyS: 20 * h))

        // Backlog: owned + unplayed. g5 has an estimate; g6 does not.
        let g5 = try await store.addGame(GameDraft(title: "Backlog A", igdbID: 5, platformIDs: ["ps2"], owned: true))
        try await store.updateMetadata(gameID: g5.gameID, MetadataPatch(ttbNormallyS: 15 * h))
        _ = try await store.addGame(GameDraft(title: "Backlog B", igdbID: 6, platformIDs: ["ps2"], owned: true))

        let r = try await stats.report(scope: .all)
        #expect(r.totalPlaytimeSeconds == 50 * h)

        let byPlat = Dictionary(uniqueKeysWithValues: r.playtimeByPlatform.map { ($0.platformID, $0.seconds) })
        #expect(byPlat["pc"] == 40 * h)
        #expect(byPlat["ps4"] == 10 * h)

        let byDecade = Dictionary(uniqueKeysWithValues: r.playtimeByDecade.map { ($0.decade, $0.seconds) })
        #expect(byDecade[2010] == 40 * h)
        #expect(byDecade[2000] == 10 * h)

        #expect(r.playtimeByTier.first { $0.letter == "S" }?.seconds == 40 * h)

        #expect(r.topPlayed.map(\.gameID) == [g1.gameID, g4.gameID])
        #expect(r.topPlayed.first?.seconds == 40 * h)

        // Me vs. average: G1 (40 h / 30 h) and G4 (10 h / 20 h) qualify.
        #expect(r.myHoursVsAverage.gameCount == 2)
        #expect(r.myHoursVsAverage.mineSeconds == 50 * h)
        #expect(r.myHoursVsAverage.averageSeconds == 50 * h)

        // Backlog estimate uses the owner's PERSONAL length at the default play style
        // (D4), not the raw 15 h main story; g6 has no estimate.
        let expectedBacklog = PersonalLength.compute(
            normallyS: 15 * h, completelyS: nil, style: .default)!.seconds
        #expect(r.myHoursVsAverage.backlogEstimateSeconds == expectedBacklog)
        #expect(expectedBacklog != 15 * h)   // it reflects the play style
        #expect(r.myHoursVsAverage.backlogGamesMissingEstimate == 1)
    }

    // MARK: - Scope variants

    @Test func scopeVariantsNarrowTheUniverse() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)
        _ = try await store.addGame(GameDraft(title: "Owned+Played", igdbID: 1, platformIDs: ["pc"],
                                              owned: true, played: true))
        _ = try await store.addGame(GameDraft(title: "Owned only", igdbID: 2, platformIDs: ["pc"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Played only", igdbID: 3, platformIDs: ["pc"], played: true))

        #expect(try await stats.report(scope: .all).totalGames == 3)
        #expect(try await stats.report(scope: .owned).totalGames == 2)
        #expect(try await stats.report(scope: .played).totalGames == 2)
        // Scope is echoed back on the report.
        #expect(try await stats.report(scope: .played).scope == .played)
    }

    // MARK: - Empty library

    @Test func emptyLibrary() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)
        let r = try await stats.report(scope: .all)
        #expect(r.isEmpty)
        #expect(r.totalGames == 0)
        #expect(r.totalPlaytimeSeconds == 0)
        #expect(r.completionRate == nil)
        #expect(r.topPlayed.isEmpty)
        #expect(r.platformBreakdown.isEmpty)
        // Activity is always a full 12-month window, even when empty.
        #expect(r.addedByMonth.count == 12)
        #expect(r.addedByMonth.allSatisfy { $0.count == 0 })
        // Tier rows still present (the ladder), all zero.
        #expect(r.tierBreakdown.count == 6)
        #expect(r.tierBreakdown.allSatisfy { $0.count == 0 })
    }

    // MARK: - NULL year / tier / status / playtime

    @Test func nullFieldsAreHandled() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)
        // Played, no year, no tier, no status, no playtime.
        _ = try await store.addGame(GameDraft(title: "Mystery", igdbID: 1, platformIDs: ["pc"], played: true))
        // A dated, tiered, status-set game for contrast.
        let g = try await store.addGame(GameDraft(title: "Known", igdbID: 2, year: 1998,
                                                  platformIDs: ["pc"], owned: true, played: true, tierID: 1))
        try await store.setStatus([g.gameID], .finished)

        let r = try await stats.report(scope: .all)
        #expect(r.unknownYearCount == 1)
        #expect(r.gamesByDecade.first { $0.decade == nil }?.count == 1)
        #expect(r.gamesByDecade.first { $0.decade == 1990 }?.count == 1)
        #expect(r.unrankedPlayedCount == 1)             // the Mystery game
        #expect(r.statusCounts.noStatus == 1)           // Mystery has no status
        #expect(r.statusCounts.finished == 1)           // Known
        // Unknown-year decade sorts last.
        #expect(r.gamesByDecade.last?.decade == nil)
    }

    // MARK: - Derived-score groupings (ranked games only)

    @Test func derivedScoreGroupings() async throws {
        let store = try await TestDB.makeStore()
        let ranking = RankingStore(store.database)
        let stats = LibraryStatsStore(store.database)

        // Three PC RPGs placed in S, top → bottom → scores 10.0, 9.5, 9.0.
        var ids: [Int64] = []
        for i in 1...3 {
            let g = try await store.addGame(GameDraft(title: "S\(i)", igdbID: Int64(i), year: 2012,
                                                      platformIDs: ["pc"], owned: true, played: true, tierID: 1))
            try await store.updateMetadata(gameID: g.gameID, MetadataPatch(genres: ["RPG"]))
            ids.append(g.gameID)
        }
        for (index, id) in ids.enumerated() {
            try await ranking.move(gameID: id, toTier: 1, atIndex: index)
        }
        // A two-game genre (below the n ≥ 3 gate) that must be excluded.
        for i in 4...5 {
            let g = try await store.addGame(GameDraft(title: "A\(i)", igdbID: Int64(i), year: 2012,
                                                      platformIDs: ["ps4"], owned: true, played: true, tierID: 2))
            try await store.updateMetadata(gameID: g.gameID, MetadataPatch(genres: ["Puzzle"]))
        }

        let r = try await stats.report(scope: .all)

        let pcScore = r.averageScoreByPlatform.first { $0.platformID == "pc" }
        #expect(pcScore?.n == 3)
        #expect(abs((pcScore?.average ?? 0) - 9.5) < 0.001)

        #expect(r.bestGameByPlatform.first { $0.platformID == "pc" }?.gameID == ids[0])
        #expect(abs((r.bestGameByPlatform.first { $0.platformID == "pc" }?.score ?? 0) - 10.0) < 0.001)

        let decade = r.averageScoreByDecade.first { $0.decade == 2012 - (2012 % 10) }
        #expect(decade?.n == 5)   // all five ranked games are 2010s

        // RPG (n = 3) present; Puzzle (n = 2) gated out.
        #expect(r.averageScoreByGenre.contains { $0.genre == "RPG" && $0.n == 3 })
        #expect(!r.averageScoreByGenre.contains { $0.genre == "Puzzle" })
        #expect(abs((r.averageScoreByGenre.first { $0.genre == "RPG" }?.average ?? 0) - 9.5) < 0.001)
    }

    // MARK: - Status & completion rate

    @Test func statusAndCompletionRate() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)
        // 4 played: finished, completed(100%), abandoned, no status.
        let finished = try await store.addGame(GameDraft(title: "F", igdbID: 1, platformIDs: ["pc"], played: true))
        let done = try await store.addGame(GameDraft(title: "C", igdbID: 2, platformIDs: ["pc"], played: true))
        let quit = try await store.addGame(GameDraft(title: "Q", igdbID: 3, platformIDs: ["pc"], played: true))
        _ = try await store.addGame(GameDraft(title: "N", igdbID: 4, platformIDs: ["pc"], played: true))
        try await store.setStatus([finished.gameID], .finished)
        try await store.setStatus([done.gameID], .completed)
        try await store.setStatus([quit.gameID], .abandoned)

        let r = try await stats.report(scope: .all)
        #expect(r.statusCounts.finished == 1)
        #expect(r.statusCounts.completed == 1)
        #expect(r.statusCounts.abandoned == 1)
        #expect(r.statusCounts.noStatus == 1)
        // (finished + 100 %) / played = 2 / 4.
        #expect(r.completionRate == 0.5)
    }

    // MARK: - Activity window

    @Test func activityCountsCurrentMonth() async throws {
        let store = try await TestDB.makeStore()
        let stats = LibraryStatsStore(store.database)
        for i in 1...3 {
            _ = try await store.addGame(GameDraft(title: "New\(i)", igdbID: Int64(i), platformIDs: ["pc"], owned: true))
        }
        let now = Date()
        let r = try await stats.report(scope: .all, referenceDate: now)
        #expect(r.addedByMonth.count == 12)
        // Everything was added "now" → the last (current) bucket holds them all.
        #expect(r.addedByMonth.last?.count == 3)
        #expect(r.addedByMonth.dropLast().allSatisfy { $0.count == 0 })
    }
}

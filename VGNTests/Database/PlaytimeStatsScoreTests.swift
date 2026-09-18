import Foundation
import Testing
import GRDB
@testable import VGN

/// Data-layer tests for the M5 playtime filter buckets, the sidebar stats
/// aggregates, and the inspector derived-score line (PLAN §6.4/§7).
@Suite struct PlaytimeStatsScoreTests {

    private let h = 3600

    // MARK: - Playtime filter buckets through SQL

    @Test func playtimeBucketsFilterOnEffectiveThenIGDB() async throws {
        let store = try await TestDB.makeStore()
        // Played with manual 5 h → short.
        let a = try await store.addGame(GameDraft(title: "Short One", igdbID: 1, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 5 * h)
        // Played with manual 20 h → medium.
        let b = try await store.addGame(GameDraft(title: "Medium One", igdbID: 2, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: b.gameID, seconds: 20 * h)
        // Played with manual 80 h → long.
        let c = try await store.addGame(GameDraft(title: "Long One", igdbID: 3, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: c.gameID, seconds: 80 * h)
        // Unplayed, IGDB main = 8 h → short (fallback estimate).
        let d = try await store.addGame(GameDraft(title: "Unplayed Short", igdbID: 4, platformIDs: ["pc"],
                                                  owned: true))
        try await store.updateMetadata(gameID: d.gameID, MetadataPatch(ttbNormallyS: 8 * h))
        // Unplayed, no estimate → excluded from any bucket.
        _ = try await store.addGame(GameDraft(title: "No Data", igdbID: 5, platformIDs: ["pc"], owned: true))

        func ids(_ buckets: Set<PlaytimeBucket>) async throws -> Set<Int64> {
            let rows = try await store.gamesOnce(filter: LibraryFilter(playtimes: buckets, scope: .all))
            return Set(rows.map(\.id))
        }

        #expect(try await ids([.short]) == [a.gameID, d.gameID])
        #expect(try await ids([.medium]) == [b.gameID])
        #expect(try await ids([.long]) == [c.gameID])
        // OR within the kind.
        #expect(try await ids([.short, .long]) == [a.gameID, c.gameID, d.gameID])
    }

    // MARK: - Playtime sort uses effective, unknowns last both directions

    @Test func playtimeSortPutsUnknownsLastBothDirections() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", igdbID: 1, platformIDs: ["pc"], played: true))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 10 * h)
        let b = try await store.addGame(GameDraft(title: "B", igdbID: 2, platformIDs: ["pc"], played: true))
        try await store.setMyPlaytime(gameID: b.gameID, seconds: 50 * h)
        let unknown = try await store.addGame(GameDraft(title: "Z", igdbID: 3, platformIDs: ["pc"], played: true))

        let desc = try await store.gamesOnce(
            filter: LibraryFilter(scope: .all, sort: .playtime, ascending: false)).map(\.id)
        #expect(desc.last == unknown.gameID)       // unknown last
        #expect(desc.first == b.gameID)            // most played first

        let asc = try await store.gamesOnce(
            filter: LibraryFilter(scope: .all, sort: .playtime, ascending: true)).map(\.id)
        #expect(asc.last == unknown.gameID)        // unknown still last
        #expect(asc.first == a.gameID)
    }

    // MARK: - Stats aggregates

    @Test func libraryStatsAggregate() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "Bloodborne", igdbID: 1, platformIDs: ["ps4"],
                                                  owned: true, played: true, tierID: 1))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 40 * h)
        _ = try await store.addGame(GameDraft(title: "Backlog Game", igdbID: 2, platformIDs: ["ps4"],
                                              owned: true))               // owned, unplayed → backlog
        _ = try await store.addGame(GameDraft(title: "Played Only", igdbID: 3, platformIDs: ["pc"],
                                              owned: false, played: true))

        let stats = try await store.libraryStats()
        #expect(stats.total == 3)
        #expect(stats.owned == 2)
        #expect(stats.played == 2)
        #expect(stats.backlog == 1)
        #expect(stats.totalPlaytimeSeconds == 40 * h)
        // Top platform is ps4 (2 games).
        #expect(stats.byPlatform.first?.platformID == "ps4")
        #expect(stats.byPlatform.first?.count == 2)
        // Tier S has 1 played game.
        #expect(stats.byTier.first { $0.letter == "S" }?.count == 1)
    }

    // MARK: - Derived-score line via the store

    @Test func scoreLinePlacedAndUnplaced() async throws {
        let db = try await TestDB.makeSeeded()
        let store = LibraryStore(db)
        let ranking = RankingStore(db)

        // Three games placed in S with explicit keys, one unplaced in A.
        let s1 = try await store.addGame(GameDraft(title: "S1", igdbID: 1, platformIDs: ["pc"], played: true, tierID: 1))
        let s2 = try await store.addGame(GameDraft(title: "S2", igdbID: 2, platformIDs: ["pc"], played: true, tierID: 1))
        let s3 = try await store.addGame(GameDraft(title: "S3", igdbID: 3, platformIDs: ["pc"], played: true, tierID: 1))
        // Place them via drag moves (assigns keys), top → bottom.
        try await ranking.move(gameID: s1.gameID, toTier: 1, atIndex: 0)
        try await ranking.move(gameID: s2.gameID, toTier: 1, atIndex: 1)
        try await ranking.move(gameID: s3.gameID, toTier: 1, atIndex: 2)

        let a1 = try await store.addGame(GameDraft(title: "A1", igdbID: 4, platformIDs: ["pc"], played: true, tierID: 2))

        let line1 = try #require(await ranking.scoreLine(for: s1.gameID))
        #expect(line1.isPlaced)
        #expect(line1.tierLetter == "S")
        #expect(line1.tierPosition == 1)
        #expect(line1.tierTotalPlaced == 3)
        #expect(line1.overallPosition == 1)
        #expect(line1.overallTotalPlaced == 3)
        // Top of a full band → 10.0
        #expect(line1.score.value == 10.0)

        let line3 = try #require(await ranking.scoreLine(for: s3.gameID))
        #expect(line3.tierPosition == 3)
        #expect(line3.overallPosition == 3)

        // Unplaced A game: approximate, no positions.
        let lineA = try #require(await ranking.scoreLine(for: a1.gameID))
        #expect(!lineA.isPlaced)
        #expect(lineA.tierLetter == "A")
        #expect(lineA.tierPosition == nil)
        #expect(lineA.score.isApproximate)

        // Unranked (played, no tier) → no line.
        let un = try await store.addGame(GameDraft(title: "U", igdbID: 9, platformIDs: ["pc"], played: true))
        #expect(await ranking.scoreLine(for: un.gameID) == nil)
    }
}

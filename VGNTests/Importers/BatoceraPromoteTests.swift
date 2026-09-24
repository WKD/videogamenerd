import Foundation
import Testing
import GRDB
@testable import VGN

/// Promotion through the shared importer commit path (PLAN §15): a candidate becomes an
/// owned ROM copy with the box's played data; a candidate matched to a game that already
/// owns a ROM copy adds no second copy; Batocera play time never clobbers a real value.
struct BatoceraPromoteTests {

    private func seededCandidate(_ store: RomCatalogStore, name: String, path: String,
                                 gametime: Int, favorite: Bool = false) async throws -> RomCatalogEntry {
        let g = BatoceraGame(system: "snes", relativePath: "./" + path, name: name,
                             gameTimeSeconds: gametime, isFavorite: favorite)
        let entry = RomCatalogEntry.make(from: g, platformID: "snes",
                                         libretroKey: BatoceraFolding.foldKey(for: g))
        _ = try await store.syncSystem(system: "snes", entries: [entry])
        return try #require(try await store.entries(system: "snes").first { $0.name == name })
    }

    @Test(.timeLimit(.minutes(1)))
    func promoteNewGameCreatesOwnedPlayedROMCopy() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let promoter = BatoceraPromoter(db)
        let entry = try await seededCandidate(store, name: "Super Metroid", path: "sm.zip", gametime: 3600)

        let result = try await promoter.promote([
            .init(entry: entry, target: BatoceraPromotionBuilder.newGameTarget(for: entry))
        ])
        #expect(result.commit.gamesCreated == 1)
        #expect(result.commit.productsAdded == 1)
        #expect(result.promotedCatalogIDs == [entry.id])

        // The catalogue row is now linked.
        let reloaded = try #require(try await store.entry(id: entry.id))
        let gameID = try #require(reloaded.promotedGameID)

        let (played, playtime, format, source, origin) = try await db.dbWriter.read { db -> (Int64, Int64?, String, String, String?) in
            let played: Int64 = try Int64.fetchOne(db, sql: "SELECT played FROM games WHERE id = ?", arguments: [gameID]) ?? -1
            let pt: Int64? = try Int64.fetchOne(db, sql: "SELECT batocera_playtime_s FROM games WHERE id = ?", arguments: [gameID])
            // v17: never written into the PSN column again.
            #expect(try Int64.fetchOne(db, sql: "SELECT psn_playtime_s FROM games WHERE id = ?", arguments: [gameID]) == nil)
            let fmt: String = try String.fetchOne(db, sql: """
                SELECT p.format FROM products p JOIN product_games pg ON pg.product_id = p.id
                WHERE pg.game_id = ?
                """, arguments: [gameID]) ?? ""
            let src: String = try String.fetchOne(db, sql: "SELECT source FROM products p JOIN product_games pg ON pg.product_id = p.id WHERE pg.game_id = ?", arguments: [gameID]) ?? ""
            let og: String? = try String.fetchOne(db, sql: "SELECT origin FROM games WHERE id = ?", arguments: [gameID])
            return (played, pt, fmt, src, og)
        }
        #expect(played == 1)                      // > 5 min → played
        #expect(playtime == 3600)                 // stored in Batocera's own column (v17)
        #expect(format == "rom")
        #expect(source == "batocera")
        #expect(origin == "batocera")             // GameOrigin tagging
    }

    @Test(.timeLimit(.minutes(1)))
    func favouriteWithNoPlaytimeIsOwnedNotPlayed() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let promoter = BatoceraPromoter(db)
        let entry = try await seededCandidate(store, name: "Fav Game", path: "fav.zip",
                                              gametime: 0, favorite: true)
        let result = try await promoter.promote([
            .init(entry: entry, target: BatoceraPromotionBuilder.newGameTarget(for: entry))
        ])
        let gameID = try #require(try await store.entry(id: entry.id)).promotedGameID
        let played = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT played FROM games WHERE id = ?", arguments: [gameID!])
        }
        #expect(result.commit.productsAdded == 1)     // owned
        #expect(played == 0)                           // not played
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateRuleAddsNoSecondROMCopyButAppliesPlayData() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let promoter = BatoceraPromoter(db)

        // First promotion creates the game + ROM copy.
        let first = try await seededCandidate(store, name: "Chrono Trigger", path: "ct-us.zip", gametime: 100)
        _ = try await promoter.promote([.init(entry: first, target: BatoceraPromotionBuilder.newGameTarget(for: first))])
        let gameID = try #require(try await store.entry(id: first.id)).promotedGameID!
        #expect(try await promoter.gameHasROMCopy(gameID: gameID, platformID: "snes") == true)

        let copiesBefore = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE format = 'rom'") ?? -1
        }

        // A second catalogue entry the (imagined) IGDB match ties to the same game, which
        // already owns a ROM copy → no second copy, but the play time lands + the row links.
        let second = try await seededCandidate(store, name: "Chrono Trigger (dup)", path: "ct-eu.zip", gametime: 4000)
        let result = try await promoter.promote([
            .init(entry: second, target: .existingGame(gameID: gameID), alreadyHasROMCopy: true)
        ])
        #expect(result.commit.productsAdded == 0)             // no second copy
        let copiesAfter = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE format = 'rom'") ?? -1
        }
        #expect(copiesAfter == copiesBefore)
        #expect(try await store.entry(id: second.id)?.promotedGameID == gameID)
    }

    @Test(.timeLimit(.minutes(1)))
    func batoceraPlaytimeNeverClobbersARealValue() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let promoter = BatoceraPromoter(db)

        // A pre-existing game with a real PSN play time.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played, psn_playtime_s) VALUES (5, 'X', 1, 5000)")
        }
        let entry = try await seededCandidate(store, name: "X ROM", path: "x.zip", gametime: 999)
        _ = try await promoter.promote([.init(entry: entry, target: .existingGame(gameID: 5), alreadyHasROMCopy: false)])

        let (pt, bato) = try await db.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: "SELECT psn_playtime_s FROM games WHERE id = 5"),
             try Int64.fetchOne(db, sql: "SELECT batocera_playtime_s FROM games WHERE id = 5"))
        }
        #expect(pt == 5000)     // PSN's value is never touched by Batocera (v17)
        #expect(bato == 999)    // Batocera's time lands in its own column
    }

    /// v17: the Batocera time is monotonic — a re-promotion with a smaller `gametime` never
    /// lowers it, a larger one raises it; the manual value is never written.
    @Test(.timeLimit(.minutes(1)))
    func batoceraPlaytimeIsMonotonicAndNeverTouchesManual() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played, my_playtime_s) VALUES (7, 'Y', 1, 60)")
            try LibraryStore.setBatoceraPlaytime(gameID: 7, seconds: 5000, db: db)
            try LibraryStore.setBatoceraPlaytime(gameID: 7, seconds: 1200, db: db)   // lower: ignored
            try LibraryStore.setBatoceraPlaytime(gameID: 7, seconds: nil, db: db)    // nil: no-op
        }
        let (mine, psn, bato) = try await db.dbWriter.read { db in
            (try Int64.fetchOne(db, sql: "SELECT my_playtime_s FROM games WHERE id = 7"),
             try Int64.fetchOne(db, sql: "SELECT psn_playtime_s FROM games WHERE id = 7"),
             try Int64.fetchOne(db, sql: "SELECT batocera_playtime_s FROM games WHERE id = 7"))
        }
        #expect(mine == 60)
        #expect(psn == nil)
        #expect(bato == 5000)
        try await db.dbWriter.write { db in
            try LibraryStore.setBatoceraPlaytime(gameID: 7, seconds: 9000, db: db)   // higher: raises
        }
        let raised = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT batocera_playtime_s FROM games WHERE id = 7")
        }
        #expect(raised == 9000)
    }

    @Test(.timeLimit(.minutes(1)))
    func importerFetchYieldsStagingRowsForCandidates() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // Seed both in ONE sync (syncing one at a time would mark the first as vanished).
        let played = BatoceraGame(system: "snes", relativePath: "./p.zip", name: "Played", gameTimeSeconds: 900)
        let short = BatoceraGame(system: "snes", relativePath: "./s.zip", name: "TooShort", gameTimeSeconds: 100)
        _ = try await store.syncSystem(system: "snes", entries: [played, short].map {
            RomCatalogEntry.make(from: $0, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: $0))
        })

        let importer = BatoceraImporter(store: store)
        let result = try await importer.fetch { _ in }
        #expect(result.rows.count == 1)                       // only the candidate
        let row = try #require(result.rows.first)
        #expect(row.name == "Played")
        #expect(row.platform == "snes")
        #expect(row.externalID == "snes/./p.zip")
        #expect(row.signals.contains(.played))
        #expect(row.playDurationS == 900)
    }
}

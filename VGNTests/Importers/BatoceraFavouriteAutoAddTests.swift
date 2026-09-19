import Foundation
import Testing
import GRDB
@testable import VGN

/// Auto-adding Batocera favourites on a confident match (PLAN §15): the pure "confident" rule,
/// the background engine (promotes confident favourites, leaves the rest for review, never
/// queries one twice, caps a first run), and the one-step Undo that removes exactly what a
/// batch created and clears `promoted_game_id`.
struct BatoceraFavouriteAutoAddTests {

    // MARK: - Helpers

    private func outcome(_ bucket: ScanConfidenceBucket, igdbID: Int64 = 900, year: Int? = nil,
                        platforms: [String] = ["snes"]) -> ScanMatchOutcome {
        let best = bucket == .none ? nil : ScanMatch(
            igdbID: igdbID, name: "Match", releaseYear: year, coverImageID: nil,
            platformSlugs: platforms, score: bucket == .confident ? 0.95 : 0.8, matchedName: "Match")
        return ScanMatchOutcome(best: best, alternatives: [], bucket: bucket)
    }

    /// Seed favourites (and any non-favourites) in ONE sync so nothing is marked vanished.
    private func seedFavourites(_ store: RomCatalogStore,
                                _ specs: [(name: String, path: String, year: Int?, fav: Bool, gametime: Int)]) async throws {
        let entries = specs.map { spec -> RomCatalogEntry in
            let g = BatoceraGame(system: "snes", relativePath: "./" + spec.path, name: spec.name,
                                 releaseYear: spec.year, gameTimeSeconds: spec.gametime, isFavorite: spec.fav)
            return RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        }
        _ = try await store.syncSystem(system: "snes", entries: entries)
    }

    private func engine(_ db: AppDatabase, matcher: any ImportMatcher) -> BatoceraFavouriteAutoAdd {
        BatoceraFavouriteAutoAdd(catalog: RomCatalogStore(db), staging: ImportStagingStore(db),
                                 matcher: matcher, promoter: BatoceraPromoter(db))
    }

    // MARK: - The pure confidence rule

    @Test func confidentRuleTopBucketPlatformAndYear() {
        // Top bucket, on platform, year within 1 → confident.
        #expect(BatoceraFavouriteMatch.isConfident(outcome: outcome(.confident, year: 1990),
                                                   entryPlatform: "snes", entryYear: 1990))
        #expect(BatoceraFavouriteMatch.isConfident(outcome: outcome(.confident, year: 1991),
                                                   entryPlatform: "snes", entryYear: 1990))   // ±1 ok
        // Not the top bucket → not confident.
        #expect(!BatoceraFavouriteMatch.isConfident(outcome: outcome(.plausible, year: 1990),
                                                    entryPlatform: "snes", entryYear: 1990))
        // Year mismatch > 1 → downgraded.
        #expect(!BatoceraFavouriteMatch.isConfident(outcome: outcome(.confident, year: 1985),
                                                    entryPlatform: "snes", entryYear: 1990))
        // Wrong platform → downgraded.
        #expect(!BatoceraFavouriteMatch.isConfident(outcome: outcome(.confident, year: 1990, platforms: ["nes"]),
                                                    entryPlatform: "snes", entryYear: 1990))
        // Unknown years on either side → the year check does not block.
        #expect(BatoceraFavouriteMatch.isConfident(outcome: outcome(.confident, year: nil),
                                                   entryPlatform: "snes", entryYear: 1990))
    }

    // MARK: - The engine

    @Test(.timeLimit(.minutes(1)))
    func confidentFavouriteIsPromoted() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, [("Super Mario World", "smw.zip", 1990, true, 0)])

        let matcher = FakeImportMatcher()
        matcher.on(title: "Super Mario World", outcome(.confident, igdbID: 567, year: 1990))
        let result = await engine(db, matcher: matcher).run()

        #expect(result.addedCount == 1)
        #expect(result.promotedEntries.count == 1)
        let entry = try #require(try await store.entries(system: "snes").first)
        let gameID = try #require(entry.promotedGameID)
        let (source, igdb, played) = try await db.dbWriter.read { db -> (String, Int64?, Int64) in
            let src: String = try String.fetchOne(db, sql: "SELECT source FROM products p JOIN product_games pg ON pg.product_id = p.id WHERE pg.game_id = ?", arguments: [gameID]) ?? ""
            let ig: Int64? = try Int64.fetchOne(db, sql: "SELECT igdb_id FROM games WHERE id = ?", arguments: [gameID])
            let pl: Int64 = try Int64.fetchOne(db, sql: "SELECT played FROM games WHERE id = ?", arguments: [gameID]) ?? -1
            return (src, ig, pl)
        }
        #expect(source == "batocera")
        #expect(igdb == 567)
        #expect(played == 0)          // a favourite with no play time lands owned-not-played
    }

    @Test(.timeLimit(.minutes(1)))
    func ambiguousAndUnmatchedAndYearMismatchStayForReview() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, [
            ("Plausible One", "p.zip", 1992, true, 0),
            ("No Match", "n.zip", 1993, true, 0),
            ("Wrong Year", "w.zip", 1990, true, 0),
        ])
        let matcher = FakeImportMatcher()
        matcher.on(title: "Plausible One", outcome(.plausible, year: 1992))
        matcher.on(title: "No Match", outcome(.none))
        matcher.on(title: "Wrong Year", outcome(.confident, year: 1980))     // > 1 year off
        let result = await engine(db, matcher: matcher).run()

        #expect(result.addedCount == 0)
        // None promoted, but all three are now staged so a later run won't re-query them.
        let promoted = try await store.entries(system: "snes").filter { $0.promotedGameID != nil }
        #expect(promoted.isEmpty)
        #expect(try await store.favouritesNeedingMatchCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFavouriteIsNeverQueriedTwice() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, [("Once Only", "o.zip", 1994, true, 0)])
        let matcher = FakeImportMatcher()
        matcher.on(title: "Once Only", outcome(.none))       // stays for review
        _ = await engine(db, matcher: matcher).run()
        #expect(matcher.requests.count == 1)
        // A second sync's auto-add pass must not match it again.
        _ = await engine(db, matcher: matcher).run()
        #expect(matcher.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func firstRunCapsTheBatchAndReportsTheRemainder() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, [
            ("A", "a.zip", nil, true, 0), ("B", "b.zip", nil, true, 0), ("C", "c.zip", nil, true, 0),
        ])
        let matcher = FakeImportMatcher()   // all "no match" — we only assert the cap here
        let result = await engine(db, matcher: matcher).run(limit: 2)
        #expect(result.processedCount == 2)
        #expect(result.stillToMatchCount == 1)      // "1 still to match"
        #expect(matcher.requests.count == 2)        // capped — did not hammer IGDB
    }

    @Test(.timeLimit(.minutes(1)))
    func nonFavouritesAreNeverTouched() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // A played-but-not-favourite candidate must stay entirely for the review sheet.
        try await seedFavourites(store, [("Played Not Fav", "pnf.zip", 1995, false, 1200)])
        let matcher = FakeImportMatcher()
        matcher.on(title: "Played Not Fav", outcome(.confident, year: 1995))
        let result = await engine(db, matcher: matcher).run()
        #expect(result.addedCount == 0)
        #expect(matcher.requests.isEmpty)           // the engine never even looked at it
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)
    }

    // MARK: - Undo

    @Test(.timeLimit(.minutes(1)))
    func undoRemovesTheCreatedGameAndClearsTheLink() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, [("Undo Me", "u.zip", 1996, true, 0)])
        let matcher = FakeImportMatcher()
        matcher.on(title: "Undo Me", outcome(.confident, igdbID: 42, year: 1996))
        let promoter = BatoceraPromoter(db)
        let result = await BatoceraFavouriteAutoAdd(
            catalog: store, staging: ImportStagingStore(db), matcher: matcher, promoter: promoter).run()
        #expect(result.addedCount == 1)
        let gameID = try #require(try await store.entries(system: "snes").first?.promotedGameID)

        try await promoter.undoAutoAdd(entries: result.promotedEntries)

        let gameGone = try await db.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [gameID]) ?? false
        }
        #expect(gameGone)                                             // the created game is removed
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)   // link cleared

        // Idempotent: a second undo (banner + undo manager) is a harmless no-op.
        try await promoter.undoAutoAdd(entries: result.promotedEntries)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoOfAnExistingGamePromotionKeepsTheGameButDropsTheCopy() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // A pre-existing owned game carrying the IGDB id the favourite will match to.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, sort_title, igdb_id, played) VALUES (7,'Existing','existing',77,0)")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source) VALUES (70,'ps4','single','physical','photo')")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (70,7,0)")
        }
        try await seedFavourites(store, [("Existing", "e.zip", 1997, true, 0)])
        let matcher = FakeImportMatcher()
        matcher.on(title: "Existing", outcome(.confident, igdbID: 77, year: 1997))
        let promoter = BatoceraPromoter(db)
        let result = await BatoceraFavouriteAutoAdd(
            catalog: store, staging: ImportStagingStore(db), matcher: matcher, promoter: promoter).run()
        #expect(result.addedCount == 1)
        // The Batocera ROM copy was added to the existing game.
        let romCopies = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source = 'batocera'") ?? -1
        }
        #expect(romCopies == 1)

        try await promoter.undoAutoAdd(entries: result.promotedEntries)

        let (gameKept, batoceraCopies): (Bool, Int) = try await db.dbWriter.read { db in
            let kept = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = 7)") ?? false
            let copies = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source = 'batocera'") ?? -1
            return (kept, copies)
        }
        #expect(gameKept)                    // the pre-existing owned game survives
        #expect(batoceraCopies == 0)         // only the copy the batch created is removed
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)
    }
}

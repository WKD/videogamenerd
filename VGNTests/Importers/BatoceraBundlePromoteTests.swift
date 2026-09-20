import Foundation
import Testing
import GRDB
@testable import VGN

/// Batocera bundle promotion (D2, PLAN §5.1) + "everything from Batocera is a ROM" (D3, PLAN
/// §16): a confident bundle match promotes as a `rom`/`batocera` **compilation** with its member
/// games — on the review path AND the favourites auto-add path — with the one-member-only play
/// data rule, working In-Library detection, and a single-step undo. No network.
@MainActor
@Suite(.serialized)
struct BatoceraBundlePromoteTests {

    // MARK: - Helpers

    /// A fake expander returning preset members per bundle id.
    private struct FakeExpander: ImportBundleExpanding {
        let membersByID: [Int64: [IGDBSearchResult]]
        func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult {
            BundleMemberResult(members: membersByID[igdbID] ?? [])
        }
    }

    private func member(_ id: Int64, _ name: String) -> IGDBSearchResult {
        IGDBSearchResult(id: id, name: name, releaseYear: nil, coverImageID: nil,
                         platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                         genres: [], alternativeNames: [], gameType: .mainGame)
    }

    private func bundleOutcome(igdbID: Int64, name: String, year: Int?) -> ScanMatchOutcome {
        ScanMatchOutcome(
            best: ScanMatch(igdbID: igdbID, name: name, releaseYear: year, coverImageID: nil,
                            platformSlugs: ["snes"], score: 0.96, matchedName: name, gameType: .bundle),
            alternatives: [], bucket: .confident)
    }

    private func seedFavourite(_ store: RomCatalogStore, name: String, path: String,
                               year: Int?, gametime: Int, favourite: Bool = true) async throws {
        let g = BatoceraGame(system: "snes", relativePath: "./" + path, name: name,
                             releaseYear: year, gameTimeSeconds: gametime, isFavorite: favourite)
        let existing = try await store.entries(system: "snes")
        let e = RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        _ = try await store.syncSystem(system: "snes", entries: existing + [e])
    }

    private func compilationRow(_ db: AppDatabase) async throws -> (productID: Int64?, format: String?, source: String?, members: Int) {
        try await db.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT p.id AS id, p.format AS format, p.source AS source, p.kind AS kind
                FROM products p WHERE p.source = 'batocera' AND p.kind = 'compilation' LIMIT 1
                """)
            guard let row else { return (nil, nil, nil, 0) }
            let pid: Int64 = row["id"]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = ?",
                                         arguments: [pid]) ?? 0
            return (pid, row["format"], row["source"], count)
        }
    }

    // MARK: - Auto-add: an n-member bundle becomes a rom/batocera compilation, In Library, undoable

    @Test(.timeLimit(.minutes(1)))
    func autoAddExpandsAConfidentBundleIntoACompilation() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Super Mario All-Stars", path: "smas.zip", year: 1993, gametime: 0)

        let matcher = FakeImportMatcher()
        matcher.on(title: "Super Mario All-Stars", bundleOutcome(igdbID: 700, name: "Super Mario All-Stars", year: 1993))
        let expander = FakeExpander(membersByID: [700: [
            member(1, "Super Mario Bros."), member(2, "Super Mario Bros. 2"),
            member(3, "Super Mario Bros. 3"), member(4, "Super Mario Bros.: The Lost Levels"),
        ]])
        let promoter = BatoceraPromoter(db)
        let engine = BatoceraFavouriteAutoAdd(catalog: store, staging: ImportStagingStore(db),
                                              matcher: matcher, promoter: promoter, expander: expander)
        let result = await engine.run()

        #expect(result.addedCount == 1)
        // A rom/batocera compilation with the four members.
        let comp = try await compilationRow(db)
        #expect(comp.format == "rom")       // D3
        #expect(comp.source == "batocera")  // D3
        #expect(comp.members == 4)
        // In-Library detection: the catalogue row is linked to the first member (promoted_game_id).
        let entry = try #require(try await store.entries(system: "snes").first)
        let firstMember = try #require(entry.promotedGameID)
        // A favourite with no play time leaves every member owned-not-played.
        let anyPlayed = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE played = 1") ?? 0
        }
        #expect(anyPlayed == 0)
        _ = firstMember

        // Undo removes the compilation + its created members and clears the link (D2).
        try await promoter.undoAutoAdd(entries: result.promotedEntries)
        let afterUndo = try await compilationRow(db)
        #expect(afterUndo.productID == nil)
        let games = try await db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1 }
        #expect(games == 0)
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func autoAddLeavesAOneMemberBundleForReview() async throws {
        // A confident bundle that expands to a single member is ambiguous for the unattended pass
        // (D2) — it is staged but not promoted, so it surfaces in the review sheet.
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Weird Pack", path: "wp.zip", year: 1994, gametime: 0)
        let matcher = FakeImportMatcher()
        matcher.on(title: "Weird Pack", bundleOutcome(igdbID: 800, name: "Weird Pack", year: 1994))
        let expander = FakeExpander(membersByID: [800: [member(9, "Only Game")]])
        let result = await BatoceraFavouriteAutoAdd(
            catalog: store, staging: ImportStagingStore(db), matcher: matcher,
            promoter: BatoceraPromoter(db), expander: expander).run()
        #expect(result.addedCount == 0)
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)
    }

    // MARK: - The one-member play-time rule (review / promoter path)

    @Test(.timeLimit(.minutes(1)))
    func oneMemberBundleCarriesThePlayData() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Solo Collection", path: "solo.zip", year: 1995,
                                gametime: 4000, favourite: true)
        let entry = try #require(try await store.entries(system: "snes").first)
        let promoter = BatoceraPromoter(db)
        let plan = BatoceraPromoter.Plan.compilation(
            entry: entry,
            bundle: BatoceraPromoter.BundlePromotion(title: "Solo Collection",
                                                     members: [CompilationMemberDraft(title: "The One", igdbID: 11)]))
        _ = try await promoter.promote([plan])

        let (played, playtime): (Int, Int?) = try await db.dbWriter.read { db in
            let p = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE played = 1") ?? 0
            let t = try Int.fetchOne(db, sql: "SELECT my_playtime_s FROM games WHERE played = 1")
                ?? Int.fetchOne(db, sql: "SELECT psn_playtime_s FROM games WHERE played = 1")
            return (p, t)
        }
        #expect(played == 1)                 // the sole member gets the ROM's play data
        #expect(playtime == 4000)
    }

    @Test(.timeLimit(.minutes(1)))
    func multiMemberBundleDropsThePlayDataFromGames() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Two Pack", path: "two.zip", year: 1996,
                                gametime: 5000, favourite: true)
        let entry = try #require(try await store.entries(system: "snes").first)
        let promoter = BatoceraPromoter(db)
        let plan = BatoceraPromoter.Plan.compilation(
            entry: entry,
            bundle: BatoceraPromoter.BundlePromotion(
                title: "Two Pack",
                members: [CompilationMemberDraft(title: "A", igdbID: 21),
                          CompilationMemberDraft(title: "B", igdbID: 22)]))
        _ = try await promoter.promote([plan])

        let played = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE played = 1") ?? -1
        }
        #expect(played == 0)   // > 1 member ⇒ play data dropped from games (kept on the catalogue row)
        // The catalogue row keeps its play time and is linked (In Library) to the first member.
        let reread = try #require(try await store.entries(system: "snes").first)
        #expect(reread.gameTimeSeconds == 5000)
        #expect(reread.promotedGameID != nil)
    }

    // MARK: - The review path: a bundle commit row promotes as a compilation

    @Test(.timeLimit(.minutes(1)))
    func reviewCommitRowWithMembersPromotesAsACompilation() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Sonic Mega Collection", path: "smc.zip", year: 2002, gametime: 0)
        let entry = try #require(try await store.entries(system: "snes").first)
        let promoter = BatoceraPromoter(db)
        let commit = BatoceraImportPresenter.commitClosure(
            promoter: promoter, entryMap: [entry.externalID: entry])
        let row = ImportReviewCommitRow(
            externalID: entry.externalID, platformID: "snes", matchedGameID: nil, igdbID: 900,
            title: "Sonic Mega Collection", releaseYear: 2002,
            bundleTitle: "Sonic Mega Collection",
            bundleMembers: [CompilationMemberDraft(title: "Sonic 1", igdbID: 31),
                            CompilationMemberDraft(title: "Sonic 2", igdbID: 32)])
        _ = try await commit([row])

        let comp = try await compilationRow(db)
        #expect(comp.format == "rom")
        #expect(comp.source == "batocera")
        #expect(comp.members == 2)
        #expect(try await store.entries(system: "snes").first?.promotedGameID != nil)
    }

    // MARK: - D3: every non-bundle promotion is rom/batocera too

    @Test(.timeLimit(.minutes(1)))
    func plainPromotionIsAlwaysRomAndBatocera() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourite(store, name: "Chrono Trigger", path: "ct.zip", year: 1995,
                                gametime: 6000, favourite: false)
        let entry = try #require(try await store.entries(system: "snes").first)
        let promoter = BatoceraPromoter(db)
        _ = try await promoter.promote([.init(
            entry: entry,
            target: .newGame(ImportNewGameSpec(title: "Chrono Trigger", igdbID: 55, releaseYear: 1995)))])

        let (format, source): (String?, String?) = try await db.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT format, source FROM products WHERE source = 'batocera' LIMIT 1")
            return (row?["format"], row?["source"])
        }
        #expect(format == "rom")
        #expect(source == "batocera")
    }
}

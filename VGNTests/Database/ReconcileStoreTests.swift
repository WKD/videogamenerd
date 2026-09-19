import Foundation
import GRDB
import Testing
@testable import VGN

/// Store-side reconcile tests (PLAN §5.1): link / re-link / merge, the copy-merge
/// matrix (owner rules 2026-09-19), invariants, importer idempotency, and undo. No
/// network; each test uses its own in-memory DB.
///
/// Assertions read values into locals first: an inline `try await … == …` inside
/// `#expect` blows up the macro's type-checker.
struct ReconcileStoreTests {

    // MARK: - Setup helpers

    @discardableResult
    private func addGame(
        _ store: LibraryStore, title: String, igdbID: Int64? = nil, played: Bool = false,
        status: String? = nil, tierID: Int64? = nil, rankKey: Int64? = nil, altTitles: String = "",
        userEdited: String = "", year: Int? = nil, summary: String? = nil, myPlaytimeS: Int? = nil,
        ttbNormallyS: Int? = nil, ttbSource: String? = nil
    ) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(
                igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title),
                altTitles: altTitles, summary: summary, year: year, played: played, status: status,
                tierID: tierID, rankKey: rankKey, myPlaytimeS: myPlaytimeS, ttbNormallyS: ttbNormallyS,
                ttbSource: ttbSource, userEdited: userEdited)
            try g.insert(db)
            return g.id!
        }
    }

    @discardableResult
    private func addProduct(
        _ store: LibraryStore, gameID: Int64, platform: String, format: ProductFormat = .physical,
        source: ProductSource = .manual, externalID: String? = nil, edition: String? = nil,
        acquiredAt: Date? = nil, played: Bool = false
    ) async throws -> Int64 {
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, edition, source, external_id, acquired_at)
                VALUES (?, 'single', ?, ?, ?, ?, ?)
                """, arguments: [platform, format.rawValue, edition, source.rawValue, externalID, acquiredAt])
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gameID])
            try db.execute(sql: """
                INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, ?, ?)
                ON CONFLICT(game_id, platform_id) DO UPDATE SET played = MAX(played, excluded.played)
                """, arguments: [gameID, platform, played])
            return pid
        }
    }

    private func game(_ store: LibraryStore, _ id: Int64) async throws -> GameRecord? {
        try await store.dbReader.read { try GameRecord.fetchOne($0, key: id) }
    }
    private func copyCount(_ store: LibraryStore, _ id: Int64) async throws -> Int {
        let cs = try await store.dbReader.read { try LibraryStore.copies(of: id, $0) }
        return cs.count
    }
    private func firstCopy(_ store: LibraryStore, _ id: Int64) async throws -> ReconcileCopy? {
        let cs = try await store.dbReader.read { try LibraryStore.copies(of: id, $0) }
        return cs.first
    }
    private func platformSlugs(_ store: LibraryStore, _ id: Int64) async throws -> [String] {
        try await store.dbReader.read { db in
            try String.fetchAll(db, sql:
                "SELECT platform_id FROM game_platforms WHERE game_id = ? ORDER BY platform_id", arguments: [id])
        }
    }
    private func exists(_ store: LibraryStore, _ id: Int64) async throws -> Bool {
        try await store.dbReader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [id]) ?? false
        }
    }
    private func invariantsHold(_ store: LibraryStore) async throws -> Bool {
        let snap = try await store.dbReader.read { try RankingStore.loadSnapshot($0) }
        return Consistency.checkInvariants(snap).isEmpty
    }
    private func scalarCount(_ store: LibraryStore, _ sql: String, _ args: StatementArguments = StatementArguments()) async throws -> Int {
        try await store.dbReader.read { db in try Int.fetchOne(db, sql: sql, arguments: args) ?? 0 }
    }

    private func copy(_ productID: Int64, _ platform: String, _ format: ProductFormat, _ source: ProductSource,
                      _ ext: String?, compilation: Bool = false) -> ReconcileCopy {
        ReconcileCopy(productID: productID, platformID: platform, format: format, source: source,
                      externalID: ext, edition: nil, region: nil, acquiredAt: nil, psnEntitlement: nil,
                      isCompilation: compilation)
    }

    // MARK: - Pure copy-merge planner (owner rules 1–3)

    @Test func planKeepsDifferentPlatformOrFormat() {
        let sc = copy(1, "mac", .digital, .gog, "g1")
        let target = [copy(9, "pc", .physical, .manual, nil)]
        #expect(MergePlanner.decide(sc, against: target).effectiveOutcome == .keep)
    }

    @Test func planCollapsesIdenticalImportedCopySilently() {
        let sc = copy(1, "ps3", .physical, .delicious, "abc")
        let tc = copy(2, "ps3", .physical, .delicious, "abc")
        #expect(MergePlanner.decide(sc, against: [tc]).outcome == .collapse(into: 2, keepBothAllowed: false))
    }

    @Test func planCollapsesPhysicalDifferentSourceWithToggle() {
        let sc = copy(1, "ps3", .physical, .delicious, "d1")
        let tc = copy(2, "ps3", .physical, .photo, nil)
        var d = MergePlanner.decide(sc, against: [tc])
        #expect(d.outcome == .collapse(into: 2, keepBothAllowed: true))
        d.keepBoth = true
        #expect(d.effectiveOutcome == .keep)
    }

    @Test func planKeepsDigitalDifferentStore() {
        let sc = copy(1, "pc", .digital, .gog, "g1")
        let tc = copy(2, "pc", .digital, .manual, nil)
        #expect(MergePlanner.decide(sc, against: [tc]).effectiveOutcome == .keep)
    }

    @Test func planKeepsCompilationMembership() {
        let sc = copy(1, "ps3", .physical, .manual, nil, compilation: true)
        let tc = copy(2, "ps3", .physical, .photo, nil)
        #expect(MergePlanner.decide(sc, against: [tc]).outcome == .keep)
    }

    // MARK: - Link

    @Test func linkSetsIGDBAndAdoptsTitlePushingOldToAlt() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "Cérébrale Académie")
        try await addProduct(store, gameID: id, platform: "snes")

        _ = try await store.linkGameToIGDB(gameID: id, igdbID: 500, igdbTitle: "Big Brain Academy: Wii Degree")
        let g = try #require(try await game(store, id))
        #expect(g.igdbID == 500)
        #expect(g.title == "Big Brain Academy: Wii Degree")
        let alts = g.altTitles.split(separator: "\n").map(String.init)
        #expect(alts.contains("Cérébrale Académie"))
    }

    @Test func linkKeepsUserEditedTitle() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "My Custom Title", userEdited: "title")
        try await addProduct(store, gameID: id, platform: "pc")
        _ = try await store.linkGameToIGDB(gameID: id, igdbID: 501, igdbTitle: "Official Name")
        let g = try #require(try await game(store, id))
        #expect(g.igdbID == 501)
        #expect(g.title == "My Custom Title")
        #expect(g.altTitles.isEmpty)
    }

    @Test func linkClearsNonUserCoverButKeepsUserCover() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "A")
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET cover_file = 'libretro.png' WHERE id = ?", arguments: [a])
        }
        _ = try await store.linkGameToIGDB(gameID: a, igdbID: 601, igdbTitle: nil)
        let coverA = try await game(store, a)?.coverFile
        #expect(coverA == nil)

        let b = try await addGame(store, title: "B", userEdited: "cover")
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET cover_file = 'mine.png' WHERE id = ?", arguments: [b])
        }
        _ = try await store.linkGameToIGDB(gameID: b, igdbID: 602, igdbTitle: nil)
        let coverB = try await game(store, b)?.coverFile
        #expect(coverB == "mine.png")
    }

    @Test func linkLeavesPlayedTierRankAndCopiesUntouched() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "Game", played: true, status: "finished",
                                   tierID: 1, rankKey: 1000, myPlaytimeS: 3600)
        try await addProduct(store, gameID: id, platform: "ps4", played: true)
        _ = try await store.linkGameToIGDB(gameID: id, igdbID: 700, igdbTitle: "Game HD")
        let g = try #require(try await game(store, id))
        #expect(g.played)
        #expect(g.status == "finished")
        #expect(g.tierID == 1)
        #expect(g.rankKey == 1000)
        #expect(g.myPlaytimeS == 3600)
        let copies = try await copyCount(store, id)
        #expect(copies == 1)
    }

    @Test func linkThrowsWhenTargetAlreadyLinked() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "A", igdbID: 42)
        try await addProduct(store, gameID: a, platform: "pc")
        let b = try await addGame(store, title: "B")
        try await addProduct(store, gameID: b, platform: "pc")
        await #expect(throws: ReconcileError.alreadyLinked(existingGameID: a)) {
            _ = try await store.linkGameToIGDB(gameID: b, igdbID: 42, igdbTitle: nil)
        }
    }

    // MARK: - Re-link (clearing rules)

    @Test func relinkClearsNonUserMetadataAndSetsNewID() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "Wrong Edition", igdbID: 10, year: 1999,
                                   summary: "stale", ttbNormallyS: 3600, ttbSource: "igdb")
        try await addProduct(store, gameID: id, platform: "pc")
        try await store.dbWriter.write { db in
            try LibraryStore.setGenres(["Action"], gameID: id, db: db)
            try db.execute(sql: "UPDATE games SET igdb_rating = 80 WHERE id = ?", arguments: [id])
        }
        _ = try await store.relinkGameInPlace(gameID: id, igdbID: 20, igdbTitle: "Right Game")
        let g = try #require(try await game(store, id))
        #expect(g.igdbID == 20)
        #expect(g.year == nil)
        #expect(g.summary == nil)
        #expect(g.ttbNormallyS == nil)
        #expect(g.ttbSource == nil)
        #expect(g.igdbRating == nil)
        let genreCount = try await scalarCount(store, "SELECT COUNT(*) FROM game_genres WHERE game_id = ?", [id])
        #expect(genreCount == 0)
    }

    @Test func relinkKeepsUserEditedFields() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "T", igdbID: 10, userEdited: "summary,year",
                                   year: 2001, summary: "mine")
        try await addProduct(store, gameID: id, platform: "pc")
        _ = try await store.relinkGameInPlace(gameID: id, igdbID: 30, igdbTitle: "T")
        let g = try #require(try await game(store, id))
        #expect(g.year == 2001)
        #expect(g.summary == "mine")
    }

    // MARK: - Merge matrix (execution)

    @Test func mergeKeepsDifferentPlatformCopies() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        try await addProduct(store, gameID: target, platform: "pc", format: .physical, source: .manual)
        let source = try await addGame(store, title: "Game (Mac)")
        try await addProduct(store, gameID: source, platform: "ps2", format: .physical, source: .photo)

        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)

        let gone = try await exists(store, source)
        let copies = try await copyCount(store, target)
        let platforms = try await platformSlugs(store, target)
        let ok = try await invariantsHold(store)
        #expect(!gone)
        #expect(copies == 2)
        #expect(platforms == ["pc", "ps2"])
        #expect(ok)
    }

    @Test func mergeCollapsesPhysicalDifferentSourceAndEnriches() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try await addProduct(store, gameID: target, platform: "ps3", format: .physical, source: .photo)
        let source = try await addGame(store, title: "Game")
        try await addProduct(store, gameID: source, platform: "ps3", format: .physical, source: .delicious,
                             externalID: "del1", edition: "Limited", acquiredAt: old)

        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)

        let copies = try await copyCount(store, target)
        let c = try await firstCopy(store, target)
        let ok = try await invariantsHold(store)
        #expect(copies == 1)
        #expect(c?.edition == "Limited")
        #expect(c?.acquiredAt == old)
        #expect(c?.externalID == "del1")
        #expect(ok)
    }

    @Test func mergeKeepsBothWhenOverridden() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        try await addProduct(store, gameID: target, platform: "ps3", format: .physical, source: .photo)
        let source = try await addGame(store, title: "Game")
        try await addProduct(store, gameID: source, platform: "ps3", format: .physical, source: .delicious,
                             externalID: "del1")
        var inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        inputs.decisions = inputs.decisions.map { var d = $0; d.keepBoth = true; return d }
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        let copies = try await copyCount(store, target)
        #expect(copies == 2)
    }

    @Test func mergeKeepsDigitalDifferentStore() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        try await addProduct(store, gameID: target, platform: "pc", format: .digital, source: .manual)
        let source = try await addGame(store, title: "Game")
        try await addProduct(store, gameID: source, platform: "pc", format: .digital, source: .gog, externalID: "g1")
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        let copies = try await copyCount(store, target)
        #expect(copies == 2)
    }

    @Test func mergeMixedCase() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        try await addProduct(store, gameID: target, platform: "pc", format: .physical, source: .manual)
        try await addProduct(store, gameID: target, platform: "ps3", format: .physical, source: .photo)
        let source = try await addGame(store, title: "Game")
        // A different-platform digital copy (kept) + a same-platform physical copy (collapsed).
        try await addProduct(store, gameID: source, platform: "ps4", format: .digital, source: .gog, externalID: "g1")
        try await addProduct(store, gameID: source, platform: "ps3", format: .physical, source: .delicious, externalID: "d1")

        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        let copies = try await copyCount(store, target)
        let platforms = try await platformSlugs(store, target)
        let ok = try await invariantsHold(store)
        #expect(copies == 3)
        #expect(platforms == ["pc", "ps3", "ps4"])
        #expect(ok)
    }

    // MARK: - Game-detail precedence

    @Test func mergePlayedIsEitherAndPrefersTargetScalars() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42, played: false)
        try await addProduct(store, gameID: target, platform: "pc")
        let source = try await addGame(store, title: "Game", played: true, status: "finished", myPlaytimeS: 7200)
        try await addProduct(store, gameID: source, platform: "pc", format: .digital, source: .gog, externalID: "g1")
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        let g = try #require(try await game(store, target))
        #expect(g.played)
        #expect(g.status == "finished")
        #expect(g.myPlaytimeS == 7200)
    }

    @Test func mergeTierOnlySourceRankedCarriesOver() async throws {
        let store = try await TestDB.makeStore()
        let t1 = try await addGame(store, title: "A", igdbID: 1)
        try await addProduct(store, gameID: t1, platform: "pc")
        let s1 = try await addGame(store, title: "A", played: true, tierID: 2, rankKey: 500)
        try await addProduct(store, gameID: s1, platform: "ps2")
        let i1 = try await store.mergeInputs(sourceGameID: s1, targetGameID: t1)
        _ = try await store.mergeGame(sourceGameID: s1, into: t1, decisions: i1.decisions)
        let g1 = try #require(try await game(store, t1))
        #expect(g1.tierID == 2)
        #expect(g1.rankKey == 500)
        #expect(g1.played)
        let ok = try await invariantsHold(store)
        #expect(ok)
    }

    @Test func mergeTierBothRankedKeepsTargets() async throws {
        let store = try await TestDB.makeStore()
        let t2 = try await addGame(store, title: "B", igdbID: 2, played: true, tierID: 1, rankKey: 100)
        try await addProduct(store, gameID: t2, platform: "pc")
        let s2 = try await addGame(store, title: "B", played: true, tierID: 3, rankKey: 900)
        try await addProduct(store, gameID: s2, platform: "ps2")
        let i2 = try await store.mergeInputs(sourceGameID: s2, targetGameID: t2)
        #expect(i2.bothRanked)
        _ = try await store.mergeGame(sourceGameID: s2, into: t2, decisions: i2.decisions)
        let g2 = try #require(try await game(store, t2))
        #expect(g2.tierID == 1)
        #expect(g2.rankKey == 100)
    }

    // MARK: - Re-pointing history + idempotency

    @Test func mergeRepointsHistoryFeedbackTraitsAndImportTitles() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42, played: true, tierID: 1, rankKey: 100)
        try await addProduct(store, gameID: target, platform: "pc")
        let other = try await addGame(store, title: "Other", played: true, tierID: 1, rankKey: 200)
        try await addProduct(store, gameID: other, platform: "pc")
        let source = try await addGame(store, title: "Game", played: true)
        try await addProduct(store, gameID: source, platform: "ps2")
        try await store.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO comparisons (winner_id, loser_id, context) VALUES (?, ?, 'refine')",
                           arguments: [source, other])
            try db.execute(sql: "INSERT INTO rec_feedback (game_id, action) VALUES (?, 'snooze')", arguments: [source])
            try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (?, 'developer', 'Studio')",
                           arguments: [source])
            try db.execute(sql: """
                INSERT INTO import_titles (source, external_id, name, matched_game_id)
                VALUES ('delicious', 'imp1', 'Game', ?)
                """, arguments: [source])
        }
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)

        let cmp = try await scalarCount(store, "SELECT COUNT(*) FROM comparisons WHERE winner_id = ? AND loser_id = ?", [target, other])
        let fb = try await scalarCount(store, "SELECT COUNT(*) FROM rec_feedback WHERE game_id = ?", [target])
        let tr = try await scalarCount(store, "SELECT COUNT(*) FROM game_traits WHERE game_id = ? AND value = 'Studio'", [target])
        let matched = try await store.dbReader.read { db in
            try Int64.fetchOne(db, sql: "SELECT matched_game_id FROM import_titles WHERE external_id = 'imp1'")
        }
        let ok = try await invariantsHold(store)
        #expect(cmp == 1)
        #expect(fb == 1)
        #expect(tr == 1)
        #expect(matched == target)
        #expect(ok)
    }

    @Test func mergeIsIdempotentForImporterRedetection() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        try await addProduct(store, gameID: target, platform: "ps3", format: .physical, source: .photo)
        let source = try await addGame(store, title: "Game")
        try await addProduct(store, gameID: source, platform: "ps3", format: .physical, source: .delicious, externalID: "del1")
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO import_titles (source, external_id, name, platform, matched_game_id)
                VALUES ('delicious', 'del1', 'Game', 'ps3', ?)
                """, arguments: [source])
        }
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)

        let staging = ImportStagingStore(store.database)
        let owned = try await staging.ownedCopies()
        let hasOwned = owned.contains { $0.igdbID == 42 && $0.platform == "ps3" && $0.format == .physical && $0.gameID == target }
        #expect(hasOwned)
        let matched = try await store.dbReader.read { db in
            try Int64.fetchOne(db, sql: "SELECT matched_game_id FROM import_titles WHERE external_id = 'del1'")
        }
        let hasExt = try await store.dbReader.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM products WHERE source = 'delicious' AND external_id = 'del1')") ?? false
        }
        #expect(matched == target)
        #expect(hasExt)
    }

    // MARK: - Undo

    @Test func linkUndoRestoresGameExactly() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "Cérébrale Académie", year: 2005)
        try await addProduct(store, gameID: id, platform: "snes")
        let before = try #require(try await game(store, id))
        let undo = try await store.linkGameToIGDB(gameID: id, igdbID: 500, igdbTitle: "Big Brain Academy")
        try await store.restoreReconcile(undo)
        let after = try #require(try await game(store, id))
        let copies = try await copyCount(store, id)
        #expect(after.igdbID == before.igdbID)
        #expect(after.title == before.title)
        #expect(after.altTitles == before.altTitles)
        #expect(copies == 1)
    }

    @Test func mergeUndoRestoresBothGamesExactly() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42, played: true, tierID: 1, rankKey: 100)
        try await addProduct(store, gameID: target, platform: "pc", format: .physical, source: .manual)
        let source = try await addGame(store, title: "Game", played: true, tierID: 2, rankKey: 300)
        try await addProduct(store, gameID: source, platform: "ps3", format: .physical, source: .delicious, externalID: "d1")

        let targetBefore = try #require(try await game(store, target))
        let sourceBefore = try #require(try await game(store, source))
        let targetCopiesBefore = try await copyCount(store, target)
        let sourceCopiesBefore = try await copyCount(store, source)

        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        let undo = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        let goneAfterMerge = try await exists(store, source)
        #expect(!goneAfterMerge)

        try await store.restoreReconcile(undo)
        let backAgain = try await exists(store, source)
        let targetAfter = try #require(try await game(store, target))
        let sourceAfter = try #require(try await game(store, source))
        let targetCopiesAfter = try await copyCount(store, target)
        let sourceCopiesAfter = try await copyCount(store, source)
        let ok = try await invariantsHold(store)
        #expect(backAgain)
        #expect(targetAfter.tierID == targetBefore.tierID)
        #expect(targetAfter.rankKey == targetBefore.rankKey)
        #expect(sourceAfter.tierID == sourceBefore.tierID)
        #expect(sourceAfter.rankKey == sourceBefore.rankKey)
        #expect(sourceAfter.igdbID == sourceBefore.igdbID)
        #expect(targetCopiesAfter == targetCopiesBefore)
        #expect(sourceCopiesAfter == sourceCopiesBefore)
        #expect(ok)
    }

    // MARK: - Index read

    // MARK: - Unlinked scope + count

    @Test func unlinkedScopeAndCount() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "Linked", igdbID: 7)
        try await addProduct(store, gameID: a, platform: "pc")
        let b = try await addGame(store, title: "Unlinked One")
        try await addProduct(store, gameID: b, platform: "pc")
        let c = try await addGame(store, title: "Unlinked Two")
        try await addProduct(store, gameID: c, platform: "snes")

        let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .unlinked))
        let ids = Set(rows.map(\.id))
        #expect(ids == [b, c])

        let count = try await store.dbReader.read { try LibraryQuery.fetchUnlinkedCount($0) }
        #expect(count == 2)
    }

    @Test func igdbLinkIndexReportsLinkedGames() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "A", igdbID: 100)
        _ = try await addGame(store, title: "B")
        let index = try await store.igdbLinkIndex()
        #expect(index[100] == a)
        #expect(index.count == 1)
    }
}

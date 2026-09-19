import Foundation
import GRDB
import Testing
@testable import VGN

/// The Batocera promotion review (PLAN §15): candidates are matched to IGDB (a fake matcher),
/// the play-time line is shown, committing runs through ``BatoceraPromoter`` (creating a game +
/// linking the catalogue row), the "adds play time only" duplicate state fires, and a dismiss
/// drops a row from the commit.
@MainActor
@Suite(.serialized)
struct BatoceraReviewFlowTests {

    /// A stub matcher returning one confident IGDB match for every title.
    struct StubMatcher: ImportMatcher {
        let igdbID: Int64
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            ScanMatchOutcome(
                best: ScanMatch(igdbID: igdbID, name: request.title, releaseYear: request.releaseYear,
                                coverImageID: nil, platformSlugs: ["snes"], score: 0.95,
                                matchedName: request.title),
                alternatives: [], bucket: .confident)
        }
    }

    private func seedCandidate(_ store: RomCatalogStore, name: String, path: String,
                               gametime: Int) async throws -> RomCatalogEntry {
        let g = BatoceraGame(system: "snes", relativePath: "./" + path, name: name,
                             releaseYear: 1994, gameTimeSeconds: gametime)
        let e = RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        _ = try await store.syncSystem(system: "snes", entries: try await currentPlus(store, e))
        return try #require(try await store.entries(system: "snes").first { $0.name == name })
    }

    /// Sync must include all existing entries (syncing one at a time marks the others vanished).
    private func currentPlus(_ store: RomCatalogStore, _ e: RomCatalogEntry) async throws -> [RomCatalogEntry] {
        let existing = try await store.entries(system: "snes")
        return existing + [e]
    }

    private func presenter(_ db: AppDatabase, igdbID: Int64 = 111) -> BatoceraImportPresenter {
        BatoceraImportPresenter(
            catalog: RomCatalogStore(db), promoter: BatoceraPromoter(db),
            staging: ImportStagingStore(db), matcher: StubMatcher(igdbID: igdbID),
            platformChoices: ["snes", "pc"])
    }

    @Test(.timeLimit(.minutes(1)))
    func matchesCommitsCreatesGameAndLinksCatalogue() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let entry = try await seedCandidate(store, name: "Super Metroid", path: "sm.zip", gametime: 3600)

        let p = presenter(db)
        p.reviewCandidates()
        await waitUntil { p.reviewModel != nil }
        let model = try #require(p.reviewModel)
        await model.load()

        #expect(model.rows.count == 1)
        let row = try #require(model.rows.first)
        #expect(row.include)                                   // confident → pre-ticked
        #expect(row.proposedMatch?.igdbID == 111)
        #expect(model.rowDetailByID[entry.externalID]?.isEmpty == false)   // play-time line
        #expect(model.rowDetailByID[entry.externalID]?.contains("1 h") == true)

        model.commit()
        await waitUntil { model.committed || model.commitError != nil }
        #expect(model.committed)
        #expect(model.commitError == nil)

        // A game was created and the catalogue row linked to it.
        let reloaded = try #require(try await store.entry(id: entry.id))
        #expect(reloaded.promotedGameID != nil)
        let (played, fmt) = try await db.dbWriter.read { db -> (Int64, String) in
            let gid = reloaded.promotedGameID!
            let played: Int64 = try Int64.fetchOne(db, sql: "SELECT played FROM games WHERE id = ?", arguments: [gid]) ?? -1
            let fmt: String = try String.fetchOne(db, sql: """
                SELECT p.format FROM products p JOIN product_games pg ON pg.product_id = p.id WHERE pg.game_id = ?
                """, arguments: [gid]) ?? ""
            return (played, fmt)
        }
        #expect(played == 1)      // > 5 min
        #expect(fmt == "rom")
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateStateAddsPlayTimeOnly() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)

        // First candidate becomes a library game (igdb 111 + a ROM copy on snes).
        let first = try await seedCandidate(store, name: "Chrono Trigger", path: "ct.zip", gametime: 1000)
        let p1 = presenter(db)
        p1.reviewCandidates()
        await waitUntil { p1.reviewModel != nil }
        let m1 = try #require(p1.reviewModel); await m1.load()
        m1.commit()
        await waitUntil { m1.committed }
        let firstGameID = try #require(try await store.entry(id: first.id)).promotedGameID
        let romCopiesBefore = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE format = 'rom'") ?? -1
        }

        // A NEW catalogue entry the matcher also ties to igdb 111 → duplicate: adds play time
        // only, no second ROM copy.
        let dup = try await seedCandidate(store, name: "Chrono Trigger EU", path: "ct-eu.zip", gametime: 7200)
        let p2 = presenter(db)
        p2.reviewCandidates()
        await waitUntil { p2.reviewModel != nil }
        let m2 = try #require(p2.reviewModel); await m2.load()
        // Only the still-unpromoted dup is a candidate now.
        let dupRow = try #require(m2.rows.first { $0.externalID == dup.externalID })
        #expect(dupRow.duplicateNote == "Already in your library — adds play time only")

        m2.commit()
        await waitUntil { m2.committed || m2.commitError != nil }
        #expect(m2.committed)
        let romCopiesAfter = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE format = 'rom'") ?? -1
        }
        #expect(romCopiesAfter == romCopiesBefore)                        // no second copy
        #expect(try await store.entry(id: dup.id)?.promotedGameID == firstGameID)  // linked to the same game
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissedRowIsNotCommitted() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let a = try await seedCandidate(store, name: "Keep Me", path: "keep.zip", gametime: 1000)
        _ = try await seedCandidate(store, name: "Drop Me", path: "drop.zip", gametime: 1000)

        let p = presenter(db)
        p.reviewCandidates()
        await waitUntil { p.reviewModel != nil }
        let model = try #require(p.reviewModel); await model.load()
        #expect(model.rows.count == 2)

        let drop = try #require(model.rows.first { $0.sourceTitle == "Drop Me" })
        model.ignore(drop.externalID)
        #expect(model.committableCount == 1)

        model.commit()
        await waitUntil { model.committed }
        // Only "Keep Me" was promoted.
        #expect(try await store.entry(id: a.id)?.promotedGameID != nil)
        let dropped = try #require(try await store.entries(system: "snes").first { $0.name == "Drop Me" })
        #expect(dropped.promotedGameID == nil)
    }
}

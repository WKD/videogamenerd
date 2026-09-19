import Foundation
import GRDB
import Testing
@testable import VGN

/// The after-sync auto-add wiring on ``BatoceraImportPresenter`` (PLAN §15): when the setting
/// is on, a confident favourite is promoted, a "N favourites added · Undo" banner appears and
/// an undo step is registered; when it is off, the quiet "N ready to review" banner shows
/// instead. `UndoManager.undo()` hangs headless, so we assert registration and call the inverse
/// (`performAutoAddUndo`) directly.
@MainActor
@Suite(.serialized)
struct BatoceraAutoAddPresenterTests {

    private struct StubMatcher: ImportMatcher {
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            ScanMatchOutcome(
                best: ScanMatch(igdbID: 321, name: request.title, releaseYear: request.releaseYear,
                                coverImageID: nil, platformSlugs: ["snes"], score: 0.95,
                                matchedName: request.title),
                alternatives: [], bucket: .confident)
        }
    }

    private func seedFavourite(_ store: RomCatalogStore, name: String, path: String) async throws {
        let g = BatoceraGame(system: "snes", relativePath: "./" + path, name: name,
                             releaseYear: 1994, gameTimeSeconds: 0, isFavorite: true)
        let existing = try await store.entries(system: "snes")
        let e = RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        _ = try await store.syncSystem(system: "snes", entries: existing + [e])
    }

    private func presenter(_ db: AppDatabase, vm: LibraryViewModel,
                           matcher: any ImportMatcher = StubMatcher(), autoAdd: Bool) -> BatoceraImportPresenter {
        let p = BatoceraImportPresenter(
            catalog: RomCatalogStore(db), promoter: BatoceraPromoter(db),
            staging: ImportStagingStore(db), matcher: matcher, platformChoices: ["snes"])
        p.library = vm
        p.autoAddEnabled = { autoAdd }
        return p
    }

    @Test(.timeLimit(.minutes(1)))
    func autoAddPromotesShowsBannerAndRegistersUndo() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: LibraryStore(db)))
        vm.undoManager = UndoManager()
        try await seedFavourite(store, name: "Zelda", path: "z.zip")

        let p = presenter(db, vm: vm, autoAdd: true)
        p.handleSyncFinished(BatoceraSyncSummary(candidateCount: 1))

        await waitUntil { vm.banner != nil }
        let banner = try #require(vm.banner)
        #expect(banner.message.contains("added from Batocera"))
        #expect(banner.actionTitle == "Undo")
        #expect(vm.undoManager?.canUndo == true)               // an undo step is registered

        // The favourite is now in the library.
        let promoted = try await store.entries(system: "snes").filter { $0.promotedGameID != nil }
        #expect(promoted.count == 1)
        let gameID = try #require(promoted.first?.promotedGameID)

        // Call the inverse directly (UndoManager.undo() hangs headless).
        await p.performAutoAddUndo(promoted)
        let gone = try await db.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [gameID]) ?? false
        }
        #expect(gone)
        #expect(try await store.entries(system: "snes").first?.promotedGameID == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func withAutoAddOffTheReviewBannerShows() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: LibraryStore(db)))
        let p = presenter(db, vm: vm, autoAdd: false)
        p.handleSyncFinished(BatoceraSyncSummary(candidateCount: 3))
        await waitUntil { vm.banner != nil }
        let banner = try #require(vm.banner)
        #expect(banner.message.contains("ready to review"))
        #expect(banner.actionTitle == "Review…")
    }
}

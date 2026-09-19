import Foundation
import GRDB
import Testing
@testable import VGN

/// Presenter-level reconcile flow (PLAN §5.1): opening the sheet, routing a chosen
/// target to link vs merge, performing the store write, and registering undo. Touches
/// GRDB on the main actor → serialized. No network (fake searcher).
@MainActor
@Suite(.serialized)
struct ReconcilePresenterTests {

    private func makeResult(_ id: Int64, _ name: String) -> IGDBSearchResult {
        IGDBSearchResult(id: id, name: name, releaseYear: 2010, coverImageID: nil,
                         platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                         genres: [], alternativeNames: [], gameType: .mainGame)
    }

    @discardableResult
    private func addGame(_ store: LibraryStore, title: String, igdbID: Int64? = nil) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title))
            try g.insert(db)
            let id = g.id!
            try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('snes','single','physical','manual')")
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)", arguments: [pid, id])
            try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, 'snes', 0)", arguments: [id])
            return id
        }
    }

    private func igdb(_ store: LibraryStore, _ id: Int64) async throws -> Int64? {
        try await store.dbReader.read { try Int64.fetchOne($0, sql: "SELECT igdb_id FROM games WHERE id = ?", arguments: [id]) }
    }
    private func exists(_ store: LibraryStore, _ id: Int64) async throws -> Bool {
        try await store.dbReader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [id]) ?? false
        }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
    }

    @Test func presentThenLinkRegistersUndo() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addGame(store, title: "Old Title")
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        let um = UndoManager(); vm.undoManager = um

        let searcher = FakeCatalog()
        await searcher.configure(results: [makeResult(555, "New Title")])
        let presenter = IGDBLinkPresenter(store: store, vm: vm, searcher: searcher, sleep: { _ in })

        presenter.present(for: id)
        await settle { presenter.link != nil }
        let model = try #require(presenter.link)
        model.start()                                   // the sheet's .task would do this
        await settle { model.phase == .results }
        model.chooseSelected()

        await settle { presenter.link == nil }
        var linked: Int64?
        for _ in 0..<1000 {
            linked = try await igdb(store, id)
            if linked == 555 { break }
            await Task.yield()
        }
        #expect(linked == 555)
        #expect(um.canUndo)
    }

    @Test func presentThenChooseExistingOpensMerge() async throws {
        let store = try await TestDB.makeStore()
        let target = try await addGame(store, title: "Game", igdbID: 42)
        let source = try await addGame(store, title: "Game (weird edition)")
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.undoManager = UndoManager()

        let searcher = FakeCatalog()
        await searcher.configure(results: [makeResult(42, "Game")])   // 42 is already the target
        let presenter = IGDBLinkPresenter(store: store, vm: vm, searcher: searcher, sleep: { _ in })

        presenter.present(for: source)
        await settle { presenter.link != nil }
        let model = try #require(presenter.link)
        model.start()
        await settle { model.phase == .results }
        #expect(model.results.first?.alreadyInLibrary == true)
        model.chooseSelected()

        await settle { presenter.merge != nil }
        let merge = try #require(presenter.merge)
        #expect(presenter.link == nil)

        merge.confirm()
        var sourceGone = false
        for _ in 0..<1000 {
            let e = try await exists(store, source)
            if !e { sourceGone = true; break }
            await Task.yield()
        }
        let targetStays = try await exists(store, target)
        #expect(sourceGone)
        #expect(targetStays)
        let targetIGDB = try await igdb(store, target)
        #expect(targetIGDB == 42)
    }
}

/// The merge confirmation model's grouping + keep-both override (pure).
struct IGDBMergeModelTests {
    @MainActor
    @Test func groupsAndTogglesKeepBoth() {
        let sourceCopy = ReconcileCopy(productID: 5, platformID: "ps3", format: .physical, source: .delicious,
                                       externalID: "d1", edition: nil, region: nil, acquiredAt: nil,
                                       psnEntitlement: nil, isCompilation: false)
        let targetCopy = ReconcileCopy(productID: 9, platformID: "ps3", format: .physical, source: .photo,
                                       externalID: nil, edition: nil, region: nil, acquiredAt: nil,
                                       psnEntitlement: nil, isCompilation: false)
        let decisions = MergePlanner.plan(source: [sourceCopy], target: [targetCopy])
        let inputs = MergeInputs(sourceGameID: 1, targetGameID: 2, sourceTitle: "A", targetTitle: "B",
                                 sourceCopies: [sourceCopy], targetCopies: [targetCopy],
                                 decisions: decisions, detailLines: ["Played"], bothRanked: false)
        let model = IGDBMergeModel(inputs: inputs)
        #expect(model.collapsingCopies.count == 1)
        #expect(model.movingCopies.isEmpty)
        #expect(model.keepBothAllowed(model.collapsingCopies[0]))

        model.setKeepBoth(true, productID: 5)
        #expect(model.decisions[0].keepBoth)
        #expect(model.decisions[0].effectiveOutcome == .keep)
    }
}

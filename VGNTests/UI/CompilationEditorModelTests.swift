import Foundation
import Testing
@testable import VGN

/// Compilation editor model logic (PLAN §5.1/§8), driven against a live in-memory
/// ``LibraryStore`` (which is the real ``CompilationWriting``) plus a fake catalog.
/// `@MainActor` + serialized + hard time limit per the repo's GRDB test rules.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CompilationEditorModelTests {

    private func makeCompilation(_ store: LibraryStore, count: Int = 3) async throws -> Int64 {
        let members = (0..<count).map { i in
            CompilationMemberDraft(title: "Game \(i)", igdbID: Int64(2000 + i), position: i)
        }
        let (productID, _) = try await store.addCompilation(
            product: ProductDraft(title: "A Collection", platformID: "ps3", igdbID: 900),
            members: members)
        return productID
    }

    private func makeModel(
        _ store: LibraryStore, productID: Int64, catalog: FakeCatalog = FakeCatalog()
    ) -> CompilationEditorModel {
        CompilationEditorModel(
            productID: productID, writer: store, catalog: catalog,
            localSearch: { text in
                let rows = (try? await store.gamesOnce(
                    filter: LibraryFilter(searchText: text, scope: .all))) ?? []
                return rows.map(QuickAddLibraryMatch.init(from:))
            },
            platforms: [PlatformInfo(id: "ps3", name: "PS3", short: "PS3", manufacturer: "Sony",
                                     group: "Sony", kind: .console, generation: 7, sort: 0),
                        PlatformInfo(id: "ps2", name: "PS2", short: "PS2", manufacturer: "Sony",
                                     group: "Sony", kind: .console, generation: 6, sort: 1)],
            debounce: .milliseconds(1))
    }

    // MARK: - Load

    @Test func loadPopulatesFields() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        #expect(!model.isLoading)
        #expect(model.titleText == "A Collection")
        #expect(model.platformID == "ps3")
        #expect(model.members.count == 3)
        #expect(model.isCompilation)
    }

    // MARK: - Pure builders

    @Test func buildResultsFlagsExistingMembers() {
        let members = [CompilationMemberInfo(gameID: 10, title: "Ico", position: 0)]
        let catalog = [makeSearchResult(id: 1, name: "Ico"), makeSearchResult(id: 2, name: "SotC")]
        let local = [makeLibraryMatch(id: 10, title: "Ico"), makeLibraryMatch(id: 11, title: "Journey")]
        let rows = CompilationEditorModel.buildResults(
            catalog: catalog, local: local, currentMembers: members)
        // Ico (already a member) is flagged; SotC is not.
        #expect(rows.first { $0.title == "Ico" }?.alreadyMember == true)
        #expect(rows.first { $0.title == "SotC" }?.alreadyMember == false)
        // Journey (local only) appears as a reuse row with a gameID.
        #expect(rows.first { $0.title == "Journey" }?.gameID == 11)
    }

    @Test func computeBundleDiffFindsMissing() {
        let members = [CompilationMemberInfo(gameID: 1, title: "Metal Gear Solid", position: 0)]
        let bundle = [makeSearchResult(id: 1, name: "Metal Gear Solid"),
                      makeSearchResult(id: 2, name: "Metal Gear Solid 2")]
        let diff = CompilationEditorModel.computeBundleDiff(bundleMembers: bundle, currentMembers: members)
        #expect(diff.toAdd.count == 1)
        #expect(diff.toAdd.first?.title == "Metal Gear Solid 2")
        #expect(diff.alreadyPresent == ["Metal Gear Solid"])
    }

    // MARK: - Add member (catalog + reuse)

    @Test func addCatalogMemberInsertsGame() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        await model.addMember(CompilationSearchResult(
            id: "igdb:77", title: "New Game", year: 2010, igdbID: 77, gameID: nil,
            source: .catalog, alreadyMember: false))
        #expect(model.members.count == 4)
        #expect(model.members.last?.title == "New Game")
    }

    @Test func addLocalMemberReusesExistingGame() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        // A manual (no IGDB) library game, played.
        let existing = try await store.addGame(
            GameDraft(title: "Manual Game", platformIDs: ["ps2"], owned: true, played: true))
        let model = makeModel(store, productID: productID)
        await model.load()
        await model.addMember(CompilationSearchResult(
            id: "local:\(existing.gameID)", title: "Manual Game", year: nil, igdbID: nil,
            gameID: existing.gameID, source: .local, alreadyMember: false))
        #expect(model.members.contains { $0.gameID == existing.gameID })
        // Reused, still played.
        let detail = try #require(try await store.gameDetail(id: existing.gameID))
        #expect(detail.played)
        #expect(detail.isCompilationMember)
    }

    // MARK: - Remove member with orphan prompt

    @Test func removeMemberRaisesOrphanThenConfirms() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        let victim = model.members[1]

        // Never-played, not-otherwise-owned → orphan prompt, no change.
        await model.removeMember(victim.gameID)
        #expect(model.orphanConfirm?.gameID == victim.gameID)
        #expect(model.members.count == 3)

        await model.confirmOrphanRemoval()
        #expect(model.orphanConfirm == nil)
        #expect(model.members.count == 2)
    }

    @Test func removeOwnedElsewhereMemberDoesNotPrompt() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        let member = model.members[0]
        // Own it standalone elsewhere → no orphan.
        _ = try await store.addCopy(gameID: member.gameID, platformID: "ps2")
        await model.removeMember(member.gameID)
        #expect(model.orphanConfirm == nil)
        #expect(model.members.count == 2)
    }

    // MARK: - Reorder

    @Test func moveReordersMembers() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        let originalFirst = model.members[0].gameID
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)  // move first to end
        // Allow the async persist to complete, then reload from the store.
        try await Task.sleep(for: .milliseconds(50))
        let members = try await store.compilationMembers(productID: productID)
        #expect(members.last?.gameID == originalFirst)
    }

    // MARK: - Fill from bundle

    @Test func fillFromBundleAddsMissing() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let catalog = FakeCatalog()
        // The bundle has the 3 existing (by title) + 1 new.
        await catalog.configure(members: [
            makeSearchResult(id: 2000, name: "Game 0"),
            makeSearchResult(id: 2001, name: "Game 1"),
            makeSearchResult(id: 2002, name: "Game 2"),
            makeSearchResult(id: 3000, name: "Bonus Game"),
        ])
        let model = makeModel(store, productID: productID, catalog: catalog)
        await model.load()
        await model.fillFromBundle()
        #expect(model.bundleDiff?.toAdd.count == 1)
        await model.applyBundleDiff()
        #expect(model.members.count == 4)
        #expect(model.members.contains { $0.title == "Bonus Game" })
    }

    // MARK: - Convert single ↔ compilation via the editor

    @Test func addingMemberConvertsSingleToCompilation() async throws {
        let store = try await TestDB.makeStore()
        let single = try await store.addGame(
            GameDraft(title: "Solo", igdbID: 500, platformIDs: ["ps3"], owned: true))
        let detail = try #require(try await store.gameDetail(id: single.gameID))
        let productID = try #require(detail.copies.first?.productID)
        let model = makeModel(store, productID: productID)
        await model.load()
        #expect(!model.isCompilation)
        await model.addMember(CompilationSearchResult(
            id: "igdb:501", title: "Sequel", year: nil, igdbID: 501, gameID: nil,
            source: .catalog, alreadyMember: false))
        #expect(model.isCompilation)
        let product = try #require(try await store.compilationProduct(id: productID))
        #expect(product.kind == .compilation)
    }

    // MARK: - Save details

    @Test func saveDetailsPersists() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        model.titleText = "Renamed Collection"
        model.platformID = "ps2"
        model.format = .digital
        model.editionText = "GOTY"
        await model.saveDetails()
        let product = try #require(try await store.compilationProduct(id: productID))
        #expect(product.title == "Renamed Collection")
        #expect(product.platformID == "ps2")
        #expect(product.format == .digital)
        #expect(product.edition == "GOTY")
    }

    // MARK: - Remove from compilation + undo (wire-up; store side is CopyRemovalUndoTests)

    /// A compilation of PLAYED members, so removing one is a clean `.ok` (the member
    /// survives — it is still played) rather than an orphan prompt.
    private func makePlayedCompilation(_ store: LibraryStore) async throws -> Int64 {
        let members = (0..<3).map { i in
            CompilationMemberDraft(title: "Played \(i)", igdbID: Int64(3100 + i), played: true, position: i)
        }
        let (productID, _) = try await store.addCompilation(
            product: ProductDraft(title: "Played Collection", platformID: "ps3", igdbID: 910),
            members: members)
        return productID
    }

    @Test func removeMemberRegistersOneUndoStep() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makePlayedCompilation(store)
        let model = makeModel(store, productID: productID)
        let um = UndoManager()
        model.undoManager = um
        await model.load()
        let target = model.members[1].gameID

        await model.removeMember(target)

        #expect(model.members.count == 2)
        #expect(!model.members.contains { $0.gameID == target })
        #expect(um.canUndo)
        #expect(um.undoActionName == "Remove from Compilation")
    }

    @Test func undoRemoveMemberRestoresTheMember() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makePlayedCompilation(store)
        let model = makeModel(store, productID: productID)
        await model.load()
        let target = model.members[1].gameID

        // Drive the store's capturing removal to get the undo snapshot, then the model's
        // undo path (restoreReconcile + reload) directly — UndoManager.undo() hangs headless.
        let (outcome, undo) = try await store.removeCompilationMemberCapturingUndo(
            productID: productID, gameID: target)
        guard case .ok = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        await model.load()
        #expect(!model.members.contains { $0.gameID == target })

        await model.undoRemoveMember(try #require(undo))
        #expect(model.members.contains { $0.gameID == target })
        #expect(model.members.count == 3)
    }
}

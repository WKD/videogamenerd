import Foundation
import Testing
@testable import VGN

/// "Holds up today?" through the wired view model + ``LibraryActions`` over an in-memory store
/// (PLAN §7b): one undo step named "Holds Up Today?", its inverse applied directly
/// (`UndoManager.undo()` hangs headless), unplayed games refused with a banner.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HoldsUpActionTests {

    private func makeWired(_ store: LibraryStore) -> (LibraryViewModel, LibraryActions) {
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: store))
        let actions = LibraryActions(store: store, vm: vm)
        actions.install()
        vm.undoManager = UndoManager()
        return (vm, actions)
    }

    private func mark(_ store: LibraryStore, _ id: Int64) async throws -> HoldsUp? {
        try await store.gameDetail(id: id)?.holdsUp
    }

    @Test func oneUndoStepAndItsExactInverse() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let b = try await store.addGame(GameDraft(title: "B", platformIDs: ["ps4"], owned: true, played: true)).gameID
        try await store.setHoldsUp(.holdsUp, for: [a])
        let (vm, actions) = makeWired(store)

        await actions.setHoldsUp(ids: [a, b], value: .tooArchaic)
        #expect(try await mark(store, a) == .tooArchaic)
        #expect(try await mark(store, b) == .tooArchaic)
        let undo = try #require(vm.undoManager)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == LibraryActions.holdsUpUndoName)
        #expect(LibraryActions.holdsUpUndoName == "Holds Up Today?")

        // The inverse, applied directly: exactly the prior marks come back.
        await actions.restoreHoldsUp([a: .holdsUp, b: nil])
        #expect(try await mark(store, a) == .holdsUp)
        #expect(try await mark(store, b) == nil)
    }

    @Test func unplayedGamesAreSkippedWithABanner() async throws {
        let store = try await UIWiring.makeStore()
        let p = try await store.addGame(GameDraft(title: "P", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let u = try await store.addGame(GameDraft(title: "U", platformIDs: ["ps4"], owned: true)).gameID
        let (vm, actions) = makeWired(store)

        await actions.setHoldsUp(ids: [p, u], value: .ofItsTime)
        #expect(try await mark(store, p) == .ofItsTime)
        #expect(try await mark(store, u) == nil)
        #expect(vm.banner?.kind == .warning)
        #expect(vm.banner?.message == LibraryActions.holdsUpSkippedBanner(1))
    }

    @Test func noUndoStepWhenNothingChanged() async throws {
        let store = try await UIWiring.makeStore()
        let u = try await store.addGame(GameDraft(title: "U", platformIDs: ["ps4"], owned: true)).gameID
        let (vm, actions) = makeWired(store)
        await actions.setHoldsUp(ids: [u], value: .holdsUp)
        #expect(vm.undoManager?.canUndo == false)
    }
}

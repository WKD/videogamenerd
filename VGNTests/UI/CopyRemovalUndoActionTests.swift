import Foundation
import Testing
@testable import VGN

/// The un-own / remove-copy action registers a "Remove Copy" undo step (owner request
/// 2026-09-20). `@MainActor` + serialized (GRDB async I/O on the main actor deadlocks in
/// parallel). `UndoManager.undo()` hangs headless, so the restore itself is covered at the
/// store level (`CopyRemovalUndoTests`); here we assert the step is registered.
@MainActor
@Suite(.serialized)
struct CopyRemovalUndoActionTests {

    private func makeWired(_ store: LibraryStore) -> (vm: LibraryViewModel, actions: LibraryActions) {
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: store))
        let actions = LibraryActions(store: store, vm: vm)
        actions.install()
        vm.undoManager = UndoManager()
        return (vm, actions)
    }

    @Test(.timeLimit(.minutes(1)))
    func unOwningACopyRegistersAnUndoStep() async throws {
        let store = try await UIWiring.makeStore()
        // A single owned copy on a PLAYED game → un-owning removes that one copy directly
        // (no picker) and does not orphan it (still played), so the removal registers an undo.
        let id = try await store.addGame(GameDraft(
            title: "Hades", platformIDs: ["ps5"], owned: true, played: true, format: .digital)).gameID
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [id], owned: false)

        #expect(vm.undoManager?.canUndo == true)
        #expect(vm.undoManager?.undoActionName == "Remove Copy")
        // The copies are gone (un-owned), but the game remains (it is played).
        try await UIWiring.syncGames(vm, from: store)
        #expect(vm.games.first { $0.id == id }?.owned == false)
    }
}

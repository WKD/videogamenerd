import Foundation
import Testing
@testable import VGN

/// Shared helpers for the live-wiring UI tests: a `LibraryStore` over an
/// in-memory DB, the GRDB-backed data source, a view model + actions, and small
/// polling helpers for the async observation propagation. Never touches the real
/// database file.
enum UIWiring {
    /// A migrated in-memory store with the test platforms seeded.
    @MainActor
    static func makeStore() async throws -> LibraryStore {
        try await TestDB.makeStore()
    }

    /// A store whose platforms come from the bundled `platforms.json` (needed
    /// when a test references a platform outside the small `TestDB` set, e.g.
    /// `ps3` for the sample compilation).
    @MainActor
    static func makeBundleStore() async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle()
        return LibraryStore(db)
    }

    /// A view model wired to a live store + actions (as the app assembles it).
    @MainActor
    static func makeWired(_ store: LibraryStore) -> (vm: LibraryViewModel, actions: LibraryActions) {
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: store))
        let actions = LibraryActions(store: store, vm: vm)
        actions.install()
        return (vm, actions)
    }

    /// Populate `vm.games` from a single one-shot read (no live observation), so
    /// intent tests exercise the write path without leaving infinite GRDB
    /// observations running — which, accumulated across parallel tests over one
    /// serial `DatabaseQueue`, would starve the awaited writes.
    @MainActor
    static func syncGames(
        _ vm: LibraryViewModel, from store: LibraryStore,
        filter: LibraryFilter = LibraryFilter()
    ) async throws {
        vm.applyGames(try await store.gamesOnce(filter: filter))
    }
}

/// Poll a synchronous condition on the main actor until it holds or the budget
/// runs out (observations propagate asynchronously).
@MainActor
func poll(_ times: Int = 400, until condition: @MainActor () -> Bool) async {
    for _ in 0..<times {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Poll an async condition until it holds or the budget runs out.
@MainActor
func pollAsync(_ times: Int = 400, until condition: @MainActor () async -> Bool) async {
    for _ in 0..<times {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

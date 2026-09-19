import Foundation
import Testing
@testable import VGN

/// UI-model tests for the Library Stats window's ``StatsModel`` (PLAN §6.4): first
/// load, scope switching, and live reload when the library changes. `@MainActor` +
/// GRDB ⇒ `@Suite(.serialized)`; every case is bounded by `poll`.
@MainActor
@Suite(.serialized)
struct StatsModelTests {

    private func makeStore() async throws -> LibraryStore {
        LibraryStore(try await TestDB.makeSeeded())
    }

    @Test func loadsReportOnStart() async throws {
        let store = try await makeStore()
        _ = try await store.addGame(GameDraft(title: "One", igdbID: 1, platformIDs: ["pc"],
                                              owned: true, played: true))
        let model = StatsModel(store: LibraryStatsStore(store.database))
        #expect(model.isLoading)

        await model.start()
        defer { model.stop() }

        #expect(!model.isLoading)
        #expect(model.report.totalGames == 1)
        #expect(model.scope == .all)
    }

    @Test func scopeSwitchNarrowsReport() async throws {
        let store = try await makeStore()
        _ = try await store.addGame(GameDraft(title: "Owned+Played", igdbID: 1, platformIDs: ["pc"],
                                              owned: true, played: true))
        _ = try await store.addGame(GameDraft(title: "Backlog", igdbID: 2, platformIDs: ["pc"], owned: true))
        let model = StatsModel(store: LibraryStatsStore(store.database))
        await model.start()
        defer { model.stop() }

        #expect(model.report.totalGames == 2)

        model.setScope(.played)
        await poll { model.scope == .played && model.report.totalGames == 1 }
        #expect(model.report.scope == .played)
        #expect(model.report.totalGames == 1)
    }

    @Test func reloadsWhenLibraryChanges() async throws {
        let store = try await makeStore()
        _ = try await store.addGame(GameDraft(title: "First", igdbID: 1, platformIDs: ["pc"], owned: true))
        let model = StatsModel(store: LibraryStatsStore(store.database))
        await model.start()
        defer { model.stop() }
        #expect(model.report.totalGames == 1)

        // A write the observation should pick up and re-query for.
        _ = try await store.addGame(GameDraft(title: "Second", igdbID: 2, platformIDs: ["pc"], owned: true))
        await poll { model.report.totalGames == 2 }
        #expect(model.report.totalGames == 2)
    }
}

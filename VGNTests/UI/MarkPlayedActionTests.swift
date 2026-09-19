import Foundation
import Testing
@testable import VGN

/// End-to-end "Mark Played As" tests over an in-memory `LibraryStore` + the wired
/// view model / actions (PLAN §8, owner request 2026-09-19). `@MainActor` +
/// serialized (GRDB async I/O on the main actor deadlocks in parallel).
@MainActor
@Suite(.serialized)
struct MarkPlayedActionTests {

    private func backlog(_ store: LibraryStore, _ title: String) async throws -> Int64 {
        try await store.addGame(GameDraft(title: title, platformIDs: ["ps4"], owned: true)).gameID
    }

    /// A wired VM + actions with an injected mark-preference box and a real
    /// undo manager, and `vm.games` seeded from a one-shot read.
    private func makeWired(
        _ store: LibraryStore, prefs: InMemoryLastPlayedMarkPreferences = .init()
    ) -> (vm: LibraryViewModel, actions: LibraryActions) {
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: store),
                                  playedMarkPreferences: prefs)
        let actions = LibraryActions(store: store, vm: vm)
        actions.install()
        vm.undoManager = UndoManager()
        return (vm, actions)
    }

    // MARK: - Targets, last value, banners

    @Test func marksExactlyTheGivenIDs() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await backlog(store, "A")
        let b = try await backlog(store, "B")
        let c = try await backlog(store, "C")
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.markPlayed(ids: [a, b], mark: .status(.finished))

        #expect(try #require(try await store.gameDetail(id: a)).status == .finished)
        #expect(try #require(try await store.gameDetail(id: b)).played)
        #expect(try #require(try await store.gameDetail(id: c)).played == false)   // untouched
    }

    @Test func choosingAMarkBecomesLastAndPersists() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await backlog(store, "A")
        let prefs = InMemoryLastPlayedMarkPreferences()
        let (vm, _) = makeWired(store, prefs: prefs)
        try await UIWiring.syncGames(vm, from: store)

        vm.markPlayed([a], as: .status(.completed))

        #expect(vm.lastPlayedMark == .status(.completed))
        #expect(prefs.lastPlayedMark() == .status(.completed))
    }

    @Test func lastMarkLoadsFromPreferencesAtInit() async throws {
        let store = try await UIWiring.makeStore()
        let prefs = InMemoryLastPlayedMarkPreferences(.status(.abandoned))
        let (vm, _) = makeWired(store, prefs: prefs)
        #expect(vm.lastPlayedMark == .status(.abandoned))
    }

    @Test func bannerCountsChanged() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await backlog(store, "A")
        let b = try await backlog(store, "B")
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.markPlayed(ids: [a, b], mark: .status(.finished))
        #expect(vm.banner?.message == "^[2 game](inflect: true) marked Finished.")
    }

    @Test func bannerReportsAlreadyInState() async throws {
        let store = try await UIWiring.makeStore()
        // Both already finished.
        let a = try await store.addGame(
            GameDraft(title: "A", platformIDs: ["ps4"], owned: true, played: true, status: .finished)).gameID
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.markPlayed(ids: [a], mark: .status(.finished))
        #expect(vm.banner?.message == "^[1 game](inflect: true) already Finished — unchanged.")
    }

    // MARK: - Undo

    @Test func undoRestoresExactPriorPlayedAndStatus() async throws {
        let store = try await UIWiring.makeStore()
        // a: already played + Playing; b: backlog (unplayed, no status).
        let a = try await store.addGame(
            GameDraft(title: "A", platformIDs: ["ps4"], owned: true, played: true, status: .playing)).gameID
        let b = try await backlog(store, "B")
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.markPlayed(ids: [a, b], mark: .status(.finished))
        #expect(try #require(try await store.gameDetail(id: a)).status == .finished)
        #expect(try #require(try await store.gameDetail(id: b)).status == .finished)

        // Registration is in place (UndoManager.undo() hangs headless — assert
        // name + drive the inverse directly).
        #expect(vm.undoManager?.canUndo == true)
        #expect(vm.undoManager?.undoActionName == "Mark as Finished")

        try await UIWiring.syncGames(vm, from: store)   // restore reads current tier state
        await actions.restoreMarkPlayed(
            [a: PriorPlayState(played: true, status: .playing),
             b: PriorPlayState(played: false, status: nil)],
            actionName: "Mark as Finished")

        let da = try #require(try await store.gameDetail(id: a))
        #expect(da.played)                      // stayed played
        #expect(da.status == .playing)          // status restored
        let db = try #require(try await store.gameDetail(id: b))
        #expect(db.played == false)             // un-played back to backlog
        #expect(db.status == nil)
    }

    @Test func undoKeepsAGameTieredAfterMarking() async throws {
        let store = try await UIWiring.makeStore()
        let b = try await backlog(store, "B")     // backlog, unplayed
        let (vm, actions) = makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.markPlayed(ids: [b], mark: .played)
        #expect(try #require(try await store.gameDetail(id: b)).played)

        // Tier it AFTER the mark (only played games can be tiered).
        _ = try await store.setTier([b], tierID: 1)
        try await UIWiring.syncGames(vm, from: store)
        #expect(vm.games.first { $0.id == b }?.tierID != nil)

        // Undo: un-playing would strip the tier → the game is left played + tiered.
        await actions.restoreMarkPlayed(
            [b: PriorPlayState(played: false, status: nil)], actionName: "Mark as Played")

        let db = try #require(try await store.gameDetail(id: b))
        #expect(db.played)
        #expect(db.tierID != nil)
        #expect(vm.banner?.message.contains("kept played") == true)
    }

    // MARK: - Selection cleanup in Backlog scope

    @Test func selectionMovesToVacatedPositionInBacklog() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await backlog(store, "A")
        let b = try await backlog(store, "B")
        let c = try await backlog(store, "C")
        let (vm, actions) = makeWired(store)   // keep `actions` alive: its hook holds self weakly
        vm.start()
        defer { vm.stop() }
        vm.select(.backlog)
        await poll { vm.games.map(\.id) == [a, b, c] }

        vm.selectOnly(a)                 // first game
        vm.markPlayed([a], as: .played)  // a leaves Backlog

        await poll { vm.games.map(\.id) == [b, c] }
        await poll { vm.selectedGameIDs == [b] }
        #expect(vm.selectedGameIDs == [b])       // the game now at index 0
        #expect(vm.selectionAnchor == b)         // anchor reset sensibly
        #expect(vm.selectedDetail?.id != a)      // no stale inspector detail
        withExtendedLifetime(actions) {}
    }

    @Test func selectionUnchangedWhenScopeKeepsGames() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await backlog(store, "A")
        let b = try await backlog(store, "B")
        let (vm, actions) = makeWired(store)   // keep `actions` alive
        vm.start()
        defer { vm.stop() }
        // .all keeps played games, so the marked game stays selected.
        await poll { vm.games.map(\.id) == [a, b] }
        vm.selectOnly(a)
        vm.markPlayed([a], as: .status(.finished))

        // Wait for the write to propagate (a's status becomes finished).
        await pollAsync {
            let detail = try? await store.gameDetail(id: a)
            return (detail ?? nil)?.status == .finished
        }
        #expect(vm.selectedGameIDs == [a])       // still selected — did not vanish
        withExtendedLifetime(actions) {}
    }
}

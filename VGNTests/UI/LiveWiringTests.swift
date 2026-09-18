import Foundation
import Testing
@testable import VGN

/// Live-wiring tests that touch a GRDB `DatabaseQueue`. They are `@MainActor`
/// (they drive the `@MainActor` view model / actions) and **serialized**: two
/// `@MainActor` tests each awaiting GRDB async I/O concurrently deadlock, so this
/// suite guarantees at most one runs at a time. (The pure store tests elsewhere
/// are non-`@MainActor` and run in parallel safely.)
@MainActor
@Suite(.serialized)
struct LiveWiringTests {

    // MARK: - Data-source bridging (GRDB ValueObservation → AsyncStream)

    @Test func gamesStreamEmitsInitialThenOnWrite() async throws {
        let store = try await UIWiring.makeStore()
        let ds = GRDBLibraryDataSource(store: store)
        var iterator = ds.games(filter: LibraryFilter()).makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.isEmpty == true)

        _ = try await store.addGame(GameDraft(title: "Halo", platformIDs: ["ps4"], owned: true))

        let afterWrite = await iterator.next()
        #expect(afterWrite?.contains { $0.title == "Halo" } == true)
    }

    @Test func detailStreamLiveUpdates() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(GameDraft(title: "Ico", platformIDs: ["ps2"], played: true)).gameID
        let ds = GRDBLibraryDataSource(store: store)
        var iterator = ds.gameDetailStream(id: id).makeAsyncIterator()

        let first = await iterator.next()
        #expect(first??.status == nil)

        try await store.setStatus([id], .finished)
        let second = await iterator.next()
        #expect(second??.status == .finished)
    }

    @Test func cancellingStreamEndsDelivery() async throws {
        let store = try await UIWiring.makeStore()
        let ds = GRDBLibraryDataSource(store: store)
        let box = EmissionBox()

        let task = Task { @MainActor in
            for await rows in ds.games(filter: LibraryFilter()) {
                box.count += 1
                box.last = rows.count
            }
        }
        await poll { box.count >= 1 }                 // initial emission arrived
        task.cancel()
        let countAtCancel = box.count

        _ = try await store.addGame(GameDraft(title: "Late", platformIDs: ["ps4"], owned: true))
        try? await Task.sleep(for: .milliseconds(120))
        #expect(box.count == countAtCancel)           // no delivery after cancel
    }

    @Test func latestFilterWinsAtViewModel() async throws {
        let store = try await UIWiring.makeStore()
        _ = try await store.addGame(GameDraft(title: "OwnedOnly", platformIDs: ["ps4"], owned: true))
        _ = try await store.addGame(GameDraft(title: "PlayedOnly", platformIDs: ["ps4"], played: true))
        let (vm, _) = UIWiring.makeWired(store)
        vm.start()
        defer { vm.stop() }
        await poll { vm.games.count == 2 }

        vm.select(.owned)
        vm.select(.played)
        vm.select(.all)
        await poll { vm.filter.scope == .all && vm.games.count == 2 }

        #expect(vm.selection == .all)
        #expect(vm.games.count == 2)
    }

    // MARK: - Tier intent

    @Test func tierAppliesToPlayedAndSkipsUnplayed() async throws {
        let store = try await UIWiring.makeStore()
        let played = try await store.addGame(
            GameDraft(title: "Played", platformIDs: ["ps4"], played: true)).gameID
        let unplayed = try await store.addGame(
            GameDraft(title: "Backlog", platformIDs: ["ps4"], owned: true, played: false)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        vm.applyTiers(try await store.tiers())
        try await UIWiring.syncGames(vm, from: store)

        await actions.setTier(ids: [played, unplayed], letter: "S")

        #expect(try await store.gameDetail(id: played)?.tierLetter == "S")
        #expect(try await store.gameDetail(id: unplayed)?.tierID == nil)   // skipped
        #expect(vm.banner?.kind == .warning)
    }

    // MARK: - Played + orphan confirmation

    @Test func unplayingOrphanRequiresConfirmationThenDeletes() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "PlayedNotOwned", platformIDs: ["pc"], owned: false, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setPlayed(ids: [id], played: false)

        #expect(vm.pendingConfirmation != nil)
        #expect(try await store.gameDetail(id: id)?.played == true)         // unchanged

        vm.pendingConfirmation?.perform()
        await pollAsync { (try? await store.gameDetail(id: id)) == .some(nil) }
        #expect(try await store.gameDetail(id: id) == nil)                  // deleted
    }

    @Test func unplayingOrphanCancelLeavesGameUntouched() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "KeepMe", platformIDs: ["pc"], owned: false, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setPlayed(ids: [id], played: false)
        vm.pendingConfirmation = nil                                        // user cancels

        try? await Task.sleep(for: .milliseconds(40))
        #expect(try await store.gameDetail(id: id)?.played == true)
    }

    @Test func playedOffWhenOwnedJustUnplays() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "OwnedPlayed", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setPlayed(ids: [id], played: false)
        #expect(vm.pendingConfirmation == nil)
        #expect(try await store.gameDetail(id: id)?.played == false)
    }

    // MARK: - Owned intent

    @Test func markOwnedSinglePlatformAddsCopy() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "PlayedOnly", platformIDs: ["ps4"], owned: false, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [id], owned: true)
        await pollAsync { (try? await store.gameDetail(id: id))??.owned == true }

        let detail = try await store.gameDetail(id: id)
        #expect(detail?.owned == true)
        #expect(detail?.copies.first?.platformID == "ps4")
        #expect(vm.ownershipRequest == nil)
    }

    @Test func markOwnedMultiPlatformOpensPickerThenAdds() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "CrossPlat", platformIDs: ["ps5", "ps4"], owned: false, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)
        #expect(vm.games.first?.platformIDs.count == 2)

        await actions.setOwned(ids: [id], owned: true)
        let request = try #require(vm.ownershipRequest)
        #expect(request.gamePlatforms.count == 2)

        request.perform("ps4", .digital)
        await pollAsync { (try? await store.gameDetail(id: id))??.owned == true }
        let detail = try await store.gameDetail(id: id)
        #expect(detail?.copies.first?.platformID == "ps4")
        #expect(detail?.copies.first?.format == .digital)
    }

    @Test func unOwnCompilationSurfacesMemberWarningData() async throws {
        let store = try await UIWiring.makeStore()
        let comp = ProductDraft(title: "Legacy Collection", platformID: "ps2")
        let (_, members) = try await store.addCompilation(
            product: comp,
            members: [
                CompilationMemberDraft(title: "MGS2", played: true, position: 0),
                CompilationMemberDraft(title: "MGS3", played: true, position: 1),
            ]
        )
        let memberID = members[0].gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [memberID], owned: false)
        await poll { vm.copyRemovalRequest != nil }

        let request = try #require(vm.copyRemovalRequest)
        let compilationChoice = try #require(request.copies.first { $0.isCompilation })
        #expect(compilationChoice.isCompilation)
        #expect(compilationChoice.compilationMembers.isEmpty == false)
    }

    // MARK: - Status + playtime

    @Test func statusSetsThenClears() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Statusable", platformIDs: ["ps4"], played: true)).gameID
        let (_, actions) = UIWiring.makeWired(store)

        await actions.setStatus(ids: [id], status: .finished)
        #expect(try await store.gameDetail(id: id)?.status == .finished)

        await actions.setStatus(ids: [id], status: nil)
        #expect(try await store.gameDetail(id: id)?.status == nil)
    }

    @Test func playtimeParsedInputPersistsAndClears() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Timed", platformIDs: ["ps4"], played: true)).gameID
        let (_, actions) = UIWiring.makeWired(store)

        let seconds = try #require(PlaytimeParser.seconds(from: "45h"))
        await actions.setMyPlaytime(gameID: id, seconds: seconds)
        #expect(try await store.gameDetail(id: id)?.myPlaytimeS == 45 * 3600)

        await actions.setMyPlaytime(gameID: id, seconds: nil)
        #expect(try await store.gameDetail(id: id)?.myPlaytimeS == nil)
    }

    // MARK: - Delete

    @Test func deleteConfirmsThenRemoves() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Doomed", platformIDs: ["ps4"], owned: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        actions.requestDelete(ids: [id])
        let confirmation = try #require(vm.pendingConfirmation)
        #expect(confirmation.isDestructive)

        confirmation.perform()
        await pollAsync { (try? await store.gameDetail(id: id)) == .some(nil) }
        #expect(try await store.gameDetail(id: id) == nil)
    }

    // MARK: - Undo

    @Test func tierChangeIsUndoable() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Undoable", platformIDs: ["ps4"], played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        vm.applyTiers(try await store.tiers())
        try await UIWiring.syncGames(vm, from: store)
        let undo = UndoManager()
        vm.undoManager = undo

        await actions.setTier(ids: [id], letter: "A")
        #expect(try await store.gameDetail(id: id)?.tierLetter == "A")
        #expect(undo.canUndo)                       // the inverse was registered

        // Apply the inverse directly (driving UndoManager.undo() would spin the
        // run loop headlessly and hang). This is exactly what undo() invokes.
        await actions.restoreTiers([id: nil])
        #expect(try await store.gameDetail(id: id)?.tierID == nil)
    }

    // MARK: - Sample launch mode + live sidebar grouping

    @Test func sampleLaunchModeSeedsThroughStore() async throws {
        let store = try await UIWiring.makeBundleStore()
        await SampleLibrarySeeder.seed(into: store)

        let counts = try await store.sidebarCountsOnce()
        #expect(counts.all == SampleLibrarySeeder.drafts.count + 2)   // + 2 compilation members
        #expect(counts.owned > 0)
        #expect(counts.played > 0)

        let games = try await store.gamesOnce(filter: LibraryFilter(scope: .owned))
        #expect(games.contains { $0.title == "Metal Gear Solid 2: Sons of Liberty" })
    }

    @Test func groupsFromLivePlatformsInUse() async throws {
        let store = try await UIWiring.makeStore()
        _ = try await store.addGame(GameDraft(title: "A", platformIDs: ["ps5"], owned: true))
        _ = try await store.addGame(GameDraft(title: "B", platformIDs: ["snes"], played: true))

        let platforms = try await store.platformsInUseOnce()
        let counts = try await store.sidebarCountsOnce()
        let groups = SidebarPlatformGrouping.groups(platforms: platforms, counts: counts)

        #expect(groups.map(\.name) == ["Sony", "Nintendo"])
        #expect(groups.first?.platforms.map(\.id) == ["ps5"])
        #expect(groups.flatMap(\.platforms).contains { $0.id == "ps4" } == false)
    }
}

@MainActor
final class EmissionBox {
    var count = 0
    var last = 0
}

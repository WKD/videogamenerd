import Foundation
import Testing
@testable import VGN

// MARK: - Pure model (no DB, no window)

/// The ask-once "Mark Owned" batch decision model (PLAN §8). Pure — constructed
/// directly from `GameSummary` values; no GRDB, so not serialized.
@MainActor
struct BatchOwnershipModelTests {

    private let platforms: [PlatformInfo] = [
        PlatformInfo(id: "ps5", name: "PlayStation 5", short: "PS5", manufacturer: "Sony", kind: .console),
        PlatformInfo(id: "ps4", name: "PlayStation 4", short: "PS4", manufacturer: "Sony", kind: .console),
        PlatformInfo(id: "pc", name: "PC (Windows)", short: "PC", manufacturer: "PC", kind: .computer),
    ]

    private func model(_ games: [GameSummary],
                       prefs: BatchOwnershipPreferenceStoring = InMemoryBatchOwnershipPreferences(),
                       onConfirm: @escaping ([BatchCopySpec]) -> Void = { _ in }) -> BatchOwnershipModel {
        BatchOwnershipModel(games: games, allPlatforms: platforms, preferences: prefs, onConfirm: onConfirm)
    }

    @Test func mixedBatchPartitionsRows() {
        let games = [
            GameSummary(id: 1, title: "Owned", owned: true, platformIDs: ["ps4"]),
            GameSummary(id: 2, title: "Ambiguous", owned: false, platformIDs: ["ps5", "ps4"]),
            GameSummary(id: 3, title: "Simple", owned: false, platformIDs: ["pc"]),
            GameSummary(id: 4, title: "NoPlatform", owned: false, platformIDs: []),
        ]
        let m = model(games)
        #expect(m.rows.count == 2)                 // only pending games
        #expect(m.alreadyOwnedCount == 1)
        #expect(m.noPlatformCount == 1)
        #expect(m.rows.first?.gameID == 2)         // ambiguous first
        #expect(m.ambiguousRows.map(\.gameID) == [2])
        #expect(m.simpleRows.map(\.gameID) == [3])
        #expect(m.rows.first?.platformID == "ps5") // default = primary
        #expect(m.canConfirm)
        #expect(BatchOwnershipModel.hasPendingGames(games))
    }

    @Test func ambiguousRowsSortBeforeSimpleKeepingOrder() {
        let games = [
            GameSummary(id: 1, title: "SimpleA", owned: false, platformIDs: ["pc"]),
            GameSummary(id: 2, title: "AmbiguousA", owned: false, platformIDs: ["ps5", "ps4"]),
            GameSummary(id: 3, title: "SimpleB", owned: false, platformIDs: ["ps4"]),
            GameSummary(id: 4, title: "AmbiguousB", owned: false, platformIDs: ["ps5", "pc"]),
        ]
        let m = model(games)
        #expect(m.rows.map(\.gameID) == [2, 4, 1, 3])   // ambiguous (in order) then simple (in order)
    }

    @Test func allOwnedHasNoPendingGamesAndCannotConfirm() {
        let games = [
            GameSummary(id: 1, title: "A", owned: true, platformIDs: ["ps4"]),
            GameSummary(id: 2, title: "B", owned: true, platformIDs: ["ps5"]),
        ]
        #expect(!BatchOwnershipModel.hasPendingGames(games))
        let m = model(games)
        #expect(m.rows.isEmpty)
        #expect(!m.canConfirm)
        #expect(m.alreadyOwnedCount == 2)
    }

    @Test func platformOverrideChangesResolvedSpec() {
        let games = [GameSummary(id: 2, title: "Ambiguous", owned: false, platformIDs: ["ps5", "ps4"])]
        let m = model(games)
        #expect(m.resolvedSpecs() == [BatchCopySpec(gameID: 2, platformID: "ps5", format: .physical)])
        m.setPlatform("ps4", for: 2)
        #expect(m.resolvedSpecs() == [BatchCopySpec(gameID: 2, platformID: "ps4", format: .physical)])
    }

    @Test func resolvedSpecsCarryTheSelectedFormat() {
        let games = [
            GameSummary(id: 1, title: "A", owned: false, platformIDs: ["pc"]),
            GameSummary(id: 2, title: "B", owned: false, platformIDs: ["ps4"]),
        ]
        let m = model(games)
        m.format = .rom
        #expect(m.resolvedSpecs().allSatisfy { $0.format == .rom })
        #expect(Set(m.resolvedSpecs().map(\.gameID)) == [1, 2])
    }

    @Test func formatDefaultsToPersistedAndSavesOnConfirm() {
        let prefs = InMemoryBatchOwnershipPreferences(.digital)
        let games = [GameSummary(id: 1, title: "A", owned: false, platformIDs: ["pc"])]

        let first = model(games, prefs: prefs)
        #expect(first.format == .digital)          // default = persisted

        var handed: [BatchCopySpec] = []
        let m = model(games, prefs: prefs, onConfirm: { handed = $0 })
        m.format = .rom
        m.confirm()
        #expect(handed == [BatchCopySpec(gameID: 1, platformID: "pc", format: .rom)])
        #expect(prefs.loadFormat() == .rom)        // persisted on confirm

        let next = model(games, prefs: prefs)
        #expect(next.format == .rom)               // remembered for the next batch
    }

    @Test func platformNameFallsBackToSlug() {
        let m = model([GameSummary(id: 1, title: "A", owned: false, platformIDs: ["ps5"])])
        #expect(m.platformName("ps5") == "PlayStation 5")
        #expect(m.platformName("unknown-slug") == "unknown-slug")
    }
}

// MARK: - Store + actions (GRDB, one transaction, wired)

@MainActor
@Suite(.serialized)
struct BatchOwnershipWiringTests {

    /// Add N games that exist (played) but aren't owned yet.
    private func seedUnowned(_ store: LibraryStore, _ titles: [(String, [String])]) async throws -> [Int64] {
        var ids: [Int64] = []
        for (title, platforms) in titles {
            ids.append(try await store.addGame(
                GameDraft(title: title, platformIDs: platforms, owned: false, played: true)).gameID)
        }
        return ids
    }

    @Test func addCopiesMarksEveryGameOwned() async throws {
        let store = try await UIWiring.makeStore()
        let ids = try await seedUnowned(store, [("A", ["ps4"]), ("B", ["ps5"]), ("C", ["pc"])])

        let specs = [
            BatchCopySpec(gameID: ids[0], platformID: "ps4", format: .physical),
            BatchCopySpec(gameID: ids[1], platformID: "ps5", format: .digital),
            BatchCopySpec(gameID: ids[2], platformID: "pc", format: .rom),
        ]
        let productIDs = try await store.addCopies(specs)
        #expect(productIDs.count == 3)

        for (id, format) in zip(ids, [ProductFormat.physical, .digital, .rom]) {
            let detail = try await store.gameDetail(id: id)
            #expect(detail?.owned == true)
            #expect(detail?.copies.first?.format == format)
        }
    }

    @Test func addCopiesEmptyIsANoOp() async throws {
        let store = try await UIWiring.makeStore()
        #expect(try await store.addCopies([]).isEmpty)
    }

    @Test func addCopiesIsOneTransaction() async throws {
        // A valid spec followed by an invalid game id must roll BACK the valid one
        // — proving the batch is a single transaction, not per-game writes.
        let store = try await UIWiring.makeStore()
        let ids = try await seedUnowned(store, [("A", ["ps4"])])
        let specs = [
            BatchCopySpec(gameID: ids[0], platformID: "ps4"),
            BatchCopySpec(gameID: 999_999, platformID: "ps4"),   // no such game → FK error
        ]
        await #expect(throws: (any Error).self) { try await store.addCopies(specs) }
        #expect(try await store.gameDetail(id: ids[0])?.owned == false)   // rolled back
    }

    @Test func multiGameMarkOwnedOpensBatchSheetThenWrites() async throws {
        let store = try await UIWiring.makeStore()
        let ids = try await seedUnowned(store, [("A", ["ps4"]), ("B", ["ps5"])])
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: Set(ids), owned: true)
        let model = try #require(vm.batchOwnershipRequest)      // sheet, not a silent write
        #expect(model.rows.count == 2)
        #expect(try await store.gameDetail(id: ids[0])?.owned == false)   // nothing written yet

        model.confirm()
        await pollAsync { (try? await store.gameDetail(id: ids[0]))??.owned == true }
        #expect(try await store.gameDetail(id: ids[0])?.owned == true)
        #expect(try await store.gameDetail(id: ids[1])?.owned == true)
    }

    @Test func multiGameAllOwnedShowsBannerNotSheet() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", platformIDs: ["ps4"], owned: true)).gameID
        let b = try await store.addGame(GameDraft(title: "B", platformIDs: ["ps5"], owned: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [a, b], owned: true)
        #expect(vm.batchOwnershipRequest == nil)
        #expect(vm.banner != nil)
    }

    @Test func multiGameUnOwnIsRefusedWithBanner() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let b = try await store.addGame(GameDraft(title: "B", platformIDs: ["ps5"], owned: true, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [a, b], owned: false)
        #expect(vm.banner != nil)
        #expect(vm.copyRemovalRequest == nil)
        #expect(try await store.gameDetail(id: a)?.owned == true)   // untouched
        #expect(try await store.gameDetail(id: b)?.owned == true)
    }

    @Test func singleGameMarkOwnedStaysImmediate() async throws {
        let store = try await UIWiring.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Solo", platformIDs: ["ps4"], owned: false, played: true)).gameID
        let (vm, actions) = UIWiring.makeWired(store)
        try await UIWiring.syncGames(vm, from: store)

        await actions.setOwned(ids: [id], owned: true)
        #expect(vm.batchOwnershipRequest == nil)                    // no sheet for one game
        await pollAsync { (try? await store.gameDetail(id: id))??.owned == true }
        #expect(try await store.gameDetail(id: id)?.owned == true)
    }
}

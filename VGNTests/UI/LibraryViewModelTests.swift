import Testing
@testable import VGN

/// Games titled so that a title sort equals id order — keeps selection maths
/// deterministic regardless of the default sort.
@MainActor
private func orderedGames(_ n: Int) -> [GameSummary] {
    (1...n).map { i in
        GameSummary(id: Int64(i), title: String(format: "Game %04d", i), year: 1990 + i,
                    played: true, owned: true, platformIDs: ["ps2"])
    }
}

@MainActor
private func loadedVM(_ games: [GameSummary]) async -> LibraryViewModel {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: games))
    vm.start()
    for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
    return vm
}

@MainActor
struct LibraryViewModelSelectionTests {

    @Test func selectionChangesFilterScope() async {
        let vm = await loadedVM(orderedGames(3))
        #expect(vm.filter.scope == .all)
        vm.select(.owned)
        #expect(vm.selection == .owned)
        #expect(vm.filter.scope == .owned)
        vm.select(.platform("ps2"))
        #expect(vm.filter.scope == .platform("ps2"))
    }

    @Test func selectionChangeClearsGridSelection() async {
        let vm = await loadedVM(orderedGames(3))
        vm.selectOnly(2)
        #expect(vm.selectedGameIDs == [2])
        vm.select(.played)
        #expect(vm.selectedGameIDs.isEmpty)
    }

    @Test func rangeSelectionForward() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(1)
        vm.extendSelection(to: 3)
        #expect(vm.selectedGameIDs == [1, 2, 3])
    }

    @Test func rangeSelectionBackward() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(4)
        vm.extendSelection(to: 2)
        #expect(vm.selectedGameIDs == [2, 3, 4])
    }

    @Test func rangeSelectionWithoutAnchorSelectsOne() async {
        let vm = await loadedVM(orderedGames(5))
        vm.clearSelection()
        vm.extendSelection(to: 3)
        #expect(vm.selectedGameIDs == [3])
    }

    @Test func commandToggle() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(1)
        vm.toggle(3)
        #expect(vm.selectedGameIDs == [1, 3])
        vm.toggle(3)
        #expect(vm.selectedGameIDs == [1])
    }

    @Test func arrowMovement() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(2)
        #expect(vm.moveSelection(by: 1) == 3)
        #expect(vm.selectedGameIDs == [3])
        #expect(vm.moveSelection(by: -1) == 2)
        #expect(vm.moveSelection(by: -5) == 1)   // clamps to first
        #expect(vm.moveSelection(by: 99) == 5)   // clamps to last
    }

    @Test func selectedGameIsNilForMultiSelection() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(2)
        #expect(vm.selectedGame?.id == 2)
        vm.selectedGameIDs = [1, 2]
        #expect(vm.selectedGame == nil)
        #expect(vm.selectedGames.count == 2)
    }
}

@MainActor
struct LibraryViewModelKeyTests {

    @Test func keyIntentsSuppressedWhileSearchFocused() async {
        let vm = await loadedVM(orderedGames(3))
        vm.selectOnly(1)
        var calls: [(Set<Int64>, String?)] = []
        vm.onSetTier = { ids, letter in calls.append((ids, letter)) }

        vm.searchFieldFocused = true
        #expect(vm.handleKey(.tier("S")) == false)
        #expect(calls.isEmpty)

        vm.searchFieldFocused = false
        #expect(vm.handleKey(.tier("S")) == true)
        #expect(calls.count == 1)
        #expect(calls.first?.1 == "S")
    }

    @Test func keyIntentsRequireSelection() async {
        let vm = await loadedVM(orderedGames(3))
        vm.clearSelection()
        #expect(vm.handleKey(.markOwned) == false)
    }

    @Test func characterMapping() {
        #expect(LibraryKey(character: "s") == .tier("S"))
        #expect(LibraryKey(character: "A") == .tier("A"))
        #expect(LibraryKey(character: "f") == .tier("F"))
        #expect(LibraryKey(character: "0") == .clearTier)
        #expect(LibraryKey(character: "o") == .markOwned)
        #expect(LibraryKey(character: "p") == .markPlayed)
        #expect(LibraryKey(character: "x") == nil)
    }
}

@MainActor
struct LibraryViewModelCellCacheTests {

    @Test func cellModelBoxesAreReused() async {
        let vm = await loadedVM(orderedGames(3))
        let a = vm.cellModel(for: 1)
        let b = vm.cellModel(for: 1)
        #expect(a === b)   // same @Observable box across lookups
    }

    @Test func reapplyUpdatesOnlyChangedBox() async {
        let vm = await loadedVM(orderedGames(3))
        let box1 = vm.cellModel(for: 1)
        let box2 = vm.cellModel(for: 2)
        let box2Summary = box2.summary

        var changed = vm.games
        changed[0].title = "Renamed Game"   // id 1 only
        vm.applyGames(changed)

        // Boxes are reused (identity preserved), not recreated.
        #expect(vm.cellModel(for: 1) === box1)
        #expect(vm.cellModel(for: 2) === box2)
        // Only the changed id's summary updated.
        #expect(box1.summary.title == "Renamed Game")
        #expect(box2.summary == box2Summary)
    }

    @Test func removedGamesPruneBoxesAndSelection() async {
        let vm = await loadedVM(orderedGames(3))
        vm.selectOnly(3)
        _ = vm.cellModel(for: 3)
        vm.applyGames(Array(vm.games.prefix(2)))   // drop id 3
        #expect(vm.selectedGameIDs.isEmpty)         // stale selection pruned
        #expect(vm.games.count == 2)
    }
}

@MainActor
struct SidebarCountsTests {

    @Test func countLookupPerRow() {
        let counts = SidebarCounts.derive(from: GameSummary.samples)
        #expect(counts.count(for: .all) == 5)
        #expect(counts.count(for: .owned) == 4)
        #expect(counts.count(for: .played) == 4)
        #expect(counts.count(for: .backlog) == 1)
        #expect(counts.count(for: .unranked) == 1)
        #expect(counts.count(for: .duel) == 1)
        #expect(counts.count(for: .platform("ps4")) == 2)
        #expect(counts.count(for: .platform("ps2")) == 1)
        #expect(counts.count(for: .platform("gba")) == 0)
        // Ranking board rows show no numeric badge.
        #expect(counts.count(for: .tierBoard) == nil)
        #expect(counts.count(for: .theTop) == nil)
    }
}

struct GameCellModelTests {

    @MainActor
    @Test func updateMutatesOnlyOnChange() {
        let g = GameSummary(id: 1, title: "A")
        let box = GameCellModel(summary: g)
        box.update(g)                    // equal — no change
        #expect(box.summary.title == "A")
        var g2 = g; g2.title = "B"
        box.update(g2)
        #expect(box.summary.title == "B")
        #expect(box.id == 1)
    }
}

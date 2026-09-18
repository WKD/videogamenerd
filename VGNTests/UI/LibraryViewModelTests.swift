import Foundation
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

/// A controllable clock for the type-to-select window.
@MainActor private final class ClockBox { var now = Date(timeIntervalSince1970: 1_000) }

@MainActor
@Suite(.serialized)
struct MultiSelectAndTypeSelectTests {

    private func typeSelectGames() -> [GameSummary] {
        // Sorted-by-title order: Mega Man, Metroid, Sonic, Zelda.
        [GameSummary(id: 1, title: "Mega Man", played: true, owned: true, platformIDs: ["nes"]),
         GameSummary(id: 2, title: "Metroid", played: true, owned: true, platformIDs: ["nes"]),
         GameSummary(id: 3, title: "Sonic", played: true, owned: true, platformIDs: ["genesis"]),
         GameSummary(id: 4, title: "Zelda", played: true, owned: true, platformIDs: ["nes"])]
    }

    private func makeVM(_ games: [GameSummary], _ clock: ClockBox) async -> LibraryViewModel {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: games), now: { clock.now })
        vm.start()
        for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
        return vm
    }

    @Test func shiftArrowExtendsAndContractsRange() async {
        let vm = await loadedVM(orderedGames(5))
        vm.selectOnly(2)
        vm.extendSelection(by: 1)
        #expect(vm.selectedGameIDs == [2, 3])
        vm.extendSelection(by: 1)
        #expect(vm.selectedGameIDs == [2, 3, 4])
        vm.extendSelection(by: -3)              // cursor 4 → 1, pivot on anchor 2
        #expect(vm.selectedGameIDs == [1, 2])
    }

    @Test func typeToSelectJumpsOnNonTierLetter() async {
        let clock = ClockBox()
        let vm = await makeVM(typeSelectGames(), clock)
        var tierCalls = 0
        vm.onSetTier = { _, _ in tierCalls += 1 }
        vm.selectOnly(4)                        // Zelda selected

        // "m" is not a tier key → type-to-select jumps to the first "m" title.
        #expect(vm.handleGridCharacter("m") == 1)   // Mega Man
        #expect(vm.selectedGameIDs == [1])
        // Continue the buffer: "e" → "me" still Mega Man; "t" → "met" → Metroid.
        _ = vm.handleGridCharacter("e")
        #expect(vm.handleGridCharacter("t") == 2)   // Metroid
        #expect(tierCalls == 0)                     // never tiered
    }

    @Test func tierKeyFiresOnFirstKeystrokeWithSelection() async {
        let clock = ClockBox()
        let vm = await makeVM(typeSelectGames(), clock)
        var lastTier: (Set<Int64>, String?)?
        vm.onSetTier = { ids, letter in lastTier = (ids, letter) }
        vm.selectOnly(2)                        // Metroid selected, buffer inactive

        // "s" is a tier key + a selection exists + buffer inactive → tiers, no jump.
        #expect(vm.handleGridCharacter("s") == nil)
        #expect(lastTier?.0 == [2])
        #expect(lastTier?.1 == "S")
        #expect(vm.selectedGameIDs == [2])      // selection unchanged (no jump)
    }

    @Test func tierLetterTypesToSelectWhenNothingSelected() async {
        let clock = ClockBox()
        let vm = await makeVM(typeSelectGames(), clock)
        var tierCalls = 0
        vm.onSetTier = { _, _ in tierCalls += 1 }
        vm.clearSelection()                     // nothing selected

        // With no selection, even a tier letter starts type-to-select → Sonic.
        #expect(vm.handleGridCharacter("s") == 3)
        #expect(vm.selectedGameIDs == [3])
        #expect(tierCalls == 0)
    }

    @Test func activeBufferSuppressesTierKeysUntilWindowExpires() async {
        let clock = ClockBox()
        let vm = await makeVM(typeSelectGames(), clock)
        var tierCalls = 0
        vm.onSetTier = { _, _ in tierCalls += 1 }
        vm.selectOnly(1)

        // Start a buffer with a non-tier letter → active.
        _ = vm.handleGridCharacter("m")
        #expect(vm.isTypeBufferActive())
        // A tier letter within the window extends the buffer (no tiering).
        #expect(vm.handleGridCharacter("s") == nil)   // "ms" matches nothing
        #expect(tierCalls == 0)

        // Past the ~1 s window the buffer expires → a tier letter tiers again.
        clock.now = clock.now.addingTimeInterval(2)
        #expect(!vm.isTypeBufferActive())
        _ = vm.handleGridCharacter("s")
        #expect(tierCalls == 1)
    }
}

@MainActor
@Suite(.serialized)
struct SearchKeyboardTests {

    @Test func clearSearchClearsThenReportsEmpty() async {
        let vm = await loadedVM(orderedGames(3))
        vm.searchText = "foo"
        #expect(vm.clearSearch() == true)          // cleared, stays focused
        #expect(vm.searchText.isEmpty)
        #expect(vm.clearSearch() == false)         // already empty → caller unfocuses
    }

    @Test func downArrowSelectsFirstAndFocusesGrid() async {
        let vm = await loadedVM(orderedGames(3))
        let before = vm.gridFocusRequests
        vm.focusGridFromSearch()
        #expect(vm.selectedGameIDs == [1])
        #expect(vm.gridFocusRequests == before + 1)
    }

    @Test func returnOpensInspectorOnFirstResult() async {
        let vm = await loadedVM(orderedGames(3))
        vm.openFirstResult()
        #expect(vm.selectedGameIDs == [1])
        #expect(vm.inspectorPresented)
    }

    @Test func searchAllBroadensScopeKeepingQuery() async {
        let vm = await loadedVM(orderedGames(3))
        vm.select(.played)
        var f = vm.filter; f.searchText = "gam"; vm.setFilter(f)
        vm.searchAllScope()
        #expect(vm.selection == .all)
        #expect(vm.filter.searchText == "gam")     // query preserved across the escape
    }

    @Test func quickAddPrefillTrimmedAndConsumedOnce() async {
        let vm = await loadedVM(orderedGames(1))
        vm.requestQuickAdd(prefill: "  Bloodborne ")
        #expect(vm.quickAddPresented)
        #expect(vm.consumeQuickAddPrefill() == "Bloodborne")
        #expect(vm.consumeQuickAddPrefill() == nil)
    }
}

@MainActor
@Suite(.serialized)
struct SortPersistenceTests {

    @Test func setSortResetsDirectionToTheFieldDefault() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty,
                                  sortPreferences: InMemorySortPreferences())
        vm.setSort(.playtime)
        #expect(vm.filter.sort == .playtime)
        #expect(vm.filter.ascending == false)          // most-played first
        vm.setSort(.title)
        #expect(vm.filter.ascending == true)           // A→Z
    }

    @Test func sortPersistsPerSelectionAndSurvivesRelaunch() {
        let prefs = InMemorySortPreferences()
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty, sortPreferences: prefs)

        vm.setSort(.year)                               // All → year
        vm.select(.owned)
        #expect(vm.filter.sort == .title)               // a fresh selection defaults to title
        vm.setSort(.playtime)                           // Owned → playtime desc

        vm.select(.all)
        #expect(vm.filter.sort == .year)                // restored
        vm.select(.owned)
        #expect(vm.filter.sort == .playtime)
        #expect(vm.filter.ascending == false)

        // A new model over the same store restores the last "All" sort at launch.
        let relaunched = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty, sortPreferences: prefs)
        #expect(relaunched.filter.sort == .year)
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

    /// The per-cell box design (PLAN §9): re-yielding the games array reuses the
    /// same box instances, and changing one row leaves every *other* cell's box
    /// untouched (so a tick re-evaluates one cell, not the whole grid).
    @MainActor
    @Test func applyGamesReusesBoxesAndTouchesOnlyChangedCells() async {
        let vm = await loadedVM(orderedGames(4))
        let boxes = (1...4).map { vm.cellModel(for: Int64($0)) }
        let summariesBefore = boxes.map(\.summary)

        // Re-yield the identical rows → same instances, nothing mutated.
        vm.applyGames(vm.games)
        for (i, id) in (1...4).enumerated() {
            #expect(vm.cellModel(for: Int64(id)) === boxes[i])
            #expect(vm.cellModel(for: Int64(id)).summary == summariesBefore[i])
        }

        // Change only game 3's tier.
        var rows = vm.games
        let idx = rows.firstIndex { $0.id == 3 }!
        rows[idx].tierLetter = "S"; rows[idx].tierID = 1
        vm.applyGames(rows)

        for (i, id) in (1...4).enumerated() {
            #expect(vm.cellModel(for: Int64(id)) === boxes[i])          // never re-homed
            if id == 3 {
                #expect(vm.cellModel(for: 3).summary.tierLetter == "S") // the one changed cell
            } else {
                #expect(vm.cellModel(for: Int64(id)).summary == summariesBefore[i])  // untouched
            }
        }
    }
}

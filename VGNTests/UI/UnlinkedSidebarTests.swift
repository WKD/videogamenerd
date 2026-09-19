import Testing
@testable import VGN

/// The "Unlinked" sidebar row's count wiring and the selection move after a game leaves
/// the Unlinked list (PLAN §5.1). Pure/model — no GRDB.
@MainActor
struct UnlinkedSidebarTests {

    private func game(_ id: Int64) -> GameSummary {
        GameSummary(id: id, title: "G\(id)", played: true, owned: true, platformIDs: ["pc"])
    }

    @Test func countAndHiddenAtZero() {
        var counts = SidebarCounts(all: 10, unlinked: 0)
        #expect(counts.count(for: .unlinked) == 0)          // row hidden by the view when 0
        counts.unlinked = 3
        #expect(counts.count(for: .unlinked) == 3)          // shown
        #expect(SidebarView.title(for: .unlinked) == "Unlinked")
        #expect(SidebarSelection.unlinked.id == "unlinked")
    }

    @Test func linkingMovesSelectionToVacatedRow() async {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.applyGames([game(1), game(2), game(3)])
        vm.selectOnly(1)
        // A link on game 1 removes it from the (Unlinked) scope.
        vm.planReselectionAfterMutation([1])
        vm.applyGames([game(2), game(3)])                   // grid refreshes without game 1
        #expect(vm.selectedGameIDs == [2])                  // moved to the vacated position
    }

    @Test func reselectionNoOpWhenGameStaysInScope() async {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.applyGames([game(1), game(2), game(3)])
        vm.selectOnly(1)
        vm.planReselectionAfterMutation([1])
        vm.applyGames([game(1), game(2), game(3)])          // still present (e.g. All scope)
        #expect(vm.selectedGameIDs == [1])                  // selection unchanged
    }
}

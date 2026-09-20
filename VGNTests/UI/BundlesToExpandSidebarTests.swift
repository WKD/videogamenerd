import Foundation
import Testing
@testable import VGN

/// The "Bundles to Expand" sidebar smart list (PLAN §5.1 / §8, wave 16): stable selection id +
/// round-trip, the count wiring (hidden at 0, shown with a count), labels/icons, and the
/// preview/in-memory evaluator treating the scope like `.unlinked` (no crash, no constraint).
/// Pure/model — no GRDB.
@MainActor
struct BundlesToExpandSidebarTests {

    private func game(_ id: Int64) -> GameSummary {
        GameSummary(id: id, title: "G\(id)", played: true, owned: true, platformIDs: ["ps3"])
    }

    @Test func selectionIDRoundTripsAndIsStable() {
        #expect(SidebarSelection.bundlesToExpand.id == "bundlesToExpand")
        #expect(SidebarSelection.bundlesToExpand == SidebarSelection.bundlesToExpand)
        #expect(SidebarSelection.bundlesToExpand != SidebarSelection.unlinked)
        // Round-trips through the sort-preference persistence keyed by `id` (restore path).
        let suite = "vgn-bte-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = UserDefaultsSortPreferences(defaults: defaults)
        prefs.setSortSetting(SortSetting(sort: .year, ascending: false),
                             for: SidebarSelection.bundlesToExpand.id)
        let reopened = UserDefaultsSortPreferences(defaults: defaults)
        #expect(reopened.sortSetting(for: SidebarSelection.bundlesToExpand.id)
                == SortSetting(sort: .year, ascending: false))
    }

    @Test func countHiddenAtZeroAndShownWithACount() {
        var counts = SidebarCounts(all: 10, bundlesToExpand: 0)
        #expect(counts.count(for: .bundlesToExpand) == 0)          // row hidden by the view when 0
        counts.bundlesToExpand = 3
        #expect(counts.count(for: .bundlesToExpand) == 3)          // shown
    }

    @Test func labelAndIcon() {
        #expect(SidebarView.title(for: .bundlesToExpand) == "Bundles to Expand")
        #expect(!SidebarView.icon(for: .bundlesToExpand).isEmpty)
    }

    @Test func previewEvaluatorTreatsScopeLikeUnlinked() {
        // In sample/preview mode a GameSummary can't reproduce the store-side title heuristic, so
        // the scope is unconstrained (never crashes) — exactly like `.unlinked`.
        let filter = LibraryFilter(scope: .bundlesToExpand)
        #expect(LibraryFilterEvaluator.matches(game(1), filter))
        #expect(LibraryFilterEvaluator.apply(filter, to: [game(1), game(2)]).count == 2)
        // And derive leaves the count at 0 (row hidden in sample mode).
        #expect(SidebarCounts.derive(from: [game(1), game(2)]).bundlesToExpand == 0)
    }

    @Test func selectingTheListScopesTheFilter() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.select(.bundlesToExpand)
        #expect(vm.selection == .bundlesToExpand)
        #expect(vm.filter.scope == .bundlesToExpand)
        #expect(vm.isBundlesToExpandSelection)
    }
}

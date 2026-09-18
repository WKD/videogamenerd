import Testing
@testable import VGN

/// Play Next sidebar entry (PLAN §7b / §8): a LIBRARY smart list, after Unranked,
/// with no count badge, routed to its own view (not the grid, not a ranking view).
struct SidebarSelectionTests {

    @Test func playNextIsLastSmartListAfterUnranked() {
        let lists = SidebarSelection.smartLists
        #expect(lists.contains(.playNext))
        #expect(lists.last == .playNext)
        let unranked = lists.firstIndex(of: .unranked)!
        let playNext = lists.firstIndex(of: .playNext)!
        #expect(playNext == unranked + 1)
        // Not part of the RANKINGS section.
        #expect(!SidebarSelection.rankingViews.contains(.playNext))
    }

    @Test func playNextShowsNoCountBadge() {
        let counts = SidebarCounts(all: 10, owned: 5, played: 7)
        #expect(counts.count(for: .playNext) == nil)
    }

    @Test func playNextHasStableIdentityAndLabels() {
        #expect(SidebarSelection.playNext.id == "playNext")
        #expect(SidebarView.title(for: .playNext) == "Play Next")
        #expect(!SidebarView.icon(for: .playNext).isEmpty)
    }
}

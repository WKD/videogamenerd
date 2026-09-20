import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The richer empty states (PLAN §10, milestone 9): the pure state→copy mapping for the
/// library grid and Play Next, and click tests proving the two most important buttons
/// ("Clear filters", empty-library "Quick Add") really fire.
struct EmptyStateMappingTests {

    /// Tone check: short, second-person, no exclamation marks.
    private func assertTone(_ title: String, _ message: String, _ sourceLoc: SourceLocation = #_sourceLocation) {
        #expect(!title.isEmpty, sourceLocation: sourceLoc)
        #expect(!message.isEmpty, sourceLocation: sourceLoc)
        #expect(!title.contains("!"), sourceLocation: sourceLoc)
        #expect(!message.contains("!"), sourceLocation: sourceLoc)
    }

    // MARK: - Library grid smart lists

    @Test func gridSmartListMapping() {
        let cases: [(SidebarSelection, LibraryGridView.SmartListAction)] = [
            (.backlog, .quickAdd),
            (.unranked, .startRanking),
            (.unlinked, .none),
            (.owned, .quickAdd),
            (.played, .quickAdd),
            (.unmeasured, .fetchTimes),
            (.length(LengthShelf.allCases.first!), .fetchTimes),
            (.platform("ps5"), .quickAdd),
        ]
        for (selection, expected) in cases {
            let e = LibraryGridView.smartListEmpty(for: selection)
            #expect(e.action == expected)
            #expect(!e.symbol.isEmpty)
            assertTone(e.title, e.message)
        }
    }

    // MARK: - Play Next copy

    @Test func playNextNoRankingsSaysHowManyMoreAreNeeded() {
        let c0 = PlayNextEmptyCopy.noRankings(rankedCount: 0)
        #expect(c0.message.contains("\(TasteBacktest.minSamples) games"))
        assertTone(c0.title, c0.message)

        let c14 = PlayNextEmptyCopy.noRankings(rankedCount: TasteBacktest.minSamples - 1)
        #expect(c14.message.contains("1 game "))   // singular
    }

    @Test func playNextSmallLibraryHintCountsDown() {
        #expect(PlayNextEmptyCopy.smallLibraryHint(rankedCount: 10)
                .contains("\(TasteBacktest.minSamples - 10) more"))
        #expect(PlayNextEmptyCopy.smallLibraryHint(rankedCount: TasteBacktest.minSamples - 1)
                .contains("1 more game "))   // singular
    }

    @Test func playNextBracketAndNothingToPlayCopy() {
        let one = PlayNextEmptyCopy.bracketTooLong(count: 1, bracket: "Short")
        #expect(one.message.contains("1 owned game was"))
        let many = PlayNextEmptyCopy.bracketTooLong(count: 3, bracket: "Short")
        #expect(many.message.contains("3 owned games were"))
        assertTone(one.title, one.message)
        assertTone(PlayNextEmptyCopy.nothingToPlay.title, PlayNextEmptyCopy.nothingToPlay.message)
    }
}

/// The empty-state buttons are genuinely clickable (plain buttons, no menus).
@MainActor
@Suite(.serialized)
struct EmptyStateClickTests {

    @Test(.timeLimit(.minutes(3)))
    func emptyLibraryQuickAddButtonFires() async throws {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
        #expect(vm.isEmptyLibrary)
        let window = ClickProbeWindow(LibraryGridView(vm: vm).frame(minWidth: 700, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        _ = try await window.sweep(band: 620, stepX: 20, stepY: 20,
                                   observe: { vm.quickAddPresented ? 1 : 0 },
                                   until: { vm.quickAddPresented })
        #expect(vm.quickAddPresented, "the empty-library Quick Add button never fired")
    }

    @Test(.timeLimit(.minutes(3)))
    func clearFiltersButtonFires() async throws {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        vm.start()
        var f = LibraryFilter(scope: .all)
        // A bogus search empties the result (the evaluator matches titles); a facet on top makes
        // hasActiveFacets true so the button is the "Clear filters" one (→ clearAllFilters).
        f.searchText = "zzzznomatch4242"
        f.genres = ["RPG"]
        vm.setFilter(f)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!vm.isEmptyLibrary)
        #expect(vm.isEmptyFilterResult)
        #expect(vm.filter.hasActiveFacets)

        let window = ClickProbeWindow(LibraryGridView(vm: vm).frame(minWidth: 700, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        _ = try await window.sweep(band: 620, stepX: 20, stepY: 24,
                                   observe: { vm.isEmptyFilterResult ? 1 : 0 },
                                   until: { !vm.isEmptyFilterResult })
        #expect(!vm.isEmptyFilterResult, "the Clear filters button never cleared the facets")
        #expect(!vm.filter.hasActiveFacets)
    }
}

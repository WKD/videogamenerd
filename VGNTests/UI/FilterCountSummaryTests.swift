import Foundation
import Testing
@testable import VGN

/// The pure "N of M games" filter-count formatter (PLAN §8): 0 / 1 / n forms, the
/// missing-total fallback, the multi-selection suffix, and the loading → nothing rule.
@Suite struct FilterCountSummaryTests {

    @Test func plainCountWithTotal() {
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 0, loaded: true) == "37 of 443 games")
    }

    @Test func singularForms() {
        #expect(FilterCountSummary.text(shown: 1, total: 443, selected: 0, loaded: true) == "1 of 443 games")
        #expect(FilterCountSummary.text(shown: 1, total: nil, selected: 0, loaded: true) == "1 game")
    }

    @Test func zeroShowsNoGames() {
        #expect(FilterCountSummary.text(shown: 0, total: 443, selected: 0, loaded: true) == "No games")
        #expect(FilterCountSummary.text(shown: 0, total: nil, selected: 0, loaded: true) == "No games")
    }

    @Test func compactFormDropsTheOfPart() {
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 0, loaded: true, compact: true) == "37 games")
        #expect(FilterCountSummary.text(shown: 1, total: 443, selected: 0, loaded: true, compact: true) == "1 game")
        #expect(FilterCountSummary.text(shown: 0, total: 443, selected: 0, loaded: true, compact: true) == "No games")
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 5, loaded: true, compact: true)
                == "37 games · 5 selected")
        #expect(FilterCountSummary.text(shown: 0, total: 443, selected: 0, loaded: false, compact: true) == nil)
    }

    @Test func withoutTotalDropsTheOfPart() {
        #expect(FilterCountSummary.text(shown: 37, total: nil, selected: 0, loaded: true) == "37 games")
    }

    @Test func nonsenseTotalBelowShownFallsBackToPlain() {
        // A total smaller than what's shown is not trustworthy → just show the count.
        #expect(FilterCountSummary.text(shown: 37, total: 10, selected: 0, loaded: true) == "37 games")
    }

    @Test func multiSelectionSuffix() {
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 5, loaded: true)
                == "37 of 443 games · 5 selected")
        // A single selection is not a "multi-selection" → no suffix.
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 1, loaded: true) == "37 of 443 games")
    }

    @Test func loadingShowsNothing() {
        #expect(FilterCountSummary.text(shown: 0, total: 443, selected: 0, loaded: false) == nil)
        #expect(FilterCountSummary.text(shown: 37, total: 443, selected: 0, loaded: false) == nil)
    }

    @Test func accessibilityLabel() {
        #expect(FilterCountSummary.accessibilityLabel(shown: 37, total: 443, selected: 0, loaded: true)
                == "37 of 443 games shown")
        #expect(FilterCountSummary.accessibilityLabel(shown: 37, total: 443, selected: 5, loaded: true)
                == "37 of 443 games shown, 5 selected")
        #expect(FilterCountSummary.accessibilityLabel(shown: 0, total: 443, selected: 0, loaded: false) == nil)
    }
}

import Foundation
import Testing
@testable import VGN

/// Pure geometry + banding tests for the playtime UI (PLAN §6.4): the me-vs-average
/// bar layout, the filter buckets, and the derived-score line text.
@Suite struct PlaytimeBarTests {

    private let h = 3600

    // MARK: - Me-vs-average bar

    @Test func barPlacesMarkersAndFill() {
        // Mine 40 h, rushed 27 h, main 32 h, completionist 61 h.
        let bar = PlaytimeBar.make(mineSeconds: 40 * h, rushed: 27 * h, main: 32 * h, completionist: 61 * h)
        #expect(!bar.isEmpty)
        #expect(bar.markers.count == 3)
        // Markers ascend by time.
        #expect(bar.markers.map(\.kind) == [.rushed, .main, .completionist])
        // Scale is above the largest value (completionist 61 h + headroom).
        #expect(bar.scaleMaxSeconds > 61 * h)
        // Fill fraction is mine / scaleMax, strictly inside (0,1).
        #expect(bar.fillFraction > 0 && bar.fillFraction < 1)
        // The completionist marker is the rightmost.
        #expect(bar.markers.last?.fraction == bar.markers.map(\.fraction).max())
        #expect(!bar.exceedsCompletionist)
    }

    @Test func barHandlesExceedingCompletionist() {
        let bar = PlaytimeBar.make(mineSeconds: 120 * h, rushed: 27 * h, main: 32 * h, completionist: 61 * h)
        #expect(bar.exceedsCompletionist)
        // The scale extends to my time, so completionist sits below the fill.
        let comp = bar.markers.first { $0.kind == .completionist }!
        #expect(comp.fraction < bar.fillFraction)
        #expect(bar.fillFraction <= 1)
    }

    @Test func barWithOnlyAveragesHasNoFill() {
        let bar = PlaytimeBar.make(mineSeconds: nil, rushed: nil, main: 32 * h, completionist: 61 * h)
        #expect(bar.mineSeconds == nil)
        #expect(bar.fillFraction == 0)
        #expect(bar.markers.count == 2)
        #expect(!bar.isEmpty)
    }

    @Test func emptyBarWhenNoData() {
        let bar = PlaytimeBar.make(mineSeconds: nil, rushed: nil, main: nil, completionist: nil)
        #expect(bar.isEmpty)
    }

    // MARK: - Filter buckets

    @Test func bucketBoundaries() {
        #expect(PlaytimeBucket.under4.contains(3 * h))
        #expect(!PlaytimeBucket.under4.contains(4 * h))         // 4 h → next band
        #expect(PlaytimeBucket.h4to10.contains(4 * h))
        #expect(PlaytimeBucket.h4to10.contains(9 * h))
        #expect(!PlaytimeBucket.h4to10.contains(10 * h))        // 10 h → next band
        #expect(PlaytimeBucket.h10to40.contains(10 * h))
        #expect(PlaytimeBucket.h10to40.contains(39 * h))
        #expect(!PlaytimeBucket.h10to40.contains(40 * h))       // 40 h → next band
        #expect(PlaytimeBucket.h40to60.contains(40 * h))
        #expect(!PlaytimeBucket.h40to60.contains(60 * h))       // 60 h → next band
        #expect(PlaytimeBucket.h60to80.contains(79 * h))
        #expect(!PlaytimeBucket.h60to80.contains(80 * h))       // 80 h → next band
        #expect(PlaytimeBucket.h80to100.contains(80 * h))
        #expect(!PlaytimeBucket.h80to100.contains(100 * h))
        #expect(PlaytimeBucket.h100to150.contains(100 * h))
        #expect(!PlaytimeBucket.h100to150.contains(150 * h))
        #expect(PlaytimeBucket.h150to200.contains(150 * h))
        #expect(!PlaytimeBucket.h150to200.contains(200 * h))    // 200 h → over200
        #expect(PlaytimeBucket.over200.contains(200 * h))
        #expect(PlaytimeBucket.over200.contains(1000 * h))
    }

    // MARK: - Derived-score line text

    @Test func scoreLinePlacedText() {
        let line = DerivedScoreLine(
            score: DerivedScoreValue(value: 9.6, isApproximate: false),
            tierLetter: "A", tierPosition: 2, tierTotalPlaced: 14,
            overallPosition: 4, overallTotalPlaced: 40, isPlaced: true)
        #expect(line.summary(locale: Locale(identifier: "en_US")) == "9.6 · #4 overall · A, #2 of 14")
    }

    @Test func scoreLineUnplacedText() {
        let line = DerivedScoreLine(
            score: DerivedScoreValue(value: 8.5, isApproximate: true),
            tierLetter: "A", tierPosition: nil, tierTotalPlaced: 14,
            overallPosition: nil, overallTotalPlaced: 40, isPlaced: false)
        #expect(line.summary(locale: Locale(identifier: "en_US")) == "~8.5 · unplaced in A")
    }

    // MARK: - Me-vs-average one-line summary (owner 2026-09-20)

    @Test func comparisonSummaryPercentOfNearestEstimateAbove() {
        // main 100 h, completionist 200 h, rushed 50 h; my 62 h → 62 % of main (nearest above).
        let bar = PlaytimeBar.make(mineSeconds: 62 * h, rushed: 50 * h, main: 100 * h,
                                   completionist: 200 * h)
        let c = bar.comparisonSummary()
        #expect(c?.mineText == "You 62 h")
        #expect(c?.comparison == "62 % of main")
        #expect(c?.beyond == false)
    }

    @Test func comparisonSummaryBeyondEveryEstimate() {
        // my 282 h exceeds completionist (200 h) → 141 % of completionist, emphasised.
        let bar = PlaytimeBar.make(mineSeconds: 282 * h, rushed: 50 * h, main: 100 * h,
                                   completionist: 200 * h)
        let c = bar.comparisonSummary()
        #expect(c?.comparison == "141 % of completionist")
        #expect(c?.beyond == true)
    }

    @Test func comparisonSummaryMidRangePicksNextEstimateUp() {
        // my 150 h sits between main and completionist → nearest above is completionist.
        let bar = PlaytimeBar.make(mineSeconds: 150 * h, rushed: 50 * h, main: 100 * h,
                                   completionist: 200 * h)
        #expect(bar.comparisonSummary()?.comparison == "75 % of completionist")
        #expect(bar.comparisonSummary()?.beyond == false)
    }

    @Test func comparisonSummaryNilWithoutTimeOrEstimates() {
        #expect(PlaytimeBar.make(mineSeconds: nil, rushed: 50 * h, main: 100 * h,
                                 completionist: 200 * h).comparisonSummary() == nil)
        #expect(PlaytimeBar.make(mineSeconds: 62 * h, rushed: nil, main: nil,
                                 completionist: nil).comparisonSummary() == nil)
    }

    // MARK: - HowLongToBeat link

    @Test func hltbURLEncodesTitle() {
        let url = HowLongToBeatLink.searchURL(title: "NieR: Automata")
        #expect(url?.absoluteString.contains("howlongtobeat.com") == true)
        #expect(url?.absoluteString.contains("q=") == true)
        #expect(HowLongToBeatLink.searchURL(title: "   ") == nil)
    }
}

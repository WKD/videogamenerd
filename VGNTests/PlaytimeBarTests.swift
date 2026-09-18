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
        #expect(PlaytimeBucket.short.contains(5 * h))
        #expect(!PlaytimeBucket.short.contains(10 * h))      // 10 h is medium
        #expect(PlaytimeBucket.medium.contains(10 * h))
        #expect(PlaytimeBucket.medium.contains(39 * h))
        #expect(!PlaytimeBucket.medium.contains(40 * h))     // 40 h is long
        #expect(PlaytimeBucket.long.contains(40 * h))
        #expect(PlaytimeBucket.long.contains(200 * h))
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

    // MARK: - HowLongToBeat link

    @Test func hltbURLEncodesTitle() {
        let url = HowLongToBeatLink.searchURL(title: "NieR: Automata")
        #expect(url?.absoluteString.contains("howlongtobeat.com") == true)
        #expect(url?.absoluteString.contains("q=") == true)
        #expect(HowLongToBeatLink.searchURL(title: "   ") == nil)
    }
}

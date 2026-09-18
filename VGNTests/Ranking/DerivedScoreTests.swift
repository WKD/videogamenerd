import Foundation
import Testing
@testable import VGN

/// Pure `DerivedScore` tests (PLAN §7 extension): band edges, monotonic strictly
/// decreasing interpolation across tier boundaries, lone game, unplaced midpoint,
/// non-six tier counts, and formatting.
@Suite(.timeLimit(.minutes(1)))
struct DerivedScoreTests {

    private func slice(_ tier: Int64, sort: Int, placed: [Int64], unplaced: [Int64] = []) -> TierSlice {
        TierSlice(tier: tier, sort: sort,
                  placed: placed.enumerated().map { RankedItem(id: $0.element, key: RankKey(($0.offset + 1) * 1000)) },
                  unplaced: unplaced)
    }

    /// A canonical six-tier snapshot with the given placed/unplaced in the top (S)
    /// tier and the other five tiers empty — so the S band is 9.0–10.0.
    private func sixTierSnapshot(placedInS: [Int64], unplacedInS: [Int64] = []) -> RankSnapshot {
        var tiers = [slice(1, sort: 0, placed: placedInS, unplaced: unplacedInS)]
        for i in 1..<6 { tiers.append(slice(Int64(i + 1), sort: i, placed: [])) }
        return RankSnapshot(tiers: tiers)
    }

    // MARK: Bands

    @Test func sixTiersUseCanonicalBands() {
        let bands = DerivedScore.bands(tierCount: 6)
        #expect(bands.count == 6)
        #expect(bands[0] == (high: 10.0, low: 9.0))
        #expect(bands[5] == (high: 2.9, low: 1.0))
    }

    @Test func nonSixTiersDivideScaleEvenly() {
        let bands = DerivedScore.bands(tierCount: 3)
        #expect(bands[0].high == 10.0)
        #expect(bands[0].low == 7.0)
        #expect(bands[1] == (high: 7.0, low: 4.0))
        #expect(bands[2] == (high: 4.0, low: 1.0))
    }

    // MARK: Interpolation edges

    @Test func firstAndLastGameHitBandEdges() {
        let snap = sixTierSnapshot(placedInS: [10, 11, 12])
        let scores = DerivedScore.scores(snap)
        #expect(scores[10]?.value == 10.0)   // first → band high
        #expect(scores[12]?.value == 9.0)    // last  → band low
        #expect(scores[11]?.value == 9.5)    // middle
    }

    @Test func loneGameSitsAtBandMidpoint() {
        let snap = sixTierSnapshot(placedInS: [10])
        #expect(DerivedScore.scores(snap)[10]?.value == 9.5)
        #expect(DerivedScore.scores(snap)[10]?.isApproximate == false)
    }

    @Test func unplacedGameIsBandMidpointApproximate() {
        let snap = sixTierSnapshot(placedInS: [10, 11], unplacedInS: [99])
        let value = DerivedScore.scores(snap)[99]
        #expect(value?.value == 9.5)
        #expect(value?.isApproximate == true)
    }

    // MARK: Monotonic across the whole list

    @Test func scoresStrictlyDecreaseDownTheGlobalList() {
        let snap = RankSnapshot(tiers: [
            slice(1, sort: 0, placed: [1, 2, 3]),
            slice(2, sort: 1, placed: [4, 5]),
            slice(3, sort: 2, placed: [6]),
            slice(4, sort: 3, placed: [7, 8, 9, 10]),
            slice(5, sort: 4, placed: [11]),
            slice(6, sort: 5, placed: [12, 13]),
        ])
        let scores = DerivedScore.scores(snap)
        let globalOrder: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
        for i in 1..<globalOrder.count {
            let prev = scores[globalOrder[i - 1]]!.value
            let curr = scores[globalOrder[i]]!.value
            #expect(curr < prev, "score at \(i) (\(curr)) should be < previous (\(prev))")
        }
        // Bounds.
        #expect(scores[1]!.value == 10.0)
        #expect(scores[13]!.value >= DerivedScore.scaleBottom)
    }

    // MARK: Formatting

    @Test func formattingRoundsToOneDecimalAndFlagsApproximate() {
        let placed = DerivedScoreValue(value: 9.63, isApproximate: false)
        #expect(placed.csvString == "9.6")
        let approx = DerivedScoreValue(value: 8.5, isApproximate: true)
        #expect(approx.formatted(locale: Locale(identifier: "en_US")) == "~8.5")
        // A comma-decimal locale keeps the CSV dot.
        let fr = DerivedScoreValue(value: 9.6, isApproximate: false)
        #expect(fr.formatted(locale: Locale(identifier: "fr_FR")) == "9,6")
        #expect(fr.csvString == "9.6")
    }
}

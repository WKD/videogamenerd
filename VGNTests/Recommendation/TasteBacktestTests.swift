import Foundation
import Testing
@testable import VGN

/// The leave-one-out taste backtest (PLAN §7b "It checks itself").
struct TasteBacktestTests {

    // MARK: - Recovers a planted preference structure (high ρ ⇒ good)

    @Test func recoversPlantedStructure() throws {
        // Two trait groups: "loved" games score high, "meh" games score low. The
        // model, from the other games, predicts a held-out game's score from its
        // group — so predicted and actual correlate strongly.
        var ranked: [RankedGame] = []
        for i in 0..<20 {
            ranked.append(Rec.ranked(GameID(i + 1), score: 0.70 + Double(i) * 0.012, [Rec.trait(.keyword, "loved")]))
        }
        for i in 0..<20 {
            ranked.append(Rec.ranked(GameID(i + 100), score: 0.05 + Double(i) * 0.010, [Rec.trait(.keyword, "meh")]))
        }
        let result = TasteBacktest.run(ranked: ranked)
        #expect(result.sampleCount == 40)
        let rho = try #require(result.spearman)
        #expect(rho > 0.5)
        #expect(result.verdict == .good)
    }

    // MARK: - Not enough data below the threshold

    @Test func notEnoughDataBelowThreshold() throws {
        let ranked = (1...10).map { Rec.ranked(GameID($0), score: Double($0) / 10, [Rec.trait(.keyword, "x")]) }
        let result = TasteBacktest.run(ranked: ranked)
        #expect(result.verdict == .notEnoughData)
        #expect(result.spearman == nil)
        #expect(result.sampleCount == 10)
    }

    // MARK: - No discriminating structure ⇒ rough

    @Test func noStructureIsRough() throws {
        // Every game shares one trait, scores spread arbitrarily → the model can't
        // discriminate, predicts near-constant → ρ undefined → rough.
        let ranked = (0..<20).map { Rec.ranked(GameID($0 + 1), score: Double($0) / 20, [Rec.trait(.keyword, "same")]) }
        let result = TasteBacktest.run(ranked: ranked)
        #expect(result.verdict == .rough)
    }

    // MARK: - Spearman helper

    @Test func spearmanMonotonicIsOne() throws {
        let a = [1.0, 2, 3, 4, 5]
        let b = [10.0, 20, 30, 40, 50]
        #expect(abs((TasteBacktest.spearman(a, b) ?? 0) - 1.0) < 1e-9)
        let c = [5.0, 4, 3, 2, 1]
        #expect(abs((TasteBacktest.spearman(a, c) ?? 0) + 1.0) < 1e-9)
    }
}

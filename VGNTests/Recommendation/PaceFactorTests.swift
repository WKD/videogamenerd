import Foundation
import Testing
@testable import VGN

/// The personal pace factor (PLAN §7b "Scheduled 2026-09-25"): the pure measurement, the
/// override, the Settings sentence, and how it scales the personal length / Play Next time
/// fit / Vault fit. Pure — no database.
@Suite struct PaceFactorTests {
    private let h = 3600

    /// A finished game that took `mine` hours against a `main`-hour estimate.
    private func sample(_ mine: Double, main: Double?, completionist: Double? = nil,
                        rushed: Double? = nil, completed100: Bool = false,
                        hltb: Bool = false, dismissed: Bool = false) -> PaceFactor.Sample {
        PaceFactor.Sample(playedSeconds: Int(mine * 3600),
                          rushedSeconds: rushed.map { Int($0 * 3600) },
                          mainSeconds: main.map { Int($0 * 3600) },
                          completionistSeconds: completionist.map { Int($0 * 3600) },
                          completed100: completed100, sourceIsHLTB: hltb, dismissed: dismissed)
    }

    // MARK: Median / clamp / minimum samples

    @Test func medianOfAnOddSample() {
        // Ratios 1.0, 1.2, 1.3, 1.5, 1.9 → median 1.3.
        let f = PaceFactor.compute(samples: [
            sample(10, main: 10), sample(12, main: 10), sample(13, main: 10),
            sample(15, main: 10), sample(19, main: 10),
        ])
        #expect(f.sampleCount == 5)
        #expect(f.isMeasured)
        #expect(abs(f.measured - 1.3) < 1e-9)
    }

    @Test func medianOfAnEvenSampleAveragesTheMiddlePair() {
        // Ratios 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 → (1.4 + 1.6) / 2 = 1.5.
        let f = PaceFactor.compute(samples: [1.0, 1.2, 1.4, 1.6, 1.8, 2.0].map { sample($0 * 10, main: 10) })
        #expect(abs(f.measured - 1.5) < 1e-9)
        #expect(f.sampleCount == 6)
    }

    @Test func clampedToPointEightAndTwo() {
        let slow = PaceFactor.compute(samples: (0..<6).map { _ in sample(30, main: 10) })   // 3.0×
        #expect(slow.measured == 2.0)
        #expect(slow.rawMedian == 3.0)
        let fast = PaceFactor.compute(samples: (0..<6).map { _ in sample(5, main: 10) })    // 0.5×
        #expect(fast.measured == 0.8)
    }

    @Test func underFiveSamplesIsOnePointZero() {
        let f = PaceFactor.compute(samples: (0..<4).map { _ in sample(20, main: 10) })
        #expect(f.measured == 1.0)
        #expect(f.sampleCount == 4)
        #expect(!f.isMeasured)
        #expect(f.rawMedian == 2.0)
        #expect(PaceFactor.compute(samples: []) == .unmeasured)
    }

    // MARK: Which samples count

    @Test func suspiciousEstimatesAreExcludedButHLTBAndDismissedCount() {
        // Five clean 1.5× games + three suspicious (completionist ≥ 4× main) at 5×.
        var samples = (0..<5).map { _ in sample(15, main: 10) }
        samples += (0..<3).map { _ in sample(50, main: 10, completionist: 60) }
        let f = PaceFactor.compute(samples: samples)
        #expect(f.sampleCount == 5)
        #expect(abs(f.measured - 1.5) < 1e-9)
        // The same odd times from HowLongToBeat (the reference) or dismissed do count.
        let hltb = PaceFactor.compute(samples: (0..<5).map { _ in sample(50, main: 10, completionist: 60, hltb: true) })
        #expect(hltb.sampleCount == 5)
        let dismissed = PaceFactor.compute(samples: (0..<5).map { _ in sample(50, main: 10, completionist: 60, dismissed: true) })
        #expect(dismissed.sampleCount == 5)
    }

    @Test func hundredPercentUsesCompletionistElseMain() {
        // 100 %: 30 h against a 20 h completionist = 1.5 (not 3.0 against the 10 h main).
        #expect(sample(30, main: 10, completionist: 20, completed100: true).ratio == 1.5)
        // 100 % with no completionist falls back to main.
        #expect(sample(15, main: 10, completed100: true).ratio == 1.5)
        // Finished uses main even when a completionist exists.
        #expect(sample(15, main: 10, completionist: 20).ratio == 1.5)
    }

    @Test func noMainOrNoPlayTimeDoesNotCount() {
        #expect(sample(15, main: nil, completionist: 20).ratio == nil)
        #expect(sample(0, main: 10).ratio == nil)
        // HLTB's Main-Story-only row (main in the rushed slot) has a main (wave 21 read rule).
        #expect(sample(15, main: nil, rushed: 10, hltb: true).ratio == 1.5)
    }

    // MARK: Override

    @Test func overrideWinsAndIsClamped() {
        let f = PaceFactor(measured: 1.3, sampleCount: 109, rawMedian: 1.3)
        #expect(f.effective(override: nil) == 1.3)
        #expect(f.effective(override: 1.1) == 1.1)
        #expect(f.effective(override: 5) == 2.0)
        #expect(f.effective(override: 0.1) == 0.8)
    }

    @Test @MainActor func modelOverrideRoundTripsAndNotifies() {
        let prefs = InMemoryPlayPacePreferences()
        let model = PlayPaceModel(store: prefs)
        var seen: [Double] = []
        model.onPaceFactorChange = { seen.append($0) }
        model.setMeasuredPace(PaceFactor(measured: 1.3, sampleCount: 109, rawMedian: 1.3))
        #expect(model.paceFactor == 1.3)
        model.commitPaceOverride(1.23)          // rounded to one decimal
        #expect(model.paceOverride == 1.2)
        #expect(prefs.paceFactorOverride() == 1.2)
        #expect(model.paceFactor == 1.2)
        // A new measurement while overridden does not move the effective factor.
        model.setMeasuredPace(PaceFactor(measured: 1.6, sampleCount: 110, rawMedian: 1.6))
        #expect(model.paceFactor == 1.2)
        model.commitPaceOverride(nil)           // "Use measured"
        #expect(model.paceFactor == 1.6)
        #expect(prefs.paceFactorOverride() == nil)
        #expect(seen == [1.3, 1.2, 1.6])
    }

    @Test func settingsSentence() {
        let measured = PaceFactor(measured: 1.3, sampleCount: 109, rawMedian: 1.3)
        #expect(PlayPaceModel.paceFactorSummary(measured: measured, override: nil)
                == "You take about 1.3× the advertised time · based on 109 finished games")
        #expect(PlayPaceModel.paceFactorSummary(measured: measured, override: 1.5)
                .hasPrefix("You plan with 1.5× the advertised time (set by hand"))
        let thin = PaceFactor(measured: 1.0, sampleCount: 3, rawMedian: 1.4)
        #expect(PlayPaceModel.paceFactorSummary(measured: thin, override: nil).contains("finish 2 more games"))
    }

    // MARK: Where it applies

    @Test func personalLengthScalesButOneIsIdentity() {
        for style in PlayStyle.allCases {
            let plain = PersonalLength.compute(normallyS: 30 * h, completelyS: 90 * h, style: style)
            let one = PersonalLength.compute(normallyS: 30 * h, completelyS: 90 * h, style: style, paceFactor: 1.0)
            #expect(plain == one)
        }
        let scaled = PersonalLength.compute(normallyS: 30 * h, completelyS: nil, style: .storyFirst, paceFactor: 1.3)
        #expect(scaled?.seconds == 39 * h)
        #expect(scaled?.isApproximate == true)
        #expect(PersonalLength.compute(normallyS: nil, completelyS: nil, style: .storyFirst, paceFactor: 2) == nil)
    }

    @Test func playNextTimeFitUsesTheFactor() {
        // A 35 h game fits "A Few Weeks" (10–40 h) at 1.0; at 1.5× it is 52.5 h — past the
        // 40 h edge but inside the 1.5× falloff, so still shown with a weaker fit and a longer
        // "for you" estimate; at 2.0× (70 h) it is beyond the hard limit (60 h) and excluded.
        let ranked = (1...16).map { Rec.ranked(GameID($0), score: 0.5) }
        let c = Rec.candidate(100, estimateHours: 35, title: "RPG")
        func run(_ factor: Double) -> PlayNextResult {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [c],
                bracket: TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst, paceFactor: factor)))
        }
        #expect(run(1.0).hero?.estimateSeconds == 35 * h)
        #expect(run(1.5).hero?.estimateSeconds == Int(52.5 * 3600))
        #expect(run(2.0).hero == nil)
        #expect(run(2.0).exclusions.byTime == 1)
    }

    @Test func vaultTimeFitUsesTheFactor() {
        let entry = RomCatalogEntry(id: 1, system: "snes", platformID: "snes", relativePath: "a.sfc",
                                    name: "A", lengthMainSeconds: 35 * h)
        let bracket = TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst)
        let one = DiscoverScorer.score(entries: [entry], ranked: [],
                                       options: .init(bracket: bracket, playStyle: .storyFirst))
        let two = DiscoverScorer.score(entries: [entry], ranked: [],
                                       options: .init(bracket: bracket, playStyle: .storyFirst, paceFactor: 2.0))
        let oneFit = one.first?.reasons.compactMap { r -> Int? in
            if case let .fitsBracket(s, _) = r { return s } else { return nil } }.first
        let twoFit = two.first?.reasons.compactMap { r -> Int? in
            if case let .fitsBracket(s, _) = r { return s } else { return nil } }.first
        #expect(oneFit == 35 * h)
        #expect(twoFit == 70 * h)
        #expect((two.first?.score ?? 1) < (one.first?.score ?? 0))
    }

    @Test func textFormat() {
        #expect(PaceFactor.text(1.3) == "1.3×")
        #expect(PaceFactor.text(1.0) == "1.0×")
    }
}

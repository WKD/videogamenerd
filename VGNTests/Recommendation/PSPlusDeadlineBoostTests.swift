import Foundation
import Testing
@testable import VGN

/// The PS Plus deadline ramp (PLAN §16): urgency monotonicity + anchors, finishability edges,
/// the additive boost never overturning a clearly better fit, past-date suppression, and the
/// reason line (omitting unknown parts). Pure — no I/O.
@Suite struct PSPlusDeadlineBoostTests {

    private let pace = PlayPace(hoursPerWeek: 8)

    @Test func urgencyIsMonotonicAndAnchored() {
        // Non-increasing across the whole range.
        var previous = Double.infinity
        for m in stride(from: 0.0, through: 36.0, by: 0.5) {
            let u = PSPlusDeadlineBoost.urgency(monthsLeft: m)
            #expect(u <= previous + 1e-12)
            previous = u
        }
        // Anchors: strongest near the deadline, ½ at six months, modest beyond a year.
        #expect(PSPlusDeadlineBoost.urgency(monthsLeft: 0) == 1)
        #expect(abs(PSPlusDeadlineBoost.urgency(monthsLeft: 6) - 0.5) < 1e-9)
        #expect(PSPlusDeadlineBoost.urgency(monthsLeft: 3) > 0.7)   // last three: strong
        #expect(PSPlusDeadlineBoost.urgency(monthsLeft: 12) < 0.25) // beyond a year: modest
    }

    @Test func finishabilityEdges() {
        // hoursLeft at 9 months, 8 h/week ≈ 9 · 4.33 · 8 ≈ 312 h.
        let months = 9.0
        // A 22 h game (well under half) is fully finishable.
        let short = PSPlusDeadlineBoost.finishability(personalLengthSeconds: 22 * 3600,
                                                      monthsLeft: months, pace: pace)
        #expect(short == 1)
        // A 120 h game is roughly a third — still comfortably above zero, below full.
        let mid = PSPlusDeadlineBoost.finishability(personalLengthSeconds: 120 * 3600,
                                                    monthsLeft: months, pace: pace)
        #expect(mid == 1)   // 120/312 ≈ 0.38 < 0.5 ⇒ still full
        // A 300 h game nearly fills the window ⇒ fades.
        let long = PSPlusDeadlineBoost.finishability(personalLengthSeconds: 300 * 3600,
                                                     monthsLeft: months, pace: pace)
        #expect(long > 0 && long < 1)
        // A game that no longer fits ⇒ zero.
        let tooLong = PSPlusDeadlineBoost.finishability(personalLengthSeconds: 400 * 3600,
                                                        monthsLeft: months, pace: pace)
        #expect(tooLong == 0)
        // Unknown length ⇒ neutral ½.
        let unknown = PSPlusDeadlineBoost.finishability(personalLengthSeconds: nil,
                                                        monthsLeft: months, pace: pace)
        #expect(unknown == 0.5)
    }

    @Test func boostGrowsAsDeadlineNears() {
        let far = PSPlusDeadlineBoost.boost(monthsLeft: 18, personalLengthSeconds: 22 * 3600, pace: pace)
        let near = PSPlusDeadlineBoost.boost(monthsLeft: 2, personalLengthSeconds: 22 * 3600, pace: pace)
        #expect(near > far)
        #expect(near <= PSPlusDeadlineBoost.constants.maxBoost + 1e-12)
    }

    @Test func noDateOrPastGivesNoBoost() {
        #expect(PSPlusDeadlineBoost.boost(monthsLeft: nil, personalLengthSeconds: 22 * 3600, pace: pace) == 0)
        #expect(PSPlusDeadlineBoost.boost(monthsLeft: -3, personalLengthSeconds: 22 * 3600, pace: pace) == 0)
    }

    @Test func neverOverturnsAClearlyBetterFit() {
        // A clearly better game scores 0.2 higher; even the strongest, fully-finishable boost
        // cannot lift the PS Plus game past it.
        let baseWeaker = 0.50
        let baseBetter = 0.70
        let strongest = PSPlusDeadlineBoost.boost(monthsLeft: 0.1, personalLengthSeconds: 3600, pace: pace)
        #expect(baseWeaker + strongest < baseBetter)
    }

    @Test func pastDateDetection() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15
        // A month clearly in the past.
        #expect(PSPlusDeadlineBoost.isPast(now: now, year: 2024, month: 1))
        // A future month.
        #expect(!PSPlusDeadlineBoost.isPast(now: now, year: 2027, month: 1))
        // monthsLeft sign follows.
        #expect(PSPlusDeadlineBoost.monthsLeft(now: now, year: 2024, month: 1) < 0)
        #expect(PSPlusDeadlineBoost.monthsLeft(now: now, year: 2027, month: 1) > 0)
    }

    @Test func reasonOmitsUnknownParts() {
        // Full reason.
        #expect(PSPlusDeadlineBoost.reason(monthsLeft: 9, personalLengthSeconds: 22 * 3600)
                == "＋ leaves with PS Plus · ~9 months left · about 22 h for you")
        // Unknown length ⇒ no hours clause.
        #expect(PSPlusDeadlineBoost.reason(monthsLeft: 9, personalLengthSeconds: nil)
                == "＋ leaves with PS Plus · ~9 months left")
        // No date ⇒ no months clause (the constant-fallback case).
        #expect(PSPlusDeadlineBoost.reason(monthsLeft: nil, personalLengthSeconds: 40 * 3600)
                == "＋ leaves with PS Plus · about 40 h for you")
        // Singular month.
        #expect(PSPlusDeadlineBoost.reason(monthsLeft: 1, personalLengthSeconds: nil)
                == "＋ leaves with PS Plus · ~1 month left")
    }
}

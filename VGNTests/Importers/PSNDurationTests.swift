import Foundation
import Testing
@testable import VGN

/// The strict ISO-8601 duration parser for the game list's `playDuration` (PLAN §13.3).
@Suite struct PSNDurationTests {
    @Test func parsesTimeComponents() {
        #expect(PSNDuration.seconds(fromISO8601: "PT0S") == 0)
        #expect(PSNDuration.seconds(fromISO8601: "PT52M10S") == 52 * 60 + 10)
        #expect(PSNDuration.seconds(fromISO8601: "PT228H56M33S") == 228 * 3600 + 56 * 60 + 33)
        #expect(PSNDuration.seconds(fromISO8601: "PT2H") == 7200)
        #expect(PSNDuration.seconds(fromISO8601: "PT90M") == 5400)
    }

    /// Exact strings seen on the real account (live, 2026-09-20).
    @Test func parsesRealAccountDurations() {
        #expect(PSNDuration.seconds(fromISO8601: "PT33H34M17S") == 33 * 3600 + 34 * 60 + 17)
        #expect(PSNDuration.seconds(fromISO8601: "PT5M22S") == 5 * 60 + 22)          // Myst: 322 s
        #expect(PSNDuration.seconds(fromISO8601: "PT221H51M37S") == 221 * 3600 + 51 * 60 + 37)
        // Myst's 322 s stays under the 30-min played-promotion floor.
        #expect((PSNDuration.seconds(fromISO8601: "PT5M22S") ?? 0) < PSNMapping.playedPromotionSeconds)
    }

    @Test func parsesDateAndMixedComponents() {
        #expect(PSNDuration.seconds(fromISO8601: "P1D") == 86_400)
        #expect(PSNDuration.seconds(fromISO8601: "P1DT2H") == 86_400 + 7200)
        #expect(PSNDuration.seconds(fromISO8601: "P1W") == 7 * 86_400)
    }

    @Test func parsesFractionalSeconds() {
        #expect(PSNDuration.seconds(fromISO8601: "PT1.5S") == 2)   // rounds
        #expect(PSNDuration.seconds(fromISO8601: "PT0.4S") == 0)
    }

    @Test func rejectsGarbage() {
        #expect(PSNDuration.seconds(fromISO8601: "") == nil)
        #expect(PSNDuration.seconds(fromISO8601: "P") == nil)
        #expect(PSNDuration.seconds(fromISO8601: "228H56M33S") == nil)   // no leading P
        #expect(PSNDuration.seconds(fromISO8601: "PTABC") == nil)
        #expect(PSNDuration.seconds(fromISO8601: "hello") == nil)
        #expect(PSNDuration.seconds(fromISO8601: "PT") == nil)          // P/T but no value
    }
}

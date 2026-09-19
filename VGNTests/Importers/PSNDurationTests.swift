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

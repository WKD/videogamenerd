import Foundation
import Testing
@testable import VGN

/// The playtime band model (PLAN §8 "Playtime bands"): the single bounds table
/// drives labels + bounds, bands tile the axis with no gap/overlap, and the removed
/// `long` raw value decodes gracefully (nothing persists these, but a stray value
/// must not crash or wipe the facet).
struct PlaytimeBucketTests {
    private let h = 3600

    @Test func labelsAndOrder() {
        #expect(PlaytimeBucket.allCases.map(\.label) == [
            "< 10 h", "10–40 h", "40–60 h", "60–80 h",
            "80–100 h", "100–150 h", "150–200 h", "> 200 h",
        ])
    }

    /// Bands are contiguous and disjoint: each band's upper bound is the next band's
    /// lower bound, the first is open below and the last open above.
    @Test func bandsTileTheAxisWithoutGapOrOverlap() {
        let bands = PlaytimeBucket.allCases
        #expect(bands.first?.lowerSeconds == nil)
        #expect(bands.last?.upperSeconds == nil)
        for (a, b) in zip(bands, bands.dropFirst()) {
            #expect(a.upperSeconds == b.lowerSeconds, "\(a) → \(b) must be contiguous")
        }
        // Every whole-hour value from 0…260 lands in exactly one band.
        for hours in 0...260 {
            let matches = bands.filter { $0.contains(hours * h) }
            #expect(matches.count == 1, "\(hours) h landed in \(matches.count) bands")
        }
    }

    @Test func stableRawValuesForKeptCases() {
        // `short` (< 10 h) and `medium` (10–40 h) kept their meaning and raw value.
        #expect(PlaytimeBucket.short.rawValue == "short")
        #expect(PlaytimeBucket.medium.rawValue == "medium")
        #expect(PlaytimeBucket.short.hourBounds.upper == 10)
        #expect(PlaytimeBucket.medium.hourBounds == (10, 40))
    }

    @Test func removedLongRawValueDecodesToNil() {
        // The old "> 40 h" case no longer exists; its raw value is simply unknown, so
        // the failable init returns nil (a stray stored value is ignored, never a crash).
        #expect(PlaytimeBucket(rawValue: "long") == nil)
        #expect(PlaytimeBucket(rawValue: "anything") == nil)
        // Codable round-trips of valid cases still work.
        for band in PlaytimeBucket.allCases {
            let data = try! JSONEncoder().encode(band)
            #expect(try! JSONDecoder().decode(PlaytimeBucket.self, from: data) == band)
        }
    }
}

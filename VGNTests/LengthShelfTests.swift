import Foundation
import AppKit
import Testing
@testable import VGN

/// The "By Length" shelf model (PLAN §8): pace-derived hour edges snapped to the
/// "nice hours" ladder, generated subtitles/tooltips, stable ids, and existing SF
/// Symbols. Pure — no DB, no UI.
struct LengthShelfTests {

    private func edges(_ hpw: Double) -> [Double] {
        LengthShelf.bounds(for: PlayPace(hoursPerWeek: hpw)).edgesHours
    }

    // MARK: - Required bound results (the owner's examples)

    @Test func boundsAtRequiredPaces() {
        #expect(edges(8) == [4, 10, 40, 80])      // default — today's constants
        #expect(edges(2) == [2, 3, 10, 20])       // owner's example: "a few weeks" = 10 h
        #expect(edges(1) == [1, 1.5, 5, 10])
        #expect(edges(20) == [4, 25, 100, 200])
    }

    @Test func paceIsClampedToOneThroughSixty() {
        #expect(PlayPace(hoursPerWeek: 0).hoursPerWeek == 1)
        #expect(PlayPace(hoursPerWeek: 1000).hoursPerWeek == 60)
        #expect(PlayPace(hoursPerWeek: .nan).hoursPerWeek == PlayPace.default.hoursPerWeek)
        #expect(PlayPace.default.hoursPerWeek == 8)
    }

    /// For every integer pace 1…60 the four edges are strictly increasing and every
    /// value is on the ladder. 60 h/week is included (stays strictly increasing).
    @Test func boundsStrictlyIncreasingAndOnLadderForEveryPace() {
        let ladder = Set(LengthShelf.niceHours)
        for hpw in 1...60 {
            let e = edges(Double(hpw))
            #expect(e.count == 4)
            for value in e { #expect(ladder.contains(value), "\(hpw) h/week edge \(value) off ladder") }
            for (a, b) in zip(e, e.dropFirst()) {
                #expect(a < b, "\(hpw) h/week edges not strictly increasing: \(e)")
            }
        }
    }

    /// At the DEFAULT pace only, the shelf edges line up with ``PlaytimeBucket`` band
    /// edges (so the two tables cannot silently drift for the common case).
    @Test func defaultPaceEdgesLineUpWithPlaytimeBucketEdges() {
        let bucketEdges = Set(PlaytimeBucket.allCases.flatMap { b -> [Int] in
            [b.hourBounds.lower, b.hourBounds.upper].compactMap { $0 }
        })
        for edge in edges(8) {
            #expect(bucketEdges.contains(Int(edge)), "default edge \(edge) is not a PlaytimeBucket boundary")
        }
        #expect(edges(8) == [4, 10, 40, 80])
    }

    // MARK: - Ladder snapping

    @Test func snapRoundsTiesUp() {
        #expect(LengthShelf.snapToLadder(2.5) == 3)     // tie 2/3 → up
        #expect(LengthShelf.snapToLadder(1.25) == 1.5)  // tie 1/1.5 → up
        #expect(LengthShelf.snapToLadder(75) == 80)     // nearer 80 than 60
        #expect(LengthShelf.snapToLadder(600) == 500)   // above the ladder → its max
    }

    // MARK: - Generated strings

    @Test func subtitlesForRepresentativePaces() {
        func subs(_ hpw: Double) -> [String] {
            let bounds = LengthShelf.bounds(for: PlayPace(hoursPerWeek: hpw))
            return LengthShelf.allCases.map { $0.subtitle(bounds: bounds) }
        }
        #expect(subs(8) == ["under 4 h", "4–10 h", "10–40 h", "40–80 h", "80 h and more"])
        #expect(subs(2) == ["under 2 h", "2–3 h", "3–10 h", "10–20 h", "20 h and more"])
        #expect(subs(1) == ["under 1 h", "1–1½ h", "1½–5 h", "5–10 h", "10 h and more"])
    }

    @Test func tooltipsCarryPaceAndRange() {
        let p2 = PlayPace(hoursPerWeek: 2)
        let b2 = LengthShelf.bounds(for: p2)
        #expect(LengthShelf.fewWeeks.tooltip(pace: p2, bounds: b2)
                == "Games you can finish in a few weeks at 2 h a week — 3 to 10 hours (time-to-beat estimate)")
        #expect(LengthShelf.evening.tooltip(pace: p2, bounds: b2)
                == "Games you can finish in one evening at 2 h a week — under 2 hours (time-to-beat estimate)")
        #expect(LengthShelf.epic.tooltip(pace: p2, bounds: b2)
                == "The long ones — 20 hours and more (time-to-beat estimate)")

        let p8 = PlayPace(hoursPerWeek: 8)
        let b8 = LengthShelf.bounds(for: p8)
        #expect(LengthShelf.season.tooltip(pace: p8, bounds: b8)
                == "Games you can finish over a season at 8 h a week — 40 to 80 hours (time-to-beat estimate)")
    }

    @Test func formatHoursRendersHalves() {
        #expect(LengthShelf.formatHours(1.5) == "1½")
        #expect(LengthShelf.formatHours(10) == "10")
        #expect(LengthShelf.formatHours(4) == "4")
    }

    // MARK: - Stable identity + symbols

    @Test func stableIdsAndOrder() {
        #expect(LengthShelf.allCases.map(\.id) == ["evening", "weekend", "fewWeeks", "season", "epic"])
        #expect(SidebarSelection.length(.evening).id == "length:evening")
        #expect(SidebarSelection.length(.epic).id == "length:epic")
        #expect(SidebarSelection.unmeasured.id == "unmeasured")
        #expect(SidebarSelection.lengthShelves == LengthShelf.allCases.map(SidebarSelection.length))
    }

    /// Every shelf symbol (and the Unmeasured symbol) must exist on this macOS, so a
    /// typo fails loudly here rather than showing a blank row.
    @Test func symbolsExistOnThisSystem() {
        for shelf in LengthShelf.allCases {
            #expect(NSImage(systemSymbolName: shelf.symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(shelf.symbol) for \(shelf)")
        }
        #expect(NSImage(systemSymbolName: LengthShelf.unmeasuredSymbol, accessibilityDescription: nil) != nil)
    }
}

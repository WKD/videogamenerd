import Foundation
import Testing
@testable import VGN

struct IGDBYearQueryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-19T00:00:00Z")!

    @Test func trailingYearIsSplitOff() {
        let s = IGDBAutocomplete.splitYear("super mario bros 1985", now: now)
        #expect(s.text == "super mario bros")
        #expect(s.year == 1985)
    }

    @Test func parenthesisedAndLeadingYearsWork() {
        #expect(IGDBAutocomplete.splitYear("super mario bros (1985)", now: now).year == 1985)
        let lead = IGDBAutocomplete.splitYear("1993 doom", now: now)
        #expect(lead.text == "doom")
        #expect(lead.year == 1993)
    }

    @Test func aTitleThatIsOnlyAYearStaysATitle() {
        #expect(IGDBAutocomplete.splitYear("1942", now: now).year == nil)
        #expect(IGDBAutocomplete.splitYear("2048", now: now).year == nil)
    }

    @Test func outOfRangeNumbersAreNotYears() {
        #expect(IGDBAutocomplete.splitYear("cyberpunk 2077", now: now).year == nil)   // future
        #expect(IGDBAutocomplete.splitYear("anno 1602", now: now).year == nil)        // before 1970
        #expect(IGDBAutocomplete.splitYear("final fantasy 7", now: now).year == nil)
        #expect(IGDBAutocomplete.splitYear("forza 12345", now: now).year == nil)
    }

    @Test func lastCandidateWins() {
        let s = IGDBAutocomplete.splitYear("fifa 2005 2004", now: now)
        #expect(s.year == 2004)
        #expect(s.text == "fifa 2005")
    }

    @Test func yearBecomesAReleaseDatesClause() {
        let q = IGDBAutocomplete.searchQuery("super mario bros", platformIGDBIDs: [18], limit: 12, releaseYear: 1985).build()
        #expect(q.contains(#"search "super mario bros""#))
        #expect(q.contains("release_dates.y = 1985"))
        #expect(q.contains("platforms = (18)"))
        let p = IGDBAutocomplete.namePrefixQuery("super mario bros", platformIGDBIDs: nil, limit: 12, releaseYear: 1988).build()
        #expect(p.contains("release_dates.y = 1988"))
        #expect(!IGDBAutocomplete.searchQuery("zelda", platformIGDBIDs: nil, limit: 12).build().contains("release_dates"))
    }
}

@MainActor
struct QuickAddYearOrderingTests {
    @Test func entriesOfTheTypedYearAreKeptWhenAnyMatch() {
        let items = [(1993, "SNES"), (1985, "NES"), (1986, "Arcade")]
        let out = QuickAddModel.yearFirst(items, year: 1985, yearOf: { $0.0 })
        #expect(out.map(\.1) == ["NES"])
    }

    @Test func aYearThatMatchesNothingHidesNothing() {
        let items = [(1993, "SNES"), (1986, "Arcade")]
        #expect(QuickAddModel.yearFirst(items, year: 1985, yearOf: { $0.0 }).count == 2)
        #expect(QuickAddModel.yearFirst(items, year: nil, yearOf: { $0.0 }).count == 2)
    }
}

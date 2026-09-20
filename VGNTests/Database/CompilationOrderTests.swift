import Foundation
import Testing
@testable import VGN

/// D3: members of a compilation created from an IGDB bundle order by first release date
/// ascending, unknown dates last, ties by IGDB order — one shared pure function
/// (`LibraryStore.orderedByReleaseDate`). The array order is preserved; only `position`
/// changes (so callers that index into the array are unaffected).
struct CompilationOrderTests {

    private func member(_ title: String, year: Int? = nil, date: Date? = nil, position: Int) -> CompilationMemberDraft {
        CompilationMemberDraft(title: title, releaseDate: date, year: year, position: position)
    }

    /// `position` keyed by title, after ordering.
    private func positions(_ members: [CompilationMemberDraft]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: LibraryStore.orderedByReleaseDate(members).map { ($0.title, $0.position) })
    }

    @Test("Orders by year ascending, reassigning position")
    func byYear() {
        let out = positions([
            member("MGS4", year: 2008, position: 0),
            member("MGS2", year: 2001, position: 1),
            member("MGS3", year: 2004, position: 2),
        ])
        #expect(out["MGS2"] == 0)
        #expect(out["MGS3"] == 1)
        #expect(out["MGS4"] == 2)
    }

    @Test("Array order is preserved; only positions change")
    func preservesArrayOrder() {
        let input = [
            member("MGS4", year: 2008, position: 0),
            member("MGS2", year: 2001, position: 1),
        ]
        let out = LibraryStore.orderedByReleaseDate(input)
        #expect(out.map(\.title) == ["MGS4", "MGS2"])   // same array order
        #expect(out[0].position == 1)                    // MGS4 sorts second
        #expect(out[1].position == 0)                    // MGS2 sorts first
    }

    @Test("Unknown dates sort last, keeping IGDB order among themselves")
    func unknownsLast() {
        let out = positions([
            member("NoDateA", position: 0),
            member("Dated", year: 1999, position: 1),
            member("NoDateB", position: 2),
        ])
        #expect(out["Dated"] == 0)
        #expect(out["NoDateA"] == 1)   // first unknown keeps its earlier IGDB order
        #expect(out["NoDateB"] == 2)
    }

    @Test("Same year ties keep IGDB order")
    func tiesKeepIGDBOrder() {
        let out = positions([
            member("First", year: 2010, position: 0),
            member("Second", year: 2010, position: 1),
        ])
        #expect(out["First"] == 0)
        #expect(out["Second"] == 1)
    }

    @Test("A precise release date beats a bare year within the same year")
    func dateFinerThanYear() {
        let june2001 = DateComponents(calendar: Calendar(identifier: .gregorian),
                                      timeZone: TimeZone(identifier: "UTC"),
                                      year: 2001, month: 6, day: 1).date!
        let out = positions([
            member("YearOnly2002", year: 2002, position: 0),
            member("Dated2001", date: june2001, position: 1),
        ])
        #expect(out["Dated2001"] == 0)
        #expect(out["YearOnly2002"] == 1)
    }
}

import Foundation
import Testing
@testable import VGN

/// The pure merge behind ``IGDBAutocomplete`` (PLAN §5.1): search order first,
/// name-prefix and alt-name fallbacks after, de-duped by game id and capped. The
/// live network behaviour was verified with a scratch script (see the handoff).
@Suite(.timeLimit(.minutes(1)))
struct IGDBAutocompleteTests {

    @Test func mergeKeepsSearchOrderAndDedupesByID() {
        let search = [makeSearchResult(id: 1, name: "Bloodborne"),
                      makeSearchResult(id: 2, name: "Bloodborne GOTY")]
        let namePrefix = [makeSearchResult(id: 2, name: "Bloodborne GOTY"),   // dup of id 2
                          makeSearchResult(id: 3, name: "Bloodbath")]
        let altName = [makeSearchResult(id: 4, name: "Broken Sword")]

        let merged = IGDBAutocomplete.merge([search, namePrefix, altName], limit: 12)
        #expect(merged.map(\.id) == [1, 2, 3, 4])           // search first, no id repeats
    }

    @Test func mergeCapsToLimit() {
        let groups = [[makeSearchResult(id: 1, name: "A"), makeSearchResult(id: 2, name: "B")],
                      [makeSearchResult(id: 3, name: "C")]]
        #expect(IGDBAutocomplete.merge(groups, limit: 2).map(\.id) == [1, 2])
    }

    @Test func mergeIgnoresEmptyGroups() {
        let merged = IGDBAutocomplete.merge([[], [makeSearchResult(id: 5, name: "Ico")], []], limit: 12)
        #expect(merged.map(\.id) == [5])
    }
}

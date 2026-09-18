import Testing
@testable import VGN

/// The active-filter chips model (PLAN §8): grouping, ordering, text, removal, clear.
struct FilterChipTests {
    private let tiers = [
        TierInfo(id: 1, letter: "S", label: "Masterpiece", colorHex: "#FF3B30", sort: 0),
        TierInfo(id: 2, letter: "A", label: "Excellent", colorHex: "#FF9500", sort: 1),
    ]

    private func fullFilter() -> LibraryFilter {
        var f = LibraryFilter(scope: .all)
        f.searchText = "souls"
        f.genres = ["RPG", "Adventure"]
        f.decades = [2010, 1990]
        f.tierIDs = [2, 1]
        f.statuses = [.finished]
        f.formats = [.rom, .physical]
        f.platforms = ["snes", "ps4"]
        return f
    }

    @Test func chipsGroupedOrderedAndTexted() {
        let chips = LibraryFilterChips.chips(for: fullFilter(), tiers: tiers,
                                             platformShort: { $0.uppercased() })
        // Kind order: search, genre, decade, tier, status, format, platform.
        #expect(chips.map(\.kind) == [
            .search, .genre, .genre, .decade, .decade, .tier, .tier,
            .status, .format, .format, .platform, .platform,
        ])
        // One value each; the first of a group leads with the "Kind:" prefix.
        let genres = chips.filter { $0.kind == .genre }
        #expect(genres.map(\.valueLabel) == ["Adventure", "RPG"])       // sorted
        #expect(genres[0].text == "Genre: Adventure")
        #expect(genres[1].text == "or RPG")                             // reads "…Adventure or RPG"
        // Tiers ordered by tier.sort (S before A), labelled by letter.
        #expect(chips.filter { $0.kind == .tier }.map(\.valueLabel) == ["S", "A"])
        // Decades formatted, sorted ascending.
        #expect(chips.filter { $0.kind == .decade }.map(\.valueLabel) == ["1990s", "2010s"])
        // Format uses ProductFormat order (physical before rom).
        #expect(chips.filter { $0.kind == .format }.map(\.valueLabel) == ["Physical", "ROM"])
        // Platform slugs sorted, labelled via the short closure.
        #expect(chips.filter { $0.kind == .platform }.map(\.valueLabel) == ["PS4", "SNES"])
        // Search chip carries the query.
        #expect(chips.first?.kind == .search)
        #expect(chips.first?.fullLabel == "Search: “souls”")
        // Stable, unique ids.
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    @Test func removingOneValueLeavesTheRest() {
        var f = fullFilter()
        let chips = LibraryFilterChips.chips(for: f, tiers: tiers)
        let rpg = try! #require(chips.first { $0.kind == .genre && $0.valueLabel == "RPG" })
        f = LibraryFilterChips.removing(rpg, from: f)
        #expect(f.genres == ["Adventure"])
        // Removing the SNES platform chip.
        let snes = try! #require(chips.first { $0.kind == .platform && $0.value == "snes" })
        f = LibraryFilterChips.removing(snes, from: f)
        #expect(f.platforms == ["ps4"])
        // Removing the search chip clears the text.
        let search = try! #require(chips.first { $0.kind == .search })
        f = LibraryFilterChips.removing(search, from: f)
        #expect(f.searchText.isEmpty)
    }

    @Test func clearAllKeepsScopeAndSort() {
        var f = fullFilter()
        f.scope = .played
        f.sort = .year
        f.ascending = false
        let cleared = LibraryFilterChips.cleared(f)
        #expect(!cleared.hasActiveFacets)
        #expect(LibraryFilterChips.chips(for: cleared, tiers: tiers).isEmpty)
        #expect(cleared.scope == .played)
        #expect(cleared.sort == .year)
        #expect(cleared.ascending == false)
    }

    @Test func noChipsWhenNoFacets() {
        #expect(LibraryFilterChips.chips(for: LibraryFilter(scope: .all), tiers: tiers).isEmpty)
    }
}

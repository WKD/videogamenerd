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

    // MARK: - Extra facets ("Unrated" / "Not Played" / "No Status" / "Not Owned")

    @Test func extraFacetChipsRenderStandaloneOrderedAndRemoveOnlyTheFlag() {
        var f = LibraryFilter(scope: .all)
        f.tierIDs = [1]
        f.includeUnrated = true
        f.includeNotPlayed = true
        f.includeNoStatus = true
        f.formats = [.physical]
        f.includeNotOwned = true
        let chips = LibraryFilterChips.chips(for: f, tiers: tiers)
        // Each standalone chip follows its kind group, in menu order.
        #expect(chips.map(\.kind) == [.tier, .unrated, .notPlayed, .noStatus, .format, .notOwned])

        let unrated = try! #require(chips.first { $0.kind == .unrated })
        #expect(unrated.text == "Unrated")          // standalone, no "Kind: value" split
        #expect(unrated.fullLabel == "Unrated")

        // Removing one flag chip clears only that flag.
        let afterUnrated = LibraryFilterChips.removing(unrated, from: f)
        #expect(afterUnrated.includeUnrated == false)
        #expect(afterUnrated.tierIDs == [1])
        #expect(afterUnrated.includeNotPlayed == true)

        #expect(LibraryFilterChips.removing(
            try! #require(chips.first { $0.kind == .notPlayed }), from: f).includeNotPlayed == false)
        #expect(LibraryFilterChips.removing(
            try! #require(chips.first { $0.kind == .noStatus }), from: f).includeNoStatus == false)
        #expect(LibraryFilterChips.removing(
            try! #require(chips.first { $0.kind == .notOwned }), from: f).includeNotOwned == false)

        #expect(chips.first { $0.kind == .notOwned }?.text == "Not Owned")
        #expect(Set(chips.map(\.id)).count == chips.count)   // unique ids
    }

    // MARK: - Playtime bands + "No Estimate"

    @Test func playtimeBandAndNoEstimateChips() {
        var f = LibraryFilter(scope: .all)
        f.playtimes = [.over200, .under4, .h80to100]
        f.includeNoTimeEstimate = true
        let chips = LibraryFilterChips.chips(for: f, tiers: tiers)
        // Band chips in canonical (ascending) order, then the standalone No Estimate.
        #expect(chips.map(\.kind) == [.playtime, .playtime, .playtime, .noEstimate])
        #expect(chips.filter { $0.kind == .playtime }.map(\.valueLabel)
                == ["< 4 h", "80–100 h", "> 200 h"])
        #expect(chips.first?.text == "Playtime: < 4 h")
        #expect(chips.dropFirst().first?.text == "or 80–100 h")

        let noEstimate = try! #require(chips.first { $0.kind == .noEstimate })
        #expect(noEstimate.text == "No Estimate")          // standalone
        #expect(noEstimate.fullLabel == "No Estimate")

        // Removing a band chip leaves the rest and the flag.
        let under4 = try! #require(chips.first { $0.kind == .playtime && $0.value == "under4" })
        let afterUnder4 = LibraryFilterChips.removing(under4, from: f)
        #expect(afterUnder4.playtimes == [.over200, .h80to100])
        #expect(afterUnder4.includeNoTimeEstimate == true)

        // Removing the No Estimate chip clears only the flag.
        let afterNoEst = LibraryFilterChips.removing(noEstimate, from: f)
        #expect(afterNoEst.includeNoTimeEstimate == false)
        #expect(afterNoEst.playtimes == [.over200, .under4, .h80to100])
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    @Test func noEstimateCountsAsActiveAndClearsWithAll() {
        #expect(LibraryFilter(includeNoTimeEstimate: true, scope: .all).hasActiveFacets)
        var f = LibraryFilter(scope: .all)
        f.playtimes = [.h10to40]
        f.includeNoTimeEstimate = true
        let cleared = LibraryFilterChips.cleared(f)
        #expect(cleared.playtimes.isEmpty)
        #expect(cleared.includeNoTimeEstimate == false)
        #expect(!cleared.hasActiveFacets)
    }

    @Test func multipleCopiesChipIsStandaloneAndRemovable() {
        var f = LibraryFilter(scope: .all)
        f.multipleCopies = true
        #expect(f.hasActiveFacets)
        let chips = LibraryFilterChips.chips(for: f, tiers: tiers)
        let chip = try! #require(chips.first { $0.kind == .multipleCopies })
        #expect(chip.text == "Multiple Copies")       // standalone facet
        #expect(chip.fullLabel == "Multiple Copies")
        let removed = LibraryFilterChips.removing(chip, from: f)
        #expect(removed.multipleCopies == false)
        #expect(!removed.hasActiveFacets)
    }

    @Test func clearAllDropsMultipleCopiesButKeepsPace() {
        var f = LibraryFilter(scope: .all, playPace: PlayPace(hoursPerWeek: 3))
        f.multipleCopies = true
        f.formats = [.physical]
        let cleared = LibraryFilterChips.cleared(f)
        #expect(cleared.multipleCopies == false)
        #expect(!cleared.hasActiveFacets)
        #expect(cleared.playPace == PlayPace(hoursPerWeek: 3))   // pace is not a facet
    }

    @Test func playedNoStatusChipLabel() {
        var f = LibraryFilter(scope: .all)
        f.includeNoStatus = true
        let chip = try! #require(LibraryFilterChips.chips(for: f, tiers: tiers)
            .first { $0.kind == .noStatus })
        #expect(chip.text == "Played, No Status")
        #expect(chip.fullLabel == "Played, No Status")
    }

    @Test func extraFlagsCountAsActiveFacetsAndClearAllResetsThem() {
        #expect(LibraryFilter(includeUnrated: true, scope: .all).hasActiveFacets)
        #expect(LibraryFilter(includeNotPlayed: true, scope: .all).hasActiveFacets)
        #expect(LibraryFilter(includeNoStatus: true, scope: .all).hasActiveFacets)
        #expect(LibraryFilter(includeNotOwned: true, scope: .all).hasActiveFacets)
        #expect(!LibraryFilter(scope: .all).hasActiveFacets)

        var f = LibraryFilter(scope: .all)
        f.includeUnrated = true
        f.includeNotPlayed = true
        f.includeNoStatus = true
        f.includeNotOwned = true
        let cleared = LibraryFilterChips.cleared(f)
        #expect(cleared.includeUnrated == false)
        #expect(cleared.includeNotPlayed == false)
        #expect(cleared.includeNoStatus == false)
        #expect(cleared.includeNotOwned == false)
        #expect(!cleared.hasActiveFacets)
        #expect(LibraryFilterChips.chips(for: cleared, tiers: tiers).isEmpty)
    }
}

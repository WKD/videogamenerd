import Testing
@testable import VGN

struct SidebarGroupingTests {

    private func platform(_ id: String, _ name: String, group: String, sort: Int) -> PlatformInfo {
        PlatformInfo(id: id, name: name, short: name, manufacturer: group,
                     group: group, kind: .console, sort: sort)
    }

    @Test func groupsOrderedAndSortedWithinGroup() {
        let platforms = [
            platform("ps4", "PS4", group: "Sony", sort: 20),
            platform("ps5", "PS5", group: "Sony", sort: 10),   // lower sort ⇒ first
            platform("switch", "Switch", group: "Nintendo", sort: 20),
            platform("genesis", "Mega Drive", group: "Sega", sort: 50),
        ]
        let counts = SidebarCounts(perPlatform: ["ps4": 3, "ps5": 8, "switch": 4, "genesis": 2])
        let groups = SidebarPlatformGrouping.groups(platforms: platforms, counts: counts)

        // Canonical manufacturer order.
        #expect(groups.map(\.name) == ["Sony", "Nintendo", "Sega"])
        // Ascending sort within a group (sort 10 before 20).
        #expect(groups[0].platforms.map(\.id) == ["ps5", "ps4"])
    }

    @Test func emptyPlatformsHidden() {
        let platforms = [
            platform("ps5", "PS5", group: "Sony", sort: 10),
            platform("ps2", "PS2", group: "Sony", sort: 40),   // zero games
        ]
        let counts = SidebarCounts(perPlatform: ["ps5": 3])   // ps2 absent ⇒ 0
        let groups = SidebarPlatformGrouping.groups(platforms: platforms, counts: counts)

        #expect(groups.count == 1)
        #expect(groups[0].platforms.map(\.id) == ["ps5"])
        #expect(groups.flatMap(\.platforms).contains { $0.id == "ps2" } == false)
    }

    @Test func groupLeftEmptyIsDropped() {
        let platforms = [
            platform("ps5", "PS5", group: "Sony", sort: 10),
            platform("switch", "Switch", group: "Nintendo", sort: 10),
        ]
        let counts = SidebarCounts(perPlatform: ["ps5": 3])   // no Nintendo games
        let groups = SidebarPlatformGrouping.groups(platforms: platforms, counts: counts)
        #expect(groups.map(\.name) == ["Sony"])
    }

    @Test func unknownGroupSortsAfterCanonicalAlphabetically() {
        let platforms = [
            platform("x", "X", group: "Zeta", sort: 10),
            platform("ps5", "PS5", group: "Sony", sort: 10),
            platform("y", "Y", group: "Amiga-ish", sort: 10),
        ]
        let counts = SidebarCounts(perPlatform: ["x": 1, "ps5": 1, "y": 1])
        let groups = SidebarPlatformGrouping.groups(platforms: platforms, counts: counts)
        // Sony (canonical) first, then unknowns alphabetically.
        #expect(groups.map(\.name) == ["Sony", "Amiga-ish", "Zeta"])
    }

    @Test func realCatalogDecodesAndGroups() {
        // The bundled platforms.json decodes into PlatformInfo values and every
        // one carries a group — a smoke test that the resource is present.
        let all = PlatformLabels.all
        #expect(all.isEmpty == false)
        #expect(all.allSatisfy { !$0.group.isEmpty })
        #expect(PlatformLabels.short("ps5") == "PS5")
    }
}

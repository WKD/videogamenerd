import Testing
@testable import VGN

@MainActor
struct GameCellSubtitleTests {
    @Test func onePillPerPlatformUsingShortNames() {
        #expect(GameCell.platformPills(for: ["ps4"]) == ["PS4"])
        #expect(GameCell.platformPills(for: ["ps4", "ps5"]) == ["PS4", "PS5"])
    }

    @Test func duplicatesCollapse() {
        #expect(GameCell.platformPills(for: ["ps4", "ps5", "ps4"]) == ["PS4", "PS5"])
    }

    @Test func moreThanTwoPlatformsAreSummarised() {
        let pills = GameCell.platformPills(for: ["ps3", "ps4", "ps5", "switch", "pc"])
        #expect(pills.count == 3)
        #expect(pills.last == "+3")
    }

    @Test func noPlatformsNoPills() {
        #expect(GameCell.platformPills(for: []).isEmpty)
    }

    @Test func unknownSlugFallsBackToTheSlug() {
        #expect(GameCell.platformPills(for: ["mystery"]) == ["mystery"])
    }
}

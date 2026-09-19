import Foundation
import Testing
@testable import VGN

/// Pure mapping: platform table (every real label + hybrids + unknowns) and title
/// cleaning / edition extraction, built from the owner's real noisy patterns.
struct DeliciousMappingTests {

    // MARK: - Platform table

    @Test(arguments: [
        (["PlayStation 3"], "ps3"), (["PLAYSTATION 3"], "ps3"),
        (["PlayStation 2"], "ps2"), (["PlayStation"], "ps1"),
        (["Nintendo Wii"], "wii"), (["GameCube"], "gamecube"),
        (["Nintendo 64"], "n64"), (["Nintendo DS"], "ds"),
        (["Sega Dreamcast"], "dreamcast"), (["Game Boy Advance"], "gba"),
        (["Windows XP"], "pc"), (["Windows 98", "Windows XP", "Windows Vista"], "pc"),
        (["Macintosh"], "mac"), (["Mac OS X"], "mac"),
    ])
    func mapsKnownPlatforms(labels: [String], expected: String) {
        let r = DeliciousMapping.resolvePlatform(labels, policy: .macWhenAvailable)
        #expect(r.slug == expected)
        #expect(r.needsPick == false)
    }

    @Test func hybridDiscFollowsPolicy() {
        let labels = ["Windows XP", "Mac OS X"]
        let macFirst = DeliciousMapping.resolvePlatform(labels, policy: .macWhenAvailable)
        #expect(macFirst.slug == "mac")
        #expect(macFirst.macAvailable == true)
        let pcAlways = DeliciousMapping.resolvePlatform(labels, policy: .alwaysPC)
        #expect(pcAlways.slug == "pc")
        #expect(pcAlways.macAvailable == true)   // still re-mappable back to mac
    }

    @Test func macOnlyRespectsAlwaysPC() {
        #expect(DeliciousMapping.resolvePlatform(["Macintosh"], policy: .alwaysPC).slug == "pc")
        #expect(DeliciousMapping.resolvePlatform(["Macintosh"], policy: .macWhenAvailable).slug == "mac")
    }

    @Test func consoleLabelIsNeverRemappedByPolicy() {
        // A physical console game keeps its slug under either policy.
        for policy in ImportPlatformPolicy.allCases {
            let r = DeliciousMapping.resolvePlatform(["PlayStation 3"], policy: policy)
            #expect(r.slug == "ps3")
            #expect(r.macAvailable == false)
        }
    }

    @Test func unknownAndEmptyNeedAPick() {
        let unknown = DeliciousMapping.resolvePlatform(["PlayStation 9"], policy: .macWhenAvailable)
        #expect(unknown.slug == nil)
        #expect(unknown.needsPick == true)
        let empty = DeliciousMapping.resolvePlatform([], policy: .macWhenAvailable)
        #expect(empty.slug == nil)
        #expect(empty.needsPick == true)
    }

    // MARK: - Title cleaning + edition

    @Test(arguments: [
        ("Heavy Rain PS3 - édition spéciale", "Heavy Rain", "Special Edition"),
        ("Donkey Kong 64 + Memory Expansion Pack", "Donkey Kong 64", String?.none),
        ("Baldur's Gate 2 : Shadows of Amn DVD Rom", "Baldur's Gate 2 : Shadows of Amn", String?.none),
        ("Cérébrale Académie", "Cérébrale Académie", String?.none),
        ("Gran Turismo 4 Platinum", "Gran Turismo 4", "Platinum"),
        ("Metal Gear Solid Essentials", "Metal Gear Solid", "Essentials"),
        ("God of War Collector's Edition PS2", "God of War", "Collector's Edition"),
        ("Some Game DVD-ROM", "Some Game", String?.none),
        ("The Legend of Zelda: Ocarina of Time", "The Legend of Zelda: Ocarina of Time", String?.none),
        ("Resident Evil 4 Wii", "Resident Evil 4", String?.none),
    ])
    func cleansTitleAndExtractsEdition(raw: String, expectedTitle: String, expectedEdition: String?) {
        let out = DeliciousMapping.clean(raw)
        #expect(out.title == expectedTitle)
        #expect(out.edition == expectedEdition)
    }

    @Test func neverReducesToEmpty() {
        // A title that is nothing but noise still yields something (falls back to raw).
        let out = DeliciousMapping.clean("PS3")
        #expect(!out.title.isEmpty)
    }

    @Test func doesNotStripPlatformWordInsideAWord() {
        // "Kids" contains "ds" but must not be stripped (word boundary).
        let out = DeliciousMapping.clean("Kids Learning Adventure")
        #expect(out.title == "Kids Learning Adventure")
    }

    // MARK: - Staging row

    @Test func buildsStagingRow() {
        let game = DeliciousGame(
            uuid: "u1", title: "Heavy Rain PS3 - édition spéciale",
            platforms: ["PlayStation 3"], publishYear: 2010,
            catalogedAt: Date(timeIntervalSince1970: 1_300_000_000))
        let row = DeliciousMapping.stagingRow(for: game, policy: .macWhenAvailable)
        #expect(row.source == ImportSourceID.delicious)
        #expect(row.externalID == "u1")
        #expect(row.name == "Heavy Rain PS3 - édition spéciale")   // original kept
        #expect(row.matchTitle == "Heavy Rain")                    // cleaned form matched
        #expect(row.platform == "ps3")
        #expect(row.signals == [.owned])
        #expect(row.releaseYear == 2010)
        #expect(row.edition == "Special Edition")
        #expect(row.acquiredAt == Date(timeIntervalSince1970: 1_300_000_000))
    }

    @Test func matchTitleNilWhenUnchanged() {
        let game = DeliciousGame(uuid: "u2", title: "Cérébrale Académie", platforms: ["Nintendo DS"])
        let row = DeliciousMapping.stagingRow(for: game, policy: .macWhenAvailable)
        #expect(row.matchTitle == nil)   // nothing to clean → match on name
        #expect(row.platform == "ds")
    }
}

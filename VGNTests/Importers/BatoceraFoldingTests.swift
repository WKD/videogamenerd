import Foundation
import Testing
@testable import VGN

/// Pure duplicate folding (PLAN §15): multi-disc, revisions, regional twins collapse to one
/// title; the representative keeps play data, else the preferred region (EU > US > JP).
struct BatoceraFoldingTests {

    private func game(_ path: String, region: String? = nil, gametime: Int = 0,
                      favorite: Bool = false, name: String = "") -> BatoceraGame {
        BatoceraGame(system: "psx", relativePath: "./" + path,
                     name: name.isEmpty ? path : name, region: region,
                     gameTimeSeconds: gametime, isFavorite: favorite)
    }

    @Test func foldsMultiDiscIntoOneTitle() {
        let result = BatoceraFolding.fold([
            game("Final Fantasy VII (USA) (Disc 1).chd"),
            game("Final Fantasy VII (USA) (Disc 2).chd"),
            game("Final Fantasy VII (USA) (Disc 3).chd"),
        ])
        #expect(result.groups.count == 1)
        #expect(result.foldedCount == 2)
        // Disc 1 is the representative.
        #expect(result.groups.first?.representative.relativePath.contains("Disc 1") == true)
    }

    @Test func foldsRegionalTwinsPreferringEUthenUS() {
        let result = BatoceraFolding.fold([
            game("Chrono Trigger (Japan).zip", region: "jp"),
            game("Chrono Trigger (USA).zip", region: "us"),
            game("Chrono Trigger (Europe).zip", region: "eu"),
        ])
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.representative.region == "eu")
        #expect(result.groups.first?.memberCount == 3)
    }

    @Test func playDataWinsOverRegionPreference() {
        let result = BatoceraFolding.fold([
            game("Secret of Mana (Europe).zip", region: "eu", gametime: 0),
            game("Secret of Mana (USA).zip", region: "us", gametime: 5000),
        ])
        #expect(result.groups.count == 1)
        // The US copy has the play time, so it is kept even though EU is the preferred region.
        #expect(result.groups.first?.representative.region == "us")
        #expect(result.groups.first?.representative.gameTimeSeconds == 5000)
    }

    @Test func distinctTitlesDoNotFold() {
        let result = BatoceraFolding.fold([
            game("Super Mario World (USA).zip"),
            game("Super Metroid (USA).zip"),
        ])
        #expect(result.groups.count == 2)
        #expect(result.foldedCount == 0)
    }

    @Test func revisionsFoldPreferringPlayData() {
        let result = BatoceraFolding.fold([
            game("Zelda (USA).zip", region: "us", gametime: 100),
            game("Zelda (USA) (Rev 1).zip", region: "us", gametime: 0),
        ])
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.representative.gameTimeSeconds == 100)
    }
}

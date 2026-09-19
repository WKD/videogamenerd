import Foundation
import Testing
@testable import VGN

/// The streaming gamelist reader (PLAN §15): parses fields, tolerates missing/unknown tags,
/// decodes entities, skips `<folder>` nodes, drops hidden entries, parses play data and the
/// two date shapes.
struct BatoceraReaderTests {

    private let reader = BatoceraGamelistReader()

    @Test func parsesCoreFieldsWithEntitiesAndAttributes() throws {
        let data = BatoceraTestSupport.data([
            .init(path: "./Advanced Dungeons & Dragons - Eye of the Beholder (USA).zip",
                  name: "Eye of the Beholder", id: "2468",
                  genre: "Role Playing Game / Dungeon Crawler RPG", family: "Dungeons & Dragons",
                  developer: "Capcom", publisher: "Capcom", region: "us", lang: "en",
                  rating: "0.6", releasedate: "19940402T000000", players: "1",
                  md5: "37c38e3fc469d69e8432e69982537de3",
                  image: "./images/x-image.png", thumbnail: "./images/x-thumb.png",
                  extra: ["bezel": "./images/x-bezel.png", "cheevosId": "12345"]),
        ])
        let games = try reader.read(system: "snes", data: data)
        #expect(games.count == 1)
        let g = try #require(games.first)
        #expect(g.system == "snes")
        #expect(g.name == "Eye of the Beholder")
        #expect(g.relativePath == "./Advanced Dungeons & Dragons - Eye of the Beholder (USA).zip")
        #expect(g.screenScraperID == "2468")
        #expect(g.developer == "Capcom")
        #expect(g.family == "Dungeons & Dragons")
        #expect(g.genre == "Role Playing Game / Dungeon Crawler RPG")
        #expect(g.region == "us")
        #expect(g.releaseYear == 1994)
        #expect(g.rating == 0.6)
        #expect(g.md5 == "37c38e3fc469d69e8432e69982537de3")
        #expect(g.thumbnailRelativePath == "./images/x-thumb.png")
    }

    @Test func toleratesMissingTagsWithSaneDefaults() throws {
        let data = BatoceraTestSupport.data([.init(path: "./Bare.zip")])
        let g = try #require(try reader.read(system: "nes", data: data).first)
        #expect(g.playCount == 0)
        #expect(g.gameTimeSeconds == 0)
        #expect(g.lastPlayed == nil)
        #expect(g.isFavorite == false)
        #expect(g.releaseYear == nil)
        // No <name> → readable fallback from the file base name (tags stripped).
        #expect(g.name == "Bare")
    }

    @Test func skipsFolderNodesEntirely() throws {
        let folder = """
          <folder>
            <path>./Subdir</path>
            <name>A Folder</name>
            <image>./x.png</image>
          </folder>
        """
        let data = BatoceraTestSupport.data([.init(path: "./Game.zip", name: "Real Game")],
                                            rawFolders: [folder])
        let games = try reader.read(system: "gba", data: data)
        #expect(games.count == 1)
        #expect(games.first?.name == "Real Game")
    }

    @Test func dropsHiddenEntriesByDefaultButKeepsFlagWhenAsked() throws {
        let specs = [
            BatoceraTestSupport.GameSpec(path: "./Shown.zip", name: "Shown"),
            BatoceraTestSupport.GameSpec(path: "./Hidden.zip", name: "Hidden", hidden: "true"),
        ]
        let dropped = try reader.read(system: "gb", data: BatoceraTestSupport.data(specs))
        #expect(dropped.map(\.name) == ["Shown"])

        let keeping = BatoceraGamelistReader(dropHidden: false)
        let all = try keeping.read(system: "gb", data: BatoceraTestSupport.data(specs))
        #expect(all.count == 2)
        #expect(all.first(where: { $0.name == "Hidden" })?.isHidden == true)
    }

    @Test func parsesPlayDataAndFavourite() throws {
        let data = BatoceraTestSupport.data([
            .init(path: "./Zelda.zip", name: "Zelda", playcount: "3", gametime: "3600",
                  lastplayed: "20250426T220042", favorite: "true"),
        ])
        let g = try #require(try reader.read(system: "cdi", data: data).first)
        #expect(g.playCount == 3)
        #expect(g.gameTimeSeconds == 3600)
        #expect(g.isFavorite == true)
        let comps = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: try #require(g.lastPlayed))
        #expect(comps.year == 2025 && comps.month == 4 && comps.day == 26)
        #expect(comps.hour == 22 && comps.minute == 0 && comps.second == 42)
    }

    @Test func playDataEdgeCasesAroundThreshold() throws {
        let specs = [0, 299, 300, 301].map {
            BatoceraTestSupport.GameSpec(path: "./g\($0).zip", name: "g\($0)", gametime: String($0))
        }
        let games = try reader.read(system: "nes", data: BatoceraTestSupport.data(specs))
        let byName = Dictionary(uniqueKeysWithValues: games.map { ($0.name, $0.gameTimeSeconds) })
        #expect(byName["g0"] == 0)
        #expect(byName["g299"] == 299)
        #expect(byName["g300"] == 300)
        #expect(byName["g301"] == 301)
        // 300 is NOT played (> 300 required); 301 is.
        #expect(BatoceraPromotion.isPlayed(gameTimeSeconds: 300) == false)
        #expect(BatoceraPromotion.isPlayed(gameTimeSeconds: 301) == true)
    }

    @Test func malformedXMLThrowsTypedError() throws {
        let broken = Data("<gameList><game><path>./x.zip</path></gameList>".utf8)   // unclosed <game>
        #expect(throws: BatoceraError.self) {
            try reader.read(system: "snes", data: broken)
        }
    }

    @Test func dateHelpersHandleSentinels() {
        #expect(BatoceraDate.year(from: "19940402T000000") == 1994)
        #expect(BatoceraDate.year(from: "00000000T000000") == nil)
        #expect(BatoceraDate.date(from: "00000000T000000") == nil)
        #expect(BatoceraDate.date(from: nil) == nil)
        #expect(BatoceraDate.date(from: "20250426T220042") != nil)
    }
}

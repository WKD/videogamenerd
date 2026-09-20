import Foundation
import Testing
@testable import VGN

/// The pure VGN-slug ↔ HowLongToBeat-name table (PLAN §5.3, D2) plus the lint against
/// the recorded fixtures: every HLTB platform name a VGN slug covers must be spelled in
/// the map exactly as HLTB prints it.
@Suite struct HLTBPlatformMapTests {

    // MARK: - Round-trip

    @Test func canonicalNamesRoundTripToTheirSlug() {
        for (slug, names) in HLTBPlatformMap.namesBySlug {
            for name in names {
                #expect(HLTBPlatformMap.slug(forHLTBName: name) == slug,
                        "\(name) should map back to \(slug)")
            }
        }
    }

    @Test func slashAndPipeFoldTheSame() {
        #expect(HLTBPlatformMap.slug(forHLTBName: "Xbox Series X/S") == "xboxseries")
        #expect(HLTBPlatformMap.slug(forHLTBName: "Xbox Series X|S") == "xboxseries")
    }

    @Test func unknownPlatformDoesNotParticipate() {
        #expect(HLTBPlatformMap.slug(forHLTBName: "Google Stadia") == nil)
        #expect(HLTBPlatformMap.slug(forHLTBName: "PICO-8") == nil)
    }

    // MARK: - Overlap

    @Test func overlapDetectsMyPlatform() {
        let cand = ["Nintendo Switch", "PC", "PlayStation 4"]
        #expect(HLTBPlatformMap.intersects(candidatePlatforms: cand, librarySlugs: ["ps4"]))
        #expect(!HLTBPlatformMap.intersects(candidatePlatforms: cand, librarySlugs: ["ps5"]))
        #expect(HLTBPlatformMap.overlapping(candidatePlatforms: cand, librarySlugs: ["ps4", "pc"])
                == ["PC", "PlayStation 4"])
    }

    @Test func emptyLibrarySlugsNeverIntersect() {
        #expect(!HLTBPlatformMap.intersects(candidatePlatforms: ["PC"], librarySlugs: []))
    }

    // MARK: - Fixture lint (spelling)

    @Test func everyFixturePlatformNameACoveredSlugKeepsIsSpeltAsInTheFixtures() throws {
        let fixtures = [
            "hltb-search-bloodborne.json", "hltb-search-celeste.json",
            "hltb-search-final-fantasy-vii.json",
            "hltb-search-the-legend-of-zelda-the-wind-waker.json",
        ]
        var namesSeen = Set<String>()
        for fixture in fixtures {
            let data = try Fixtures.data(fixture)
            let candidates = try HLTBEndpoint.parseCandidates(data)
            for candidate in candidates {
                for name in candidate.platforms { namesSeen.insert(name) }
            }
        }
        #expect(!namesSeen.isEmpty)
        for name in namesSeen {
            guard let slug = HLTBPlatformMap.slug(forHLTBName: name) else { continue } // not a VGN platform
            #expect(HLTBPlatformMap.names(forSlug: slug).contains(name),
                    "fixture spells \(slug) as “\(name)”, which the map must include verbatim")
        }
    }

    /// Sanity: the fixtures really do exercise several known VGN platforms.
    @Test func fixturesCoverKnownPlatforms() throws {
        let data = try Fixtures.data("hltb-search-celeste.json")
        let names = try HLTBEndpoint.parseCandidates(data).flatMap(\.platforms)
        #expect(names.contains("PlayStation 4"))
        #expect(HLTBPlatformMap.slug(forHLTBName: "PlayStation 4") == "ps4")
        #expect(HLTBPlatformMap.slug(forHLTBName: "Nintendo Switch") == "switch")
    }
}

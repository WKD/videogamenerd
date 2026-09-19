import Foundation
import Testing
@testable import VGN

/// The ScreenScraper-genre → IGDB-trait mapping and the promotion rule (PLAN §15, §7b).
struct BatoceraTraitsTests {

    @Test func mapsTopLevelGenresToIGDBNames() {
        #expect(RomCatalogTraits.primaryGenreTrait(for: "Platform")
                == GameTrait(kind: .genre, value: "Platform"))
        #expect(RomCatalogTraits.primaryGenreTrait(for: "Role Playing Game / Action RPG")
                == GameTrait(kind: .genre, value: "Role-playing (RPG)"))
        #expect(RomCatalogTraits.primaryGenreTrait(for: "Shoot'em Up / Horizontal")
                == GameTrait(kind: .genre, value: "Shooter"))
        #expect(RomCatalogTraits.primaryGenreTrait(for: "Racing, Driving / Racing")
                == GameTrait(kind: .genre, value: "Racing"))
        #expect(RomCatalogTraits.primaryGenreTrait(for: "Action / Labyrinth")
                == GameTrait(kind: .theme, value: "Action"))
    }

    @Test func unknownGenrePassesThroughAsKeywordsOnly() {
        #expect(RomCatalogTraits.mapsToKnownTrait(genre: "Various") == false)
        let traits = RomCatalogTraits.traits(genre: "Various / Weird", family: nil,
                                             developer: nil, releaseYear: nil)
        #expect(traits.allSatisfy { $0.kind == .keyword })
        #expect(traits.contains(GameTrait(kind: .keyword, value: "various")))
    }

    @Test func buildsFamilyDeveloperAndDecadeTraits() {
        let traits = RomCatalogTraits.traits(
            genre: "Platform / Run & Jump", family: "Super Mario",
            developer: "Nintendo", releaseYear: 1994)
        #expect(traits.contains(GameTrait(kind: .genre, value: "Platform")))
        #expect(traits.contains(GameTrait(kind: .franchise, value: "Super Mario")))
        #expect(traits.contains(GameTrait(kind: .developer, value: "Nintendo")))
        #expect(traits.contains(GameTrait(kind: .decade, value: "1990")))
        // Sub-segment becomes a keyword.
        #expect(traits.contains(GameTrait(kind: .keyword, value: "run & jump")))
    }

    @Test func promotionThresholdIsFiveMinutesExclusive() {
        #expect(BatoceraPromotion.isPlayed(gameTimeSeconds: 300) == false)
        #expect(BatoceraPromotion.isPlayed(gameTimeSeconds: 301) == true)
        // playcount alone never promotes.
        #expect(BatoceraPromotion.isCandidate(gameTimeSeconds: 100, isFavorite: false) == false)
        #expect(BatoceraPromotion.isCandidate(gameTimeSeconds: 100, isFavorite: true) == true)
        #expect(BatoceraPromotion.isCandidate(gameTimeSeconds: 600, isFavorite: false) == true)
    }
}

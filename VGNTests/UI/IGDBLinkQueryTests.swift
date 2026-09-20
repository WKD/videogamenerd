import Testing
@testable import VGN

/// The link-sheet query cleaner (PLAN §5.1): the owner's eight real unlinked titles
/// should prefill to a sensible IGDB query.
struct IGDBLinkQueryTests {

    @Test(arguments: [
        ("Obduction ®", "Obduction"),
        ("Evolution Worlds - GameCube - US", "Evolution Worlds"),
        ("Myst V: End of Ages Limited Edition", "Myst V: End of Ages"),
        ("Uru: Complete Chronicles", "Uru: Complete Chronicles"),   // real subtitle — kept
        ("The Bard's Tale IV: Barrows Deep", "The Bard's Tale IV: Barrows Deep"),
        ("The Nomad Soul", "The Nomad Soul"),
        ("Cérébrale Académie", "Cérébrale Académie"),               // French — owner retypes the English title
        ("Dragon Quest IV : L'épopée des Elus", "Dragon Quest IV : L'épopée des Elus"),
    ])
    func cleansRealTitles(_ input: String, _ expected: String) {
        #expect(IGDBLinkQuery.clean(input) == expected)
    }

    @Test func stripsTrademarkAndParentheses() {
        #expect(IGDBLinkQuery.clean("Portal™ (Steam)") == "Portal")
        #expect(IGDBLinkQuery.clean("Halo [Disc 1]") == "Halo")
    }

    @Test func stripsEditionTails() {
        #expect(IGDBLinkQuery.clean("Skyrim Special Edition") == "Skyrim")
        #expect(IGDBLinkQuery.clean("Tomb Raider Game of the Year Edition") == "Tomb Raider")
        #expect(IGDBLinkQuery.clean("The Witcher 3 GOTY Edition") == "The Witcher 3")
    }

    @Test func stripsRegionAndPlatformTails() {
        #expect(IGDBLinkQuery.clean("Chrono Trigger - SNES - Japan") == "Chrono Trigger")
        #expect(IGDBLinkQuery.clean("Ico - PS2 - PAL") == "Ico")
    }

    @Test func neverEmptiesTheTitle() {
        #expect(IGDBLinkQuery.clean("Remastered") == "Remastered")   // whole title is an edition word
    }

    /// W19 part 2C: a PSN twin's bare PlayStation platform tail is dropped from the PREFILL so
    /// it finds the same IGDB game as its sibling (the shown "Current: …" line keeps the real
    /// title). Counter-case: a title that merely ends in a number is untouched.
    @Test(arguments: [
        ("The Dark Pictures Anthology: Man of Medan PS4 & PS5", "The Dark Pictures Anthology: Man of Medan"),
        ("Aliens: Fireteam Elite PS4 & PS5", "Aliens: Fireteam Elite"),
        ("Ghost of Tsushima (PS4)", "Ghost of Tsushima"),
        ("Persona 5", "Persona 5"),   // no platform tail — untouched
    ])
    func stripsPlayStationPlatformTails(_ input: String, _ expected: String) {
        #expect(IGDBLinkQuery.clean(input) == expected)
    }
}

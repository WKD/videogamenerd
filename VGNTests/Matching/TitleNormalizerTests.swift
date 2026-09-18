import Testing
@testable import VGN

struct TitleNormalizerTests {

    private func canon(_ s: String) -> String { TitleNormalizer.normalize(s, level: .canonical) }
    private func artless(_ s: String) -> String { TitleNormalizer.normalize(s, level: .articleless) }
    private func core(_ s: String) -> String { TitleNormalizer.normalize(s, level: .core) }

    @Test("Diacritics and trademark symbols fold away")
    func diacritics() {
        #expect(canon("Pokémon") == "pokemon")
        #expect(canon("Ōkami") == "okami")
        #expect(canon("Pokémon™") == "pokemon")
        #expect(canon("Mario®") == "mario")
    }

    @Test("Ampersand becomes 'and'")
    func ampersand() {
        #expect(canon("Ratchet & Clank") == "ratchet and clank")
        #expect(canon("ICO & Shadow of the Colossus Collection") == "ico and shadow of the colossus collection")
    }

    @Test("Multi-char roman numerals convert; single-char X/I/V stay")
    func numerals() {
        #expect(canon("Final Fantasy VII") == "final fantasy 7")
        #expect(canon("Final Fantasy VII") == canon("Final Fantasy 7"))
        #expect(canon("Baldur's Gate III") == "baldur s gate 3")
        #expect(canon("Civilization VI") == "civilization 6")
        // Single-char X must NOT become 10.
        #expect(canon("Final Fantasy X") == "final fantasy x")
        #expect(canon("Mega Man X") == "mega man x")
        #expect(canon("Final Fantasy X-2") == "final fantasy x 2")
        // Non-canonical roman spellings are left alone.
        #expect(TitleNormalizer.romanToArabic("iiii") == "iiii")
        #expect(TitleNormalizer.romanToArabic("vv") == "vv")
        #expect(TitleNormalizer.romanToArabic("xvi") == "16")
    }

    @Test("Leading articles (English + French) stripped at articleless level only")
    func leadingArticles() {
        #expect(canon("The Last of Us") == "the last of us")     // kept at canonical
        #expect(artless("The Last of Us") == "last of us")       // stripped
        #expect(artless("Les Chevaliers de Baphomet") == "chevaliers de baphomet")
        #expect(artless("A Plague Tale") == "plague tale")
        #expect(artless("Un Prince") == "prince")
    }

    @Test("Trailing-article comma form is reflowed and stripped")
    func commaArticle() {
        #expect(artless("Legend of Zelda, The") == "legend of zelda")
        #expect(artless("Legend of Zelda, The - Ocarina of Time") == "legend of zelda ocarina of time")
    }

    @Test("Parenthesised region/tag groups never leak into the title")
    func parenTags() {
        #expect(canon("Legend of Zelda, The (Europe) (En,Fr,De)") == "legend of zelda the")
        #expect(canon("Gran Turismo 4 (Platinum)") == "gran turismo 4")
        #expect(canon("Metroid Prime (USA) (Rev 1)") == "metroid prime")
    }

    @Test("Edition and budget tags stripped at articleless level")
    func editionTags() {
        #expect(artless("Uncharted 2: Among Thieves - Game of the Year Edition") == "uncharted 2 among thieves")
        #expect(artless("The Witcher 3: Wild Hunt - Complete Edition") == "witcher 3 wild hunt")
        #expect(artless("Skyrim Special Edition") == "skyrim")
        #expect(artless("Halo 2 Deluxe") == "halo 2")
        // Budget label stripped, but never reduces a title to nothing.
        #expect(artless("Platinum") == "platinum")
    }

    @Test("Remasters / HD / Remake / Part are NEVER stripped (separate games)")
    func remastersPreserved() {
        #expect(artless("The Last of Us Remastered") == "last of us remastered")
        // Bare "Anniversary" (no "Edition") is preserved; only "Anniversary Edition" strips.
        #expect(artless("Halo Combat Evolved Anniversary") == "halo combat evolved anniversary")
        #expect(artless("Shadow of the Colossus HD") == "shadow of the colossus hd")
        #expect(artless("Resident Evil 2 Remake") == "resident evil 2 remake")
        #expect(artless("Final Fantasy VII Remake") == "final fantasy 7 remake")
    }

    @Test("Subtitle dropped only at core level")
    func subtitle() {
        #expect(artless("NieR:Automata") == "nier automata")
        #expect(core("NieR:Automata") == "nier")
        #expect(core("Metal Gear Solid: The Legacy Collection") == "metal gear solid")
        #expect(core("Uncharted 2: Among Thieves") == "uncharted 2")
    }

    @Test("Apostrophes fold to a separator and still score as a confident match")
    func apostrophes() {
        #expect(canon("Tom Clancy's Splinter Cell") == "tom clancy s splinter cell")
        // The apostrophe/no-apostrophe forms differ by one space but match confidently.
        let s = FuzzyMatch.score("Tom Clancy's Splinter Cell", "Tom Clancys Splinter Cell")
        #expect(FuzzyMatch.classify(s) == .confident)
    }
}

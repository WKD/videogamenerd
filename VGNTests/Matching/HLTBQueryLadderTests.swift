import Foundation
import Testing
@testable import VGN

/// The pure HLTB query ladder (PLAN §5.3, D3): the ordered ≤ 3 queries a long / edition
/// title expands into, and — decisively — the counter-cases that must NOT be stripped
/// (numerals, a bare qualifier that is not an edition tag, a distinct sequel).
@Suite struct HLTBQueryLadderTests {

    // MARK: - Cap + ordering

    @Test func firstQueryIsAlwaysTheRawTitle() {
        #expect(HLTBQueryLadder.queries(for: "Bloodborne").first == "Bloodborne")
    }

    @Test func atMostThreeQueries() {
        let q = HLTBQueryLadder.queries(for: "Batman: Arkham Knight - Game of the Year Edition")
        #expect(q.count <= HLTBQueryLadder.maxQueries)
    }

    @Test func aPlainTitleCollapsesToOneQuery() {
        // Nothing to strip → the looser rungs duplicate rung 1 and are dropped.
        #expect(HLTBQueryLadder.queries(for: "Celeste") == ["Celeste"])
    }

    // MARK: - Edition families

    @Test func completeEditionStripped() {
        let q = HLTBQueryLadder.queries(for: "The Witcher 3: Wild Hunt - Complete Edition")
        #expect(q.contains("The Witcher 3: Wild Hunt"))
    }

    @Test func gotyStripped() {
        #expect(HLTBQueryLadder.cleaned("Borderlands GOTY", dropSubtitle: false) == "Borderlands")
        #expect(HLTBQueryLadder.cleaned("Skyrim Game of the Year Edition", dropSubtitle: false) == "Skyrim")
    }

    @Test func definitiveDeluxeUltimateSpecialStripped() {
        #expect(HLTBQueryLadder.cleaned("Control Ultimate Edition", dropSubtitle: false) == "Control")
        #expect(HLTBQueryLadder.cleaned("Tomb Raider Definitive Edition", dropSubtitle: false) == "Tomb Raider")
        #expect(HLTBQueryLadder.cleaned("Grand Theft Auto V Special Edition", dropSubtitle: false) == "Grand Theft Auto V")
        #expect(HLTBQueryLadder.cleaned("Hades Deluxe Edition", dropSubtitle: false) == "Hades")
    }

    @Test func directorsCutStripped() {
        #expect(HLTBQueryLadder.cleaned("Death Stranding Director's Cut", dropSubtitle: false) == "Death Stranding")
    }

    @Test func remasteredAndHDStrippedConservatively() {
        #expect(HLTBQueryLadder.cleaned("Okami HD", dropSubtitle: false) == "Okami")
        #expect(HLTBQueryLadder.cleaned("Shadow of the Colossus Remastered", dropSubtitle: false) == "Shadow of the Colossus")
    }

    @Test func gotyParodyEditionStrippedButSubtitleKept() {
        // "NieR: Automata – Game of the YoRHa Edition" → keep "NieR: Automata".
        let q = HLTBQueryLadder.queries(for: "NieR: Automata – Game of the YoRHa Edition")
        #expect(q.contains("NieR: Automata"))
    }

    @Test func platformTailStripped() {
        #expect(HLTBQueryLadder.cleaned("Persona 5 Royal PS4", dropSubtitle: false) == "Persona 5 Royal")
    }

    @Test func trademarkSymbolsStripped() {
        #expect(HLTBQueryLadder.cleaned("Bloodborne™", dropSubtitle: false) == "Bloodborne")
    }

    // MARK: - Subtitle drop (last rung only)

    @Test func subtitleKeptOnFirstRetryDroppedOnLast() {
        let q = HLTBQueryLadder.queries(for: "Halo: Combat Evolved Anniversary Edition")
        // rung 2 keeps the subtitle, minus the "Anniversary Edition" tag.
        #expect(q.contains("Halo: Combat Evolved"))
        // rung 3 drops the subtitle entirely.
        #expect(q.last == "Halo")
    }

    // MARK: - Counter-cases (must NOT be stripped)

    @Test func royalWithoutEditionIsKept() {
        #expect(HLTBQueryLadder.queries(for: "Persona 5 Royal") == ["Persona 5 Royal"])
    }

    @Test func numeralsAreNeverStripped() {
        #expect(HLTBQueryLadder.queries(for: "Doom 3") == ["Doom 3"])
        #expect(HLTBQueryLadder.cleaned("Doom 3", dropSubtitle: true) == "Doom 3")
    }

    @Test func residentEvil2DoesNotCollapseToResidentEvil() {
        let q = HLTBQueryLadder.queries(for: "Resident Evil 2")
        #expect(q == ["Resident Evil 2"])
        #expect(!q.contains("Resident Evil"))
    }

    @Test func editionStripNeverEmptiesTheTitle() {
        // A title that is *only* an edition word must not vanish.
        #expect(!HLTBQueryLadder.cleaned("Complete Edition", dropSubtitle: false).isEmpty)
    }

    // MARK: - Prefill

    @Test func prefillIsTheCleanedSubtitleKeptForm() {
        #expect(HLTBQueryLadder.prefill(for: "The Witcher 3: Wild Hunt - Complete Edition")
                == "The Witcher 3: Wild Hunt")
    }
}

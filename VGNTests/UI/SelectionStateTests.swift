import Testing
@testable import VGN

/// The pure ``SelectionState`` and the mixed-state menu helpers over a selection
/// (PLAN §8, wave 17): every / some / no game matches an option → ✓ / – / nothing.
struct SelectionStateTests {

    @Test func overComputesAllSomeNone() {
        #expect(SelectionState.over([1, 2, 3]) { $0 > 0 } == .all)
        #expect(SelectionState.over([1, 2, 3]) { $0 > 2 } == .some)
        #expect(SelectionState.over([1, 2, 3]) { $0 > 9 } == .none)
        // An empty set is `.none` (nothing is ticked).
        #expect(SelectionState.over([Int]()) { _ in true } == .none)
    }

    @Test func menuGlyphMatchesState() {
        #expect(SelectionState.all.menuGlyph == "checkmark")
        #expect(SelectionState.some.menuGlyph == "minus")
        #expect(SelectionState.none.menuGlyph == nil)
    }

    // MARK: Per-option state over a game selection

    private func game(_ id: Int64, tier: String? = nil, played: Bool = false,
                      status: PlayStatus? = nil, owned: Bool = false,
                      single: ProductFormat? = nil, several: Bool = false) -> GameSummary {
        GameSummary(id: id, title: "G\(id)", tierID: tier == nil ? nil : 1,
                    tierLetter: tier, played: played, owned: owned,
                    status: status, singleCopyFormat: single, hasSeveralChangeableCopies: several)
    }

    @Test func tierStateAcrossSelection() {
        let sel = [game(1, tier: "S"), game(2, tier: "S"), game(3, tier: "A")]
        #expect(sel.tierState(letter: "S") == .some)   // two of three
        #expect([game(1, tier: "S"), game(2, tier: "S")].tierState(letter: "S") == .all)
        #expect(sel.tierState(letter: "F") == .none)
        // Clear/Unrated = no tier at all.
        #expect([game(1), game(2)].clearTierState == .all)
        #expect(sel.clearTierState == .none)
    }

    @Test func playedMarkStateDistinguishesStatus() {
        let sel = [game(1, played: true, status: .finished), game(2, played: true, status: .finished),
                   game(3, played: false)]
        #expect(sel.playedMarkState(.played) == .some)                 // 2 of 3 played
        #expect(sel.playedMarkState(.status(.finished)) == .some)      // 2 of 3 finished
        #expect(sel.playedMarkState(.status(.abandoned)) == .none)
        let allFinished = [game(1, played: true, status: .finished), game(2, played: true, status: .finished)]
        #expect(allFinished.playedMarkState(.status(.finished)) == .all)
        #expect(allFinished.playedMarkState(.played) == .all)
    }

    @Test func ownedState() {
        #expect([game(1, owned: true), game(2, owned: true)].ownedState == .all)
        #expect([game(1, owned: true), game(2)].ownedState == .some)
        #expect([game(1), game(2)].ownedState == .none)
    }

    @Test func copyFormatStateIgnoresMultiCopyGames() {
        // Two single-copy games (physical + digital) and one several-copies game.
        let sel = [game(1, single: .physical), game(2, single: .digital), game(3, several: true)]
        // The several-copies game is excluded from the state entirely.
        #expect(sel.copyFormatState(.physical) == .some)   // one of the two single-copy games
        #expect(sel.copyFormatState(.digital) == .some)
        #expect(sel.copyFormatState(.rom) == .none)
        #expect(sel.severalCopiesCount == 1)               // the footer count
        // All single-copy physical → ✓ on Physical only.
        let allPhysical = [game(1, single: .physical), game(2, single: .physical)]
        #expect(allPhysical.copyFormatState(.physical) == .all)
        #expect(allPhysical.copyFormatState(.digital) == .none)
        // Only multi-copy games → every format is .none (nothing the action can touch).
        let onlyMulti = [game(1, several: true), game(2, several: true)]
        #expect(onlyMulti.copyFormatState(.physical) == .none)
        #expect(onlyMulti.severalCopiesCount == 2)
    }
}

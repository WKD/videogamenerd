import SwiftUI

/// Per-option ``SelectionState`` for the multi-select menus (PLAN §8, owner request
/// wave 17: "tick the current format, use '–' on a mixed set"). Pure over a collection
/// of the already-loaded ``GameSummary`` values — a menu builder never queries the DB or
/// writes observable state (the 100 % CPU lesson, LIMITATIONS §3). Unit-tested directly.
extension Collection where Element == GameSummary {
    /// Whether every / some / no game in this set sits in tier `letter`.
    func tierState(letter: String) -> SelectionState {
        SelectionState.over(self) { $0.tierLetter?.caseInsensitiveCompare(letter) == .orderedSame }
    }

    /// The "Clear / Unrated" tier option: every / some / no game has no tier.
    var clearTierState: SelectionState {
        SelectionState.over(self) { $0.tierID == nil }
    }

    /// "Mark Played" / "Mark Played As ▸ status": `.played` matches any played game;
    /// `.status(s)` matches a played game whose completion status is exactly `s`.
    func playedMarkState(_ mark: PlayedMark) -> SelectionState {
        switch mark {
        case .played: return SelectionState.over(self) { $0.played }
        case let .status(status): return SelectionState.over(self) { $0.played && $0.status == status }
        }
    }

    /// "Mark Owned": every / some / no game is owned.
    var ownedState: SelectionState {
        SelectionState.over(self) { $0.owned }
    }

    /// "Change Copy Format ▸ Physical / Digital / ROM": computed **only over the games the
    /// action can act on** — those with exactly one reformat-able copy (``GameSummary/
    /// singleCopyFormat``). Games with several copies are ignored for the state (they are
    /// skipped by the write) and counted by ``severalCopiesCount`` for the footer.
    func copyFormatState(_ format: ProductFormat) -> SelectionState {
        SelectionState.over(filter { $0.singleCopyFormat != nil }) { $0.singleCopyFormat == format }
    }

    /// "Holds Up Today? ▸ value / Clear" (PLAN §7b): computed **only over the played games**
    /// (the ones the action can mark); unplayed games are ignored for the state and counted
    /// by ``unplayedCount`` for the disabled footer. `nil` = the "Clear" (Unrated) option.
    func holdsUpState(_ value: HoldsUp?) -> SelectionState {
        SelectionState.over(filter(\.played)) { $0.holdsUp == value }
    }

    /// How many games in this set are unplayed — the "N unplayed games not changed" footer
    /// of the Holds Up Today? menu.
    var unplayedCount: Int {
        reduce(0) { $0 + ($1.played ? 0 : 1) }
    }

    /// How many games in this set own several reformat-able copies — the "N games with
    /// several copies are not changed" footer (PLAN §13.3).
    var severalCopiesCount: Int {
        reduce(0) { $0 + ($1.hasSeveralChangeableCopies ? 1 : 0) }
    }
}

/// A menu item that shows a ``SelectionState`` as a leading ✓ (all) / – (mixed) / nothing
/// (none), matching macOS's mixed-state menu marks. Clicking runs `action`. Used by the
/// grid context menu and the menu-bar Game menu so both render state identically.
struct StateMenuButton: View {
    let title: String
    let state: SelectionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let glyph = state.menuGlyph {
                Label(title, systemImage: glyph)
            } else {
                Text(title)
            }
        }
    }
}

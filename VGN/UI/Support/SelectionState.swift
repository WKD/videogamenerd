import Foundation

/// How a per-item value is distributed across a multi-selection (wave 17, owner
/// request): every item has it (`all` → a ✓), some do (`some` → the mixed dash),
/// none do (`none` → nothing). One pure function so every mixed-state menu — grid
/// context menu, menu-bar Game menu, tier / format / played submenus — computes its
/// ticks the same way and is unit-tested without any UI.
///
/// A menu renders it as a `Button` whose `Label` carries `menuGlyph` — a `checkmark`
/// for `.all`, a `minus` for the mixed `.some`, and no glyph for `.none` — so the ✓/–
/// state is deterministic and testable (a `Toggle`'s mixed dash needs a key-path
/// `Toggle(sources:isOn:)`, which these derived predicates are not). Building a menu
/// never mutates observable state (the 100 % CPU lesson, LIMITATIONS §3), so these are
/// computed from already-loaded values.
enum SelectionState: Sendable, Hashable {
    /// Every considered item matches (`✓`).
    case all
    /// Some but not all match (the mixed `–`).
    case some
    /// No considered item matches (blank).
    case none

    /// The distribution of `predicate` over `items`. An **empty** set is `.none`
    /// (nothing is ticked). Only the items passed are considered — a caller that must
    /// ignore part of the selection (e.g. "Change Copy Format" ignores multi-copy
    /// games) filters them out before calling.
    static func over<S: Sequence>(_ items: S, where predicate: (S.Element) -> Bool) -> SelectionState {
        var sawMatch = false
        var sawMiss = false
        for item in items {
            if predicate(item) { sawMatch = true } else { sawMiss = true }
            if sawMatch && sawMiss { return .some }
        }
        if sawMatch { return .all }   // at least one, and no miss
        return .none                  // empty, or all misses
    }

    /// The SF Symbol a menu item draws to show this state: `checkmark` (all), `minus`
    /// (the mixed dash), or nil (nothing) — matching macOS's ✓ / – menu marks.
    var menuGlyph: String? {
        switch self {
        case .all: return "checkmark"
        case .some: return "minus"
        case .none: return nil
        }
    }
}

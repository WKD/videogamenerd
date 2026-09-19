import SwiftUI

/// The deterministic action a single keystroke maps to in the **library grid**.
/// A plain value so the rule is unit-testable without a window.
enum GridKeyAction: Equatable, Sendable {
    /// ⇧S ⇧A ⇧B ⇧C ⇧D ⇧F — set the selection's tier.
    case tier(String)
    /// Plain `0` — clear the selection's tier.
    case clearTier
    /// ⇧O — toggle owned for the selection.
    case toggleOwned
    /// ⇧P — toggle played for the selection.
    case togglePlayed
    /// ⇧M — apply the last-chosen "Mark Played As" value to the selection.
    case markPlayedAsLast
    /// Any plain letter/digit (and ⇧ + a non-action letter) — type-to-select.
    case typeSelect(Character)
}

/// Pure routing for the library grid's one-key actions (owner decision
/// 2026-09-19; PLAN §7 "Coarse: tiers", §8). The decision depends **only** on the
/// character and whether ⇧ is physically held — never on timing or the current
/// selection — so it is fully deterministic and covered by tests without any UI:
///
/// - Plain letters/digits (no ⇧) **always** feed type-to-select. The one exception
///   is plain `0`, which clears the tier.
/// - ⇧ + `S A B C D F` set that tier; ⇧O toggles owned; ⇧P toggles played;
///   ⇧M repeats the last "Mark Played As" value.
/// - ⇧ + any *other* letter/digit behaves like a plain letter (type-to-select), so
///   ⇧K still jumps to "Kirby".
///
/// Caps Lock is deliberately **not** treated as ⇧: the rule reads
/// `modifiers.contains(.shift)`, not the character's case, so a Caps-Locked "S"
/// type-selects instead of tiering. ⌘-combinations are handled by the caller
/// before the router is consulted.
enum GridKeyRouter {
    private static let tierLetters: Set<Character> = ["S", "A", "B", "C", "D", "F"]

    static func route(characters: String, modifiers: EventModifiers) -> GridKeyAction? {
        guard let ch = characters.first else { return nil }

        if modifiers.contains(.shift) {
            let upper = Character(ch.uppercased())
            if tierLetters.contains(upper) { return .tier(String(upper)) }
            if upper == "O" { return .toggleOwned }
            if upper == "P" { return .togglePlayed }
            if upper == "M" { return .markPlayedAsLast }
            // ⇧ + a non-action key falls through to type-to-select.
        } else if ch == "0" {
            return .clearTier
        }

        guard ch.isLetter || ch.isNumber else { return nil }
        return .typeSelect(ch)
    }
}

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
    /// "Holds up today?" (PLAN §7b) — set (or clear, with `nil`) the selection's mark:
    /// ⇧1 ⇧2 ⇧3 (⇧0 clears) in every grid scope; plain 1 2 3 (0 clears) in the
    /// "Needs a 'Holds Up' Rating" list.
    case holdsUp(HoldsUp?)
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
/// - **Holds up today?** (PLAN §7b, wave 22 — one keystroke, ⇧ at most): ⇧1 Holds Up,
///   ⇧2 Of Its Time, ⇧3 Too Archaic, ⇧0 clear — in every grid scope. In the
///   **"Needs a 'Holds Up' Rating"** list (`inHoldsUpList`) the plain digits do it too:
///   1 / 2 / 3, and plain **0 clears the holds-up mark there instead of the tier**. Plain
///   4…9 still type-select there.
///
/// These are grid keys, never menu key equivalents: a bare-digit / ⇧-digit menu
/// equivalent would steal typing in the search field and Quick Add. The digit is read
/// from the **physical top-row key** when the caller knows it (`digitKey`, from the key
/// code — so ⇧1 works whether the layout makes it "!" (US) or "1" (AZERTY)); otherwise
/// from the character, with the US shifted symbols `! @ # )` accepted as ⇧1 ⇧2 ⇧3 ⇧0.
///
/// Caps Lock is deliberately **not** treated as ⇧: the rule reads
/// `modifiers.contains(.shift)`, not the character's case, so a Caps-Locked "S"
/// type-selects instead of tiering. ⌘-combinations are handled by the caller
/// before the router is consulted.
enum GridKeyRouter {
    private static let tierLetters: Set<Character> = ["S", "A", "B", "C", "D", "F"]

    /// The value for a Holds Up digit (0 = clear).
    static func holdsUpValue(forDigit digit: Int) -> HoldsUp?? {
        switch digit {
        case 1: return .some(.holdsUp)
        case 2: return .some(.ofItsTime)
        case 3: return .some(.tooArchaic)
        case 0: return .some(nil)
        default: return .none
        }
    }

    /// The key hint for a Holds Up value in a given scope ("⇧1", or "1" in the list).
    static func holdsUpHint(for value: HoldsUp?, inHoldsUpList: Bool = false) -> String {
        let digit: String
        switch value {
        case .holdsUp: digit = "1"
        case .ofItsTime: digit = "2"
        case .tooArchaic: digit = "3"
        case nil: digit = "0"
        }
        return (inHoldsUpList ? "" : "⇧") + digit
    }

    /// The top-row digit a macOS virtual key code stands for (layout-independent), or nil.
    /// kVK_ANSI_1…9, 0 = 18 19 20 21 23 22 26 28 25 29.
    static func topRowDigit(keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        case 29: return 0
        default: return nil
        }
    }

    /// The US shifted symbols of the top-row digits the router cares about.
    private static let shiftedDigitSymbols: [Character: Int] = ["!": 1, "@": 2, "#": 3, ")": 0]

    static func route(characters: String, modifiers: EventModifiers,
                      inHoldsUpList: Bool = false, digitKey: Int? = nil) -> GridKeyAction? {
        guard let ch = characters.first else { return nil }
        let shift = modifiers.contains(.shift)

        // Holds up today? — ⇧digit everywhere; the plain digit in the rating list.
        if shift || inHoldsUpList {
            let digit = digitKey ?? ch.wholeNumberValue ?? (shift ? shiftedDigitSymbols[ch] : nil)
            if let digit, let value = holdsUpValue(forDigit: digit) { return .holdsUp(value) }
        }

        if shift {
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

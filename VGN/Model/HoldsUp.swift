import Foundation

/// **"Holds up today?"** (PLAN §7b, owner request 2026-09-25) — an optional, hand-set mark on
/// a *played* game saying how it plays **now**, as opposed to its tier (a favourites ranking
/// where nostalgia counts). A fact about the game today, never a rank.
///
/// `nil` (no value) is **Unrated** — the default; nothing is ever inferred from year,
/// platform or tier (PLAN §4 inv. 5). Stored in `games.holds_up` (v16) with the raw values
/// below, which are also the model's `Codable` form (so JSON written by any version decodes;
/// an absent key is `nil` = Unrated).
///
/// What it changes: **Play Next only** — *Holds Up* adds a small bonus to a candidate, *Of Its
/// Time* a small penalty, *Too Archaic* excludes it from the regular picks. The taste
/// profile, the ranking and the backtest never see it.
enum HoldsUp: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case holdsUp = "holds_up"
    case ofItsTime = "of_its_time"
    case tooArchaic = "too_archaic"

    var id: String { rawValue }

    /// The short label used in the inspector, menus, filter and chips.
    var label: String {
        switch self {
        case .holdsUp: return "Holds Up"
        case .ofItsTime: return "Of Its Time"
        case .tooArchaic: return "Too Archaic"
        }
    }

    /// The owner's own definition, shown as a tooltip wherever the mark is set.
    var explanation: String {
        switch self {
        case .holdsUp:
            return "Holds up — still a great play today."
        case .ofItsTime:
            return "Of its time — great then, dated now; still worth knowing."
        case .tooArchaic:
            return "Too archaic — from a gameplay point of view, no longer playable for the gamer I am today."
        }
    }

    /// An SF Symbol for compact surfaces (inspector segments, menus).
    var systemImage: String {
        switch self {
        case .holdsUp: return "checkmark.seal"
        case .ofItsTime: return "clock.arrow.circlepath"
        case .tooArchaic: return "hourglass.bottomhalf.filled"
        }
    }

    /// The label for the unrated state (`nil`).
    static let unratedLabel = "Unrated"
    /// The tooltip for the unrated state.
    static let unratedExplanation = "Unrated — not judged yet. Nothing is ever guessed from the year or platform."

    // MARK: - DB storage mapping (v16) — the one place the column is read or written

    /// The `games.holds_up` string (one of the v16 CHECK values).
    var dbValue: String { rawValue }

    /// Map a stored `games.holds_up` value; `nil` / unknown ⇒ `nil` (Unrated).
    init?(dbValue: String?) {
        guard let dbValue, let value = HoldsUp(rawValue: dbValue) else { return nil }
        self = value
    }

    /// Label for an optional mark (`nil` ⇒ "Unrated").
    static func label(for value: HoldsUp?) -> String { value?.label ?? unratedLabel }
}

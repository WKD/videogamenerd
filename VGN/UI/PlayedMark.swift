import Foundation

/// The choice a "Mark Played" action applies to a selection (PLAN §8, owner
/// request 2026-09-19): plain **played** (sets the played flag, leaves any
/// completion status alone) or **played with a completion status**
/// (`Playing` / `Finished` / `100%` / `Abandoned`).
///
/// A plain value so the menu titles, persistence and banner text are all
/// unit-testable without a window.
enum PlayedMark: Equatable, Hashable, Sendable, Identifiable {
    /// Mark played; an existing status is left untouched.
    case played
    /// Mark played **and** set this completion status.
    case status(PlayStatus)

    /// The choices offered, in menu order: Played · Playing · Finished · 100% · Abandoned.
    static let allCases: [PlayedMark] = [.played] + PlayStatus.allCases.map(PlayedMark.status)

    var id: String { storageKey }

    /// The `PlayStatus` this mark writes, or `nil` for plain "Played".
    var status: PlayStatus? {
        if case let .status(s) = self { return s }
        return nil
    }

    /// The label shown in the "Mark Played As" submenu ("Played", "Finished", …).
    var label: String {
        switch self {
        case .played: return "Played"
        case let .status(s): return s.label
        }
    }

    /// The verb form used at the top level and for the undo action name
    /// ("Mark as Finished", "Mark as Played").
    var menuTitle: String { "Mark as \(label)" }

    // MARK: Persistence

    /// A flat string key for `UserDefaults` (never collides: no `PlayStatus`
    /// raw value equals "played").
    var storageKey: String {
        switch self {
        case .played: return "played"
        case let .status(s): return s.rawValue
        }
    }

    init?(storageKey: String) {
        if storageKey == "played" { self = .played }
        else if let s = PlayStatus(rawValue: storageKey) { self = .status(s) }
        else { return nil }
    }
}

/// The exact prior played state of one game, captured before a "Mark Played"
/// batch so undo can restore it precisely (PLAN §8 undo).
struct PriorPlayState: Equatable, Sendable {
    var played: Bool
    var status: PlayStatus?
}

/// Pure banner text for a completed "Mark Played" batch (PLAN §8 feedback).
/// `changed` = games that actually moved; `already` = games already in the
/// target state (nothing to do). Grammar agreement via the same inflection
/// markup the rest of the app uses.
enum PlayedMarkFeedback {
    static func banner(mark: PlayedMark, changed: Int, already: Int) -> String {
        let label = mark.label
        if changed == 0 {
            return "^[\(already) game](inflect: true) already \(label) — unchanged."
        }
        if already == 0 {
            return "^[\(changed) game](inflect: true) marked \(label)."
        }
        return "^[\(changed) game](inflect: true) marked \(label) · \(already) already \(label)."
    }
}

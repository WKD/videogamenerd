import Foundation

/// A generic taste feature attached to a game (PLAN §4 `game_traits`, §7b). Filled
/// by IGDB enrichment and read by the Play Next recommendation engine. Foundation
/// only — a shared contract between the DB, the pure engine and the UI.
enum GameTraitKind: String, Hashable, Sendable, Codable, CaseIterable {
    // Persisted in `game_traits` (the DB CHECK allows exactly these eight).
    case franchise
    case series          // IGDB `collections`
    case developer
    case theme
    case mode            // IGDB `game_modes`
    case perspective     // IGDB `player_perspectives`
    case keyword
    case similar         // IGDB `similar_games` — value is an IGDB game id (as a string)

    // Engine-only affinity features (PLAN §7b lists genre / platform / decade among
    // the trait affinities). These are **never** written to `game_traits`; the
    // recommendation store synthesises them from `game_genres`, ownership platforms
    // and `year`. `isPersisted` guards accidental writes.
    case genre
    case platform
    case decade

    /// Whether this kind is stored in `game_traits` (vs synthesised for scoring).
    var isPersisted: Bool {
        switch self {
        case .genre, .platform, .decade: return false
        default: return true
        }
    }

    /// A short human label (the UI may format its own sentences instead).
    var label: String {
        switch self {
        case .franchise: return "Franchise"
        case .series: return "Series"
        case .developer: return "Developer"
        case .theme: return "Theme"
        case .mode: return "Mode"
        case .perspective: return "Perspective"
        case .keyword: return "Keyword"
        case .similar: return "Similar game"
        case .genre: return "Genre"
        case .platform: return "Platform"
        case .decade: return "Decade"
        }
    }
}

/// One `(kind, value)` taste feature of a game. `similar` values are IGDB game ids
/// rendered as strings (PLAN §7b); every other kind's value is a human name.
struct GameTrait: Hashable, Sendable, Codable {
    var kind: GameTraitKind
    var value: String

    init(kind: GameTraitKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

extension GameTrait {
    /// The `similar` game-id, if this trait is a similar-games link.
    var similarGameID: Int64? {
        kind == .similar ? Int64(value) : nil
    }
}

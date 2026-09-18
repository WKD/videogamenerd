import Foundation

/// Live counts shown next to the sidebar rows (PLAN §8: "live counts, one
/// observed aggregate query"). Produced by a lane-A DB observation.
struct SidebarCounts: Hashable, Sendable {
    var all: Int
    var owned: Int
    var played: Int
    var backlog: Int
    var unranked: Int
    /// Number of games waiting in the duel queue (unplaced + refine pairs).
    var duelQueue: Int
    /// Per-platform game counts, keyed by platform slug. Only platforms with
    /// ≥ 1 game are expected to appear (the sidebar hides empty ones).
    var perPlatform: [String: Int]

    init(
        all: Int = 0,
        owned: Int = 0,
        played: Int = 0,
        backlog: Int = 0,
        unranked: Int = 0,
        duelQueue: Int = 0,
        perPlatform: [String: Int] = [:]
    ) {
        self.all = all
        self.owned = owned
        self.played = played
        self.backlog = backlog
        self.unranked = unranked
        self.duelQueue = duelQueue
        self.perPlatform = perPlatform
    }

    static let empty = SidebarCounts()

    /// The count to display for a given sidebar row, or nil when that row
    /// shows no badge (Tier Board / The Top).
    func count(for selection: SidebarSelection) -> Int? {
        switch selection {
        case .all: return all
        case .owned: return owned
        case .played: return played
        case .backlog: return backlog
        case .unranked: return unranked
        case .duel: return duelQueue
        case .tierBoard, .theTop: return nil
        case .platform(let slug): return perPlatform[slug] ?? 0
        }
    }
}

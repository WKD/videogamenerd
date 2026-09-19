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
    /// Per-length-shelf game counts (PLAN §8). Counts use the time-to-beat
    /// **estimate only**, never the owner's playtime, and depend on the current
    /// ``PlayPace`` (the observation re-runs when the pace changes). A shelf with no
    /// games stays in the sidebar (dimmed), so a missing key reads as 0.
    var lengthShelves: [LengthShelf: Int]
    /// Games with no time-to-beat estimate at all (the "Unmeasured" row).
    var unmeasured: Int
    /// Games not linked to an IGDB entry (`igdb_id IS NULL`) — the "Unlinked" row,
    /// shown only when > 0 (PLAN §5.1). Part of the same single counts query.
    var unlinked: Int

    init(
        all: Int = 0,
        owned: Int = 0,
        played: Int = 0,
        backlog: Int = 0,
        unranked: Int = 0,
        duelQueue: Int = 0,
        perPlatform: [String: Int] = [:],
        lengthShelves: [LengthShelf: Int] = [:],
        unmeasured: Int = 0,
        unlinked: Int = 0
    ) {
        self.all = all
        self.owned = owned
        self.played = played
        self.backlog = backlog
        self.unranked = unranked
        self.duelQueue = duelQueue
        self.perPlatform = perPlatform
        self.lengthShelves = lengthShelves
        self.unmeasured = unmeasured
        self.unlinked = unlinked
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
        case .tierBoard, .theTop, .playNext: return nil
        case .unlinked: return unlinked
        case .length(let shelf): return lengthShelves[shelf] ?? 0
        case .unmeasured: return unmeasured
        case .platform(let slug): return perPlatform[slug] ?? 0
        }
    }
}

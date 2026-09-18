import Foundation

/// A cheap aggregate snapshot of the library for the sidebar stats popover
/// (PLAN §6.4 — "feeds a stats view"; the full stats view is a later milestone).
/// Foundation-only; Lane A fills it with a handful of aggregate queries.
struct LibraryStats: Sendable, Hashable {
    var total: Int
    var owned: Int
    var played: Int
    var backlog: Int
    /// Sum of effective playtime (manual over PSN) across all games, in seconds.
    var totalPlaytimeSeconds: Int
    /// Games per platform, most first (the popover shows the top 5).
    var byPlatform: [PlatformCount]
    /// Played games per tier, best tier first.
    var byTier: [TierCount]

    struct PlatformCount: Sendable, Hashable, Identifiable {
        var platformID: String
        var count: Int
        var id: String { platformID }
    }

    struct TierCount: Sendable, Hashable, Identifiable {
        var tierID: Int64
        var letter: String
        var count: Int
        var id: Int64 { tierID }
    }

    static let empty = LibraryStats(
        total: 0, owned: 0, played: 0, backlog: 0, totalPlaytimeSeconds: 0,
        byPlatform: [], byTier: [])
}

import Foundation

/// The scope a ``LibraryStatsReport`` is computed over — the picker at the top of
/// the stats window (PLAN §6.4). Applies to every section that has a natural game
/// universe; sections that are inherently a subset (backlog, tiers) narrow further
/// on their own.
enum StatsScope: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case owned
    case played

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .owned: return "Owned"
        case .played: return "Played"
        }
    }
}

/// The full Library Stats dashboard as a plain `Sendable` value (PLAN §6.4 — the
/// stats view: total hours, by platform/decade/tier, and the rest). Computed by
/// ``LibraryStatsStore`` in one read transaction; the UI (`VGN/UI/Stats`) only
/// renders it. Foundation-only, so it stays a Model contract with no GRDB/SwiftUI.
///
/// Every list is pre-sorted for display and every derived-score figure carries its
/// sample size `n` (only ranked games contribute a score). Sections whose source
/// column does not exist were dropped, never invented.
struct LibraryStatsReport: Sendable, Hashable {
    var scope: StatsScope
    /// The reference "now" the activity window and month labels were built from.
    var referenceDate: Date

    // MARK: 1 — Overview
    var totalGames: Int
    var ownedGames: Int
    var playedGames: Int
    /// Owned and never played.
    var backlogGames: Int
    var playedNotOwned: Int
    var compilations: Int
    /// Owned copies (products) grouped by format — physical / digital / ROM.
    var copiesByFormat: [FormatCount]

    // MARK: 2 — Playtime
    /// Effective playtime = manual over PSN (PLAN §6.4), summed, in seconds.
    var totalPlaytimeSeconds: Int
    var playtimeByPlatform: [PlatformSeconds]
    var playtimeByDecade: [DecadeSeconds]
    var playtimeByTier: [TierSeconds]
    /// Up to ten most-played games.
    var topPlayed: [GamePlaytime]
    /// "Me vs. average": over games that have both my effective playtime and an
    /// IGDB main-story (`ttb_normally`) estimate.
    var myHoursVsAverage: MeVsAverage

    // MARK: 3 — Platforms
    /// Every platform with ≥ 1 game (all, not a top-N), with the owned/played split.
    var platformBreakdown: [PlatformBreakdown]

    // MARK: 4 — Decades & years
    var gamesByDecade: [DecadeCount]
    var gamesByYear: [YearCount]
    var unknownYearCount: Int

    // MARK: 5 — Tiers & scores
    var tierBreakdown: [TierBreakdown]
    /// Played games with no tier.
    var unrankedPlayedCount: Int
    var averageScoreByPlatform: [PlatformScore]
    var averageScoreByDecade: [DecadeScore]
    var bestGameByPlatform: [PlatformBestGame]

    // MARK: 6 — Genres
    var gamesByGenre: [GenreCount]
    /// Average derived score per genre, only where at least three ranked games.
    var averageScoreByGenre: [GenreScore]

    // MARK: 7 — Status
    var statusCounts: StatusCounts
    /// (finished + 100 %) / played, or nil when nothing is played.
    var completionRate: Double?

    // MARK: 8 — Activity
    /// Games added per month, the last twelve months, oldest → newest.
    var addedByMonth: [MonthCount]

    var isEmpty: Bool { totalGames == 0 }

    // MARK: - Nested value types

    struct FormatCount: Sendable, Hashable, Identifiable {
        var format: ProductFormat
        var count: Int
        var id: String { format.rawValue }
    }

    struct PlatformSeconds: Sendable, Hashable, Identifiable {
        var platformID: String
        var seconds: Int
        var id: String { platformID }
    }

    struct DecadeSeconds: Sendable, Hashable, Identifiable {
        /// nil = unknown release year.
        var decade: Int?
        var seconds: Int
        var id: Int { decade ?? -1 }
    }

    struct TierSeconds: Sendable, Hashable, Identifiable {
        var tierID: Int64
        var letter: String
        var colorHex: String
        var seconds: Int
        var id: Int64 { tierID }
    }

    struct GamePlaytime: Sendable, Hashable, Identifiable {
        var gameID: Int64
        var title: String
        var seconds: Int
        var id: Int64 { gameID }
    }

    struct MeVsAverage: Sendable, Hashable {
        var mineSeconds: Int
        var averageSeconds: Int
        var gameCount: Int
        /// Backlog size in estimated hours: sum of IGDB main for unplayed owned
        /// games, plus how many such games have no estimate.
        var backlogEstimateSeconds: Int
        var backlogGamesMissingEstimate: Int
    }

    struct PlatformBreakdown: Sendable, Hashable, Identifiable {
        var platformID: String
        var total: Int
        var owned: Int
        var played: Int
        var id: String { platformID }
    }

    struct DecadeCount: Sendable, Hashable, Identifiable {
        var decade: Int?
        var count: Int
        var id: Int { decade ?? -1 }
    }

    struct YearCount: Sendable, Hashable, Identifiable {
        var year: Int
        var count: Int
        var id: Int { year }
    }

    struct TierBreakdown: Sendable, Hashable, Identifiable {
        var tierID: Int64
        var letter: String
        var label: String
        var colorHex: String
        var sort: Int
        var count: Int
        var id: Int64 { tierID }
    }

    struct PlatformScore: Sendable, Hashable, Identifiable {
        var platformID: String
        var average: Double
        var n: Int
        var id: String { platformID }
    }

    struct DecadeScore: Sendable, Hashable, Identifiable {
        var decade: Int?
        var average: Double
        var n: Int
        var id: Int { decade ?? -1 }
    }

    struct PlatformBestGame: Sendable, Hashable, Identifiable {
        var platformID: String
        var gameID: Int64
        var title: String
        var score: Double
        var id: String { platformID }
    }

    struct GenreCount: Sendable, Hashable, Identifiable {
        var genre: String
        var count: Int
        var id: String { genre }
    }

    struct GenreScore: Sendable, Hashable, Identifiable {
        var genre: String
        var average: Double
        var n: Int
        var id: String { genre }
    }

    struct StatusCounts: Sendable, Hashable {
        var playing: Int
        var finished: Int
        var completed: Int   // 100 %
        var abandoned: Int   // dropped, done with it (revisit = 0)
        /// Dropped but flagged "To Revisit" (abandoned + revisit = 1, v15) — its own slice,
        /// disjoint from ``abandoned``.
        var toRevisit: Int
        /// Played games with no status set.
        var noStatus: Int

        static let zero = StatusCounts(playing: 0, finished: 0, completed: 0,
                                       abandoned: 0, toRevisit: 0, noStatus: 0)
    }

    struct MonthCount: Sendable, Hashable, Identifiable {
        var year: Int
        var month: Int
        var count: Int
        var id: Int { year * 100 + month }

        /// Short "MMM" label ("Jan"), or "MMM yy" at a year boundary.
        var shortLabel: String {
            let names = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let name = (1...12).contains(month) ? names[month] : "\(month)"
            return month == 1 ? "\(name) \(String(format: "%02d", year % 100))" : name
        }
    }

    /// An empty report (used for the loading / no-games states).
    static func empty(scope: StatsScope = .all, referenceDate: Date = Date()) -> LibraryStatsReport {
        LibraryStatsReport(
            scope: scope, referenceDate: referenceDate,
            totalGames: 0, ownedGames: 0, playedGames: 0, backlogGames: 0,
            playedNotOwned: 0, compilations: 0, copiesByFormat: [],
            totalPlaytimeSeconds: 0, playtimeByPlatform: [], playtimeByDecade: [],
            playtimeByTier: [], topPlayed: [],
            myHoursVsAverage: MeVsAverage(mineSeconds: 0, averageSeconds: 0, gameCount: 0,
                                          backlogEstimateSeconds: 0, backlogGamesMissingEstimate: 0),
            platformBreakdown: [], gamesByDecade: [], gamesByYear: [], unknownYearCount: 0,
            tierBreakdown: [], unrankedPlayedCount: 0, averageScoreByPlatform: [],
            averageScoreByDecade: [], bestGameByPlatform: [], gamesByGenre: [],
            averageScoreByGenre: [], statusCounts: .zero, completionRate: nil,
            addedByMonth: [])
    }
}

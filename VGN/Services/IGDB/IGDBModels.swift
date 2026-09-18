import Foundation

// MARK: - Raw decode DTOs (mirror the IGDB JSON shapes we request)

/// One game as IGDB returns it for our field list. Every field is optional because
/// IGDB omits absent relations entirely.
struct IGDBGameDTO: Decodable, Sendable {
    let id: Int64
    let name: String?
    let slug: String?
    let summary: String?
    let firstReleaseDate: Int?      // unix seconds, UTC
    let gameType: Int?
    let cover: Cover?
    let platforms: [PlatformRef]?
    let genres: [NamedRef]?
    let alternativeNames: [AltName]?
    let bundles: [Int64]?
    let parentGame: Int64?
    let versionParent: Int64?
    // §7b taste traits.
    let franchise: NamedRef?
    let franchises: [NamedRef]?
    let collection: NamedRef?
    let collections: [NamedRef]?
    let involvedCompanies: [InvolvedCompany]?
    let themes: [NamedRef]?
    let gameModes: [NamedRef]?
    let playerPerspectives: [NamedRef]?
    let keywords: [NamedRef]?
    let similarGames: [Int64]?
    // §7b crowd prior. `total_*` is IGDB's blended critic+user score; falls back to
    // `aggregated_*` (critics) then `rating`/`rating_count` (users).
    let totalRating: Double?
    let totalRatingCount: Int?
    let aggregatedRating: Double?
    let aggregatedRatingCount: Int?
    let rating: Double?
    let ratingCount: Int?

    struct Cover: Decodable, Sendable { let imageId: String?
        enum CodingKeys: String, CodingKey { case imageId = "image_id" }
    }
    /// Requesting `platforms.abbreviation` expands each platform to an object.
    struct PlatformRef: Decodable, Sendable { let id: Int; let abbreviation: String? }
    struct NamedRef: Decodable, Sendable { let id: Int64?; let name: String? }
    struct AltName: Decodable, Sendable { let id: Int64?; let name: String?; let comment: String? }
    /// One `involved_companies` row: `developer` marks the studio (vs publisher/
    /// porter/support).
    struct InvolvedCompany: Decodable, Sendable {
        let company: NamedRef?
        let developer: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, summary, cover, platforms, genres, bundles
        case franchise, franchises, collection, collections, themes, keywords, rating
        case firstReleaseDate = "first_release_date"
        case gameType = "game_type"
        case alternativeNames = "alternative_names"
        case parentGame = "parent_game"
        case versionParent = "version_parent"
        case involvedCompanies = "involved_companies"
        case gameModes = "game_modes"
        case playerPerspectives = "player_perspectives"
        case similarGames = "similar_games"
        case totalRating = "total_rating"
        case totalRatingCount = "total_rating_count"
        case aggregatedRating = "aggregated_rating"
        case aggregatedRatingCount = "aggregated_rating_count"
        case ratingCount = "rating_count"
    }
}

/// One `game_time_to_beats` row. Durations are in seconds; any may be absent.
struct IGDBTimeToBeatDTO: Decodable, Sendable {
    let gameId: Int64
    let hastily: Int?
    let normally: Int?
    let completely: Int?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case hastily, normally, completely, count
        case gameId = "game_id"
    }
}

// MARK: - Public result types (what other lanes consume)

/// A lightweight autocomplete/search result (PLAN §5.1 field list, §6.1 Quick Add).
struct IGDBSearchResult: Sendable, Equatable, Identifiable {
    let id: Int64
    let name: String
    let releaseYear: Int?
    let coverImageID: String?
    /// IGDB platform ids attached to this game.
    let platformIGDBIDs: [Int]
    /// IGDB platform abbreviations (e.g. "PS4"), for a quick chip when no slug maps.
    let platformAbbreviations: [String]
    /// VGN platform slugs mapped via `PlatformCatalog` (deduped, catalogue order).
    let platformSlugs: [String]
    let genres: [String]
    let alternativeNames: [String]
    let gameType: IGDBGameType
    /// Convenience: the game is a bundle/pack whose members can be expanded.
    var isBundle: Bool { gameType.isCompilation }
}

/// Full metadata for enrichment (PLAN §5.1 games(ids:)).
struct IGDBGameMetadata: Sendable, Equatable, Identifiable {
    let id: Int64
    let name: String
    let slug: String?
    let summary: String?
    let releaseDate: Date?
    let releaseYear: Int?
    let coverImageID: String?
    let platformIGDBIDs: [Int]
    let platformSlugs: [String]
    let genres: [String]
    let alternativeNames: [String]
    let gameType: IGDBGameType
    /// Member game ids when this is a bundle (may be empty even for a bundle —
    /// coverage is imperfect, PLAN §5.1).
    let bundleMemberIDs: [Int64]
    let parentGameID: Int64?
    let versionParentID: Int64?
    // §7b taste traits (names; deduped, in IGDB order). `similarGameIDs` are IGDB
    // game ids. `keywords` is capped (see ``IGDBTraitLimits``).
    var franchises: [String] = []
    var series: [String] = []
    var developers: [String] = []
    var themes: [String] = []
    var gameModes: [String] = []
    var perspectives: [String] = []
    var keywords: [String] = []
    var similarGameIDs: [Int64] = []
    /// Resolved crowd rating (0…100) and its sample count — `total_rating` when
    /// present, else `aggregated_rating`, else `rating` (PLAN §7b, verified live).
    var igdbRating: Double? = nil
    var igdbRatingCount: Int? = nil

    /// The `[GameTrait]` this metadata contributes (PLAN §7b game_traits).
    var traits: [GameTrait] {
        var out: [GameTrait] = []
        for v in franchises { out.append(GameTrait(kind: .franchise, value: v)) }
        for v in series { out.append(GameTrait(kind: .series, value: v)) }
        for v in developers { out.append(GameTrait(kind: .developer, value: v)) }
        for v in themes { out.append(GameTrait(kind: .theme, value: v)) }
        for v in gameModes { out.append(GameTrait(kind: .mode, value: v)) }
        for v in perspectives { out.append(GameTrait(kind: .perspective, value: v)) }
        for v in keywords { out.append(GameTrait(kind: .keyword, value: v)) }
        for id in similarGameIDs { out.append(GameTrait(kind: .similar, value: String(id))) }
        return out
    }
}

/// Caps for high-cardinality IGDB trait lists (some games have 100+ keywords).
enum IGDBTraitLimits {
    static let keywords = 12
}

/// Average completion times (PLAN §5.1 / §6.4). All durations in seconds.
struct IGDBTimeToBeat: Sendable, Equatable, Identifiable {
    let gameID: Int64
    let hastily: Int?
    let normally: Int?
    let completely: Int?
    let count: Int?
    var id: Int64 { gameID }
}

// MARK: - Field lists

enum IGDBFields {
    /// PLAN §5.1 search field list, plus a few edition-disambiguating extras.
    static let search = [
        "name", "first_release_date", "platforms.abbreviation",
        "cover.image_id", "genres.name", "game_type",
        "alternative_names.name", "slug", "parent_game", "version_parent",
    ]

    /// Fuller set for enrichment: adds summary, the bundle relation, and the §7b
    /// taste traits + crowd-rating fields. `franchises`/`collections` (arrays) are
    /// more reliably populated than the singular `franchise`/`collection`, so both
    /// are requested; `total_rating` falls back to `aggregated_rating`/`rating`.
    static let full = [
        "name", "slug", "summary", "first_release_date",
        "platforms.abbreviation", "cover.image_id", "genres.name", "game_type",
        "alternative_names.name", "bundles", "parent_game", "version_parent",
        "franchise.name", "franchises.name", "collection.name", "collections.name",
        "involved_companies.company.name", "involved_companies.developer",
        "themes.name", "game_modes.name", "player_perspectives.name", "keywords.name",
        "similar_games",
        "total_rating", "total_rating_count", "aggregated_rating",
        "aggregated_rating_count", "rating", "rating_count",
    ]

    static let timeToBeat = ["game_id", "hastily", "normally", "completely", "count"]
}

// MARK: - Date helpers

enum IGDBDate {
    /// IGDB `first_release_date` (unix seconds, UTC) → `Date`.
    static func date(fromUnix seconds: Int?) -> Date? {
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Calendar year (UTC) of a unix timestamp.
    static func year(fromUnix seconds: Int?) -> Int? {
        guard let date = date(fromUnix: seconds) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.component(.year, from: date)
    }
}

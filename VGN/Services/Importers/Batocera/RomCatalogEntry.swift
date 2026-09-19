import Foundation

/// One row of the ROM catalogue (PLAN §15) as a plain `Sendable` value — the projection
/// the phase-2 browser, promotion review and Discover row consume. It is **never** a
/// library game: nothing in the grid, counts, stats, ranking or exports reads it.
struct RomCatalogEntry: Sendable, Hashable, Identifiable {
    var id: Int64
    var source: String
    var system: String
    var platformID: String?
    var relativePath: String
    var name: String
    var sortTitle: String
    var normalisedTitle: String
    var libretroKey: String
    var screenScraperID: String?
    var md5: String?
    var region: String?
    var lang: String?
    var genre: String?
    var family: String?
    var developer: String?
    var publisher: String?
    var releaseYear: Int?
    var rating: Double?
    var players: String?
    var playCount: Int
    var gameTimeSeconds: Int
    var lastPlayedAt: Date?
    var isFavorite: Bool
    var imagePath: String?
    var thumbnailPath: String?
    var firstSeenAt: Date?
    var lastSeenAt: Date?
    var removedAt: Date?
    var promotedGameID: Int64?
    var dismissedAt: Date?
    var notInterested: Bool

    /// The `<system>/<relativePath>` external id used when this ROM is promoted (PLAN §15).
    var externalID: String { "\(system)/\(relativePath)" }

    /// Whether this entry is a promotion candidate (played > 5 min or favourite).
    var isPromotionCandidate: Bool {
        BatoceraPromotion.isCandidate(gameTimeSeconds: gameTimeSeconds, isFavorite: isFavorite)
    }

    /// Taste features for the recommendation engine (offline, from gamelist metadata).
    var traits: [GameTrait] {
        RomCatalogTraits.traits(genre: genre, family: family, developer: developer,
                                releaseYear: releaseYear)
    }

    init(id: Int64 = 0, source: String = "batocera", system: String, platformID: String?,
         relativePath: String, name: String, sortTitle: String = "", normalisedTitle: String = "",
         libretroKey: String = "", screenScraperID: String? = nil, md5: String? = nil,
         region: String? = nil, lang: String? = nil, genre: String? = nil, family: String? = nil,
         developer: String? = nil, publisher: String? = nil, releaseYear: Int? = nil,
         rating: Double? = nil, players: String? = nil, playCount: Int = 0,
         gameTimeSeconds: Int = 0, lastPlayedAt: Date? = nil, isFavorite: Bool = false,
         imagePath: String? = nil, thumbnailPath: String? = nil, firstSeenAt: Date? = nil,
         lastSeenAt: Date? = nil, removedAt: Date? = nil, promotedGameID: Int64? = nil,
         dismissedAt: Date? = nil, notInterested: Bool = false) {
        self.id = id
        self.source = source
        self.system = system
        self.platformID = platformID
        self.relativePath = relativePath
        self.name = name
        self.sortTitle = sortTitle
        self.normalisedTitle = normalisedTitle
        self.libretroKey = libretroKey
        self.screenScraperID = screenScraperID
        self.md5 = md5
        self.region = region
        self.lang = lang
        self.genre = genre
        self.family = family
        self.developer = developer
        self.publisher = publisher
        self.releaseYear = releaseYear
        self.rating = rating
        self.players = players
        self.playCount = playCount
        self.gameTimeSeconds = gameTimeSeconds
        self.lastPlayedAt = lastPlayedAt
        self.isFavorite = isFavorite
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.removedAt = removedAt
        self.promotedGameID = promotedGameID
        self.dismissedAt = dismissedAt
        self.notInterested = notInterested
    }

    /// Build a fresh catalogue entry from a folded gamelist representative (PLAN §15). The
    /// sort / normalised titles come from the shared `SortTitle` / `TitleNormalizer` stages,
    /// so catalogue search folds diacritics exactly like library search.
    static func make(from game: BatoceraGame, platformID: String?, libretroKey: String,
                     source: String = "batocera") -> RomCatalogEntry {
        RomCatalogEntry(
            source: source,
            system: game.system,
            platformID: platformID,
            relativePath: game.relativePath,
            name: game.name,
            sortTitle: SortTitle.make(from: game.name),
            normalisedTitle: TitleNormalizer.normalize(game.name, level: .articleless),
            libretroKey: libretroKey,
            screenScraperID: game.screenScraperID,
            md5: game.md5,
            region: game.region,
            lang: game.lang,
            genre: game.genre,
            family: game.family,
            developer: game.developer,
            publisher: game.publisher,
            releaseYear: game.releaseYear,
            rating: game.rating,
            players: game.players,
            playCount: game.playCount,
            gameTimeSeconds: game.gameTimeSeconds,
            lastPlayedAt: game.lastPlayed,
            isFavorite: game.isFavorite,
            imagePath: game.imageRelativePath,
            thumbnailPath: game.thumbnailRelativePath)
    }
}

/// Per-system change-detection state (PLAN §15 — mtime/size compared against the share).
struct RomCatalogSyncState: Sendable, Hashable {
    var system: String
    var gamelistMtime: Date?
    var gamelistSize: Int64
    var lastReadAt: Date?
    var entryCount: Int
}

/// One system's sync counts (added / updated / removed catalogue rows).
struct RomCatalogSyncCounts: Sendable, Hashable {
    var added = 0
    var updated = 0
    var removed = 0
}

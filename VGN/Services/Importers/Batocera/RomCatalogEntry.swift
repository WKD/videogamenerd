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

    // MARK: The Vault — PS Plus fields (PLAN §16, migration v11)

    /// The PSN external id (mirrors ``relativePath`` for a PS Plus row); nil for Batocera.
    var externalIDColumn: String?
    /// A remote cover URL (PS Store), loaded through the cover cache — never copied into the
    /// app's cover folder. nil for Batocera, which reads ``imagePath`` off the share.
    var coverURL: String?
    /// The PSN membership marker (`ps_plus`); nil for Batocera.
    var membership: String?
    /// A human note for the browser (e.g. "PS4 & PS5 versions"); nil when there is none.
    var crossGenNote: String?
    /// The matched IGDB id (nil until the trait pass runs).
    var igdbID: Int64?
    /// IGDB time-to-beat "main" seconds, for the "From the vault" time-fit term (nil for a ROM
    /// or an unmatched entry).
    var lengthMainSeconds: Int?
    /// IGDB time-to-beat "completionist" seconds (nil for a ROM or an unmatched entry).
    var lengthCompleteSeconds: Int?
    /// A JSON array of the entry's IGDB traits (genres/themes/keywords/franchise/developer),
    /// so a matched PS Plus row is taste-scorable offline. nil until matched.
    var traitsJSON: String?
    /// The IGDB crowd rating (0…100), for the crowd prior. nil until matched.
    var igdbRating: Double?
    /// The trait pass's outcome for this row (nil = never attempted), so a matched **or**
    /// no-matched entry is never re-queried (PLAN §16).
    var matchState: VaultMatchState?
    /// When the trait pass last touched the row.
    var matchedAt: Date?
    /// The owner sent this row to the Vault by hand and **really owns** it (a purchase / a GOG or
    /// Delicious game), so it never gets the PS Plus boost / deadline (PLAN §16, v12). A PS Plus
    /// claim keeps `owned = false` and its `membership`.
    var owned: Bool = false

    /// The `rom_catalog.source` as a typed value (nil for an unknown source string).
    var vaultSource: VaultSource? { VaultSource(storage: source) }

    /// The `<system>/<relativePath>` external id used when this ROM is promoted (PLAN §15). A
    /// PS Plus row carries its PSN external id in ``externalIDColumn`` (also == `relativePath`).
    var externalID: String { externalIDColumn ?? "\(system)/\(relativePath)" }

    /// Whether this entry is a promotion candidate (played > 5 min or favourite).
    var isPromotionCandidate: Bool {
        BatoceraPromotion.isCandidate(gameTimeSeconds: gameTimeSeconds, isFavorite: isFavorite)
    }

    /// Taste features for the recommendation engine. A matched PS Plus entry carries persisted
    /// IGDB traits (``traitsJSON``); everything else derives them offline from gamelist
    /// metadata (PLAN §15/§16). A `decade` trait is always added from ``releaseYear`` so the
    /// two paths line up.
    var traits: [GameTrait] {
        if let json = traitsJSON, let decoded = Self.decodeTraits(json) {
            return decoded
        }
        return RomCatalogTraits.traits(genre: genre, family: family, developer: developer,
                                       releaseYear: releaseYear)
    }

    /// Whether this entry has enough to be taste-scored and suggested in "From the vault"
    /// (PLAN §16): a Batocera ROM always is (offline gamelist traits); a PS Plus entry only
    /// once matched to IGDB (unmatched entries are browsable but never suggested).
    var isSuggestable: Bool {
        if vaultSource == .psn { return matchState == .matched }
        return true
    }

    /// Crowd rating on a 0…100 scale for the recommendation crowd prior: IGDB (already 0…100)
    /// for a matched PS Plus entry, ScreenScraper (0…1 → ×100) for a Batocera ROM.
    var crowdRating0to100: Double? {
        if vaultSource == .psn { return igdbRating }
        return rating.map { $0 * 100 }
    }

    /// The owner's **personal length** for a play style (PLAN §8), from the IGDB time-to-beat
    /// on a matched PS Plus entry. A Batocera ROM has no length ⇒ nil (time fit stays neutral).
    func personalLength(style: PlayStyle) -> PersonalLength? {
        PersonalLength.compute(normallyS: lengthMainSeconds, completelyS: lengthCompleteSeconds,
                               style: style)
    }

    static func decodeTraits(_ json: String) -> [GameTrait]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([GameTrait].self, from: data)
    }

    static func encodeTraits(_ traits: [GameTrait]) -> String? {
        guard let data = try? JSONEncoder().encode(traits) else { return nil }
        return String(data: data, encoding: .utf8)
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
         dismissedAt: Date? = nil, notInterested: Bool = false,
         externalIDColumn: String? = nil, coverURL: String? = nil, membership: String? = nil,
         crossGenNote: String? = nil, igdbID: Int64? = nil, lengthMainSeconds: Int? = nil,
         lengthCompleteSeconds: Int? = nil, traitsJSON: String? = nil, igdbRating: Double? = nil,
         matchState: VaultMatchState? = nil, matchedAt: Date? = nil, owned: Bool = false) {
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
        self.externalIDColumn = externalIDColumn
        self.coverURL = coverURL
        self.membership = membership
        self.crossGenNote = crossGenNote
        self.igdbID = igdbID
        self.lengthMainSeconds = lengthMainSeconds
        self.lengthCompleteSeconds = lengthCompleteSeconds
        self.traitsJSON = traitsJSON
        self.igdbRating = igdbRating
        self.matchState = matchState
        self.matchedAt = matchedAt
        self.owned = owned
    }

    /// Whether this Vault entry should get the PS Plus boost / deadline: a PS Plus claim that is
    /// not a hand-vaulted purchase (PLAN §16). A `owned` entry never does.
    var isPSPlusSubscription: Bool { vaultSource == .psn && !owned }

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

    /// Build a Vault entry for a review row the owner **sent to the Vault by hand** (PLAN §16 —
    /// the fourth fate). Works for any importer source (GOG, Delicious, PSN): `owned = true` for a
    /// real purchase, `owned = false` + `membership` for a PS Plus claim (so it keeps the deadline
    /// boost). `system = <platform slug>`, `relative_path = <external id>`.
    static func makeSentToVault(source: String, externalID: String, platform: String, name: String,
                                igdbID: Int64?, membership: String?, owned: Bool,
                                coverURL: String? = nil) -> RomCatalogEntry {
        RomCatalogEntry(
            source: source,
            system: platform,
            platformID: platform,
            relativePath: externalID,
            name: name,
            sortTitle: SortTitle.make(from: name),
            normalisedTitle: TitleNormalizer.normalize(name, level: .articleless),
            externalIDColumn: externalID,
            coverURL: coverURL,
            membership: membership,
            igdbID: igdbID,
            owned: owned)
    }

    /// Build a PS Plus Vault entry from a staged PSN row (PLAN §16). Its identity keeps the
    /// `UNIQUE(source, system, relative_path)` contract by using `system = <platform slug>`
    /// and `relative_path = <PSN external id>`; the external id is also kept in its own column.
    static func makePSNVault(externalID: String, platform: String, name: String,
                             coverURL: String?, membership: String?,
                             crossGenNote: String? = nil) -> RomCatalogEntry {
        RomCatalogEntry(
            source: VaultSource.psn.storage,
            system: platform,
            platformID: platform,
            relativePath: externalID,
            name: name,
            sortTitle: SortTitle.make(from: name),
            normalisedTitle: TitleNormalizer.normalize(name, level: .articleless),
            externalIDColumn: externalID,
            coverURL: coverURL,
            membership: membership,
            crossGenNote: crossGenNote)
    }
}

/// The IGDB trait-matching outcome for a PS Plus Vault entry (PLAN §16). Set once so an entry
/// is never re-queried, matched or not.
enum VaultMatchState: String, Hashable, Sendable {
    case matched
    case noMatch = "no_match"
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

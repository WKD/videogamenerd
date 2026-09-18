import Foundation

/// Everything needed to add one game (from a catalogue hit or manual entry).
///
/// `owned` ⇒ a single Product is created on `platformIDs.first` (physical or
/// digital, from `format`/`source`). `played` (or a non-nil `tierID`, which
/// implies played) ⇒ the game is marked played. Every platform in `platformIDs`
/// gets a `game_platforms` row so the game counts for those platforms.
struct GameDraft: Sendable, Equatable {
    var title: String
    var igdbID: Int64?
    var releaseDate: Date?
    var year: Int?
    var altTitles: [String]
    var platformIDs: [String]
    var owned: Bool
    var played: Bool
    /// Setting a tier on add implies played (PLAN §6.1 Quick Add).
    var tierID: Int64?
    var format: ProductFormat
    var source: ProductSource
    var status: PlayStatus?

    init(
        title: String,
        igdbID: Int64? = nil,
        releaseDate: Date? = nil,
        year: Int? = nil,
        altTitles: [String] = [],
        platformIDs: [String] = [],
        owned: Bool = false,
        played: Bool = false,
        tierID: Int64? = nil,
        format: ProductFormat = .physical,
        source: ProductSource = .manual,
        status: PlayStatus? = nil
    ) {
        self.title = title
        self.igdbID = igdbID
        self.releaseDate = releaseDate
        self.year = year
        self.altTitles = altTitles
        self.platformIDs = platformIDs
        self.owned = owned
        self.played = played
        self.tierID = tierID
        self.format = format
        self.source = source
        self.status = status
    }
}

/// The product side of ``LibraryStore/addCompilation(product:members:)``.
struct ProductDraft: Sendable, Equatable {
    var title: String?
    var platformID: String
    var format: ProductFormat
    var source: ProductSource
    var edition: String?
    var region: String?
    var igdbID: Int64?
    var acquiredAt: Date?

    init(
        title: String? = nil,
        platformID: String,
        format: ProductFormat = .physical,
        source: ProductSource = .manual,
        edition: String? = nil,
        region: String? = nil,
        igdbID: Int64? = nil,
        acquiredAt: Date? = nil
    ) {
        self.title = title
        self.platformID = platformID
        self.format = format
        self.source = source
        self.edition = edition
        self.region = region
        self.igdbID = igdbID
        self.acquiredAt = acquiredAt
    }
}

/// One member game of a compilation, with its position in the product.
struct CompilationMemberDraft: Sendable, Equatable {
    var title: String
    var igdbID: Int64?
    var releaseDate: Date?
    var year: Int?
    var altTitles: [String]
    var played: Bool
    var status: PlayStatus?
    var position: Int

    init(
        title: String,
        igdbID: Int64? = nil,
        releaseDate: Date? = nil,
        year: Int? = nil,
        altTitles: [String] = [],
        played: Bool = false,
        status: PlayStatus? = nil,
        position: Int = 0
    ) {
        self.title = title
        self.igdbID = igdbID
        self.releaseDate = releaseDate
        self.year = year
        self.altTitles = altTitles
        self.played = played
        self.status = status
        self.position = position
    }
}

/// What a metadata write changes. A non-nil field is applied; a nil field is
/// left untouched. Enrichment fills these in the next wave (PLAN §9).
struct MetadataPatch: Sendable, Equatable {
    var title: String?
    var summary: String?
    var releaseDate: Date?
    var year: Int?
    /// Replaces the game's alternative-title set (rebuilds the FTS alt column).
    var altTitles: [String]?
    /// Replaces the game's genre set (upserts genres + rewrites the join).
    var genres: [String]?
    var coverFile: String?
    var igdbCoverImageID: String?
    var igdbID: Int64?
    var ttbHastilyS: Int?
    var ttbNormallyS: Int?
    var ttbCompletelyS: Int?
    var ttbSource: String?
    /// Replaces the game's IGDB-derived trait set (PLAN §7b). When non-nil, every
    /// existing enrichment-sourced trait row is rebuilt from this list (replace-all
    /// per kind — see ``LibraryStore/setTraits(_:gameID:db:)``).
    var traits: [GameTrait]?
    /// IGDB aggregated rating (0…100) — the crowd prior (PLAN §7b).
    var igdbRating: Double?
    var igdbRatingCount: Int?

    init(
        title: String? = nil,
        summary: String? = nil,
        releaseDate: Date? = nil,
        year: Int? = nil,
        altTitles: [String]? = nil,
        genres: [String]? = nil,
        coverFile: String? = nil,
        igdbCoverImageID: String? = nil,
        igdbID: Int64? = nil,
        ttbHastilyS: Int? = nil,
        ttbNormallyS: Int? = nil,
        ttbCompletelyS: Int? = nil,
        ttbSource: String? = nil,
        traits: [GameTrait]? = nil,
        igdbRating: Double? = nil,
        igdbRatingCount: Int? = nil
    ) {
        self.title = title
        self.summary = summary
        self.releaseDate = releaseDate
        self.year = year
        self.altTitles = altTitles
        self.genres = genres
        self.coverFile = coverFile
        self.igdbCoverImageID = igdbCoverImageID
        self.igdbID = igdbID
        self.ttbHastilyS = ttbHastilyS
        self.ttbNormallyS = ttbNormallyS
        self.ttbCompletelyS = ttbCompletelyS
        self.ttbSource = ttbSource
        self.traits = traits
        self.igdbRating = igdbRating
        self.igdbRatingCount = igdbRatingCount
    }
}

/// What happened when adding a game (PLAN §4 dedupe: same igdb_id reuses the
/// Game — Elden Ring PS4 + PS5 = one Game, two Products).
enum AddOutcome: Sendable, Equatable {
    /// A brand-new Game was created.
    case created(gameID: Int64)
    /// An existing Game was reused and a new owned Product (copy) was added.
    case addedCopy(gameID: Int64)
    /// An existing Game already covered this add; nothing new was created.
    case alreadyPresent(gameID: Int64)

    var gameID: Int64 {
        switch self {
        case let .created(id), let .addedCopy(id), let .alreadyPresent(id): return id
        }
    }
}

/// The result of an operation that could leave a game neither owned nor played
/// (PLAN §4 invariant 1). When `.wouldOrphan` is returned, NO change was made —
/// the transaction rolled back — so the UI can confirm and retry with
/// `confirmOrphanDelete: true` (which deletes the listed games) or cancel.
enum WriteOutcome: Sendable, Equatable {
    case ok
    case wouldOrphan([Int64])
}

/// The result of ``LibraryStore/setTier(gameIDs:tierID:)``. Only played games
/// can carry a tier (invariant 2), so unplayed games are skipped and reported.
struct SetTierOutcome: Sendable, Equatable {
    var applied: [Int64]
    var skippedUnplayed: [Int64]
}

import Foundation
import GRDB

/// GRDB record for the `games` table (PLAN §4). The `decade` column is
/// generated in SQL and therefore intentionally absent here (read it via a
/// query when needed). `played`, `tier_id` and `rank_key` invariants are held
/// by `LibraryStore`; the DB also CHECKs them.
struct GameRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var igdbID: Int64?
    var title: String
    var sortTitle: String
    var altTitles: String            // newline-joined; mirrored into games_fts
    var summary: String?
    var releaseDate: Date?
    var year: Int?
    var played: Bool
    var status: String?
    var tierID: Int64?
    var rankKey: Int64?
    var myPlaytimeS: Int?
    var psnPlaytimeS: Int?
    var ttbHastilyS: Int?
    var ttbNormallyS: Int?
    var ttbCompletelyS: Int?
    var ttbSource: String?
    var igdbCoverImageID: String?
    var coverFile: String?
    var igdbRating: Double?
    var igdbRatingCount: Int?
    var userEdited: String
    /// HowLongToBeat game id kept when the HLTB fallback filled an estimate (v6).
    var hltbID: Int64?
    /// How the game first entered the library, for debugging (v6). See ``GameOrigin``.
    var origin: String?
    var addedAt: Date
    var updatedAt: Date

    static let databaseTableName = "games"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case igdbID = "igdb_id"
        case title
        case sortTitle = "sort_title"
        case altTitles = "alt_titles"
        case summary
        case releaseDate = "release_date"
        case year
        case played
        case status
        case tierID = "tier_id"
        case rankKey = "rank_key"
        case myPlaytimeS = "my_playtime_s"
        case psnPlaytimeS = "psn_playtime_s"
        case ttbHastilyS = "ttb_hastily_s"
        case ttbNormallyS = "ttb_normally_s"
        case ttbCompletelyS = "ttb_completely_s"
        case ttbSource = "ttb_source"
        case igdbCoverImageID = "igdb_cover_image_id"
        case coverFile = "cover_file"
        case igdbRating = "igdb_rating"
        case igdbRatingCount = "igdb_rating_count"
        case userEdited = "user_edited"
        case hltbID = "hltb_id"
        case origin
        case addedAt = "added_at"
        case updatedAt = "updated_at"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(
        id: Int64? = nil,
        igdbID: Int64? = nil,
        title: String,
        sortTitle: String = "",
        altTitles: String = "",
        summary: String? = nil,
        releaseDate: Date? = nil,
        year: Int? = nil,
        played: Bool = false,
        status: String? = nil,
        tierID: Int64? = nil,
        rankKey: Int64? = nil,
        myPlaytimeS: Int? = nil,
        psnPlaytimeS: Int? = nil,
        ttbHastilyS: Int? = nil,
        ttbNormallyS: Int? = nil,
        ttbCompletelyS: Int? = nil,
        ttbSource: String? = nil,
        igdbCoverImageID: String? = nil,
        coverFile: String? = nil,
        igdbRating: Double? = nil,
        igdbRatingCount: Int? = nil,
        userEdited: String = "",
        hltbID: Int64? = nil,
        origin: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.igdbID = igdbID
        self.title = title
        self.sortTitle = sortTitle
        self.altTitles = altTitles
        self.summary = summary
        self.releaseDate = releaseDate
        self.year = year
        self.played = played
        self.status = status
        self.tierID = tierID
        self.rankKey = rankKey
        self.myPlaytimeS = myPlaytimeS
        self.psnPlaytimeS = psnPlaytimeS
        self.ttbHastilyS = ttbHastilyS
        self.ttbNormallyS = ttbNormallyS
        self.ttbCompletelyS = ttbCompletelyS
        self.ttbSource = ttbSource
        self.igdbCoverImageID = igdbCoverImageID
        self.coverFile = coverFile
        self.igdbRating = igdbRating
        self.igdbRatingCount = igdbRatingCount
        self.userEdited = userEdited
        self.hltbID = hltbID
        self.origin = origin
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

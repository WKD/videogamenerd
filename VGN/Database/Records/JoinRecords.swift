import Foundation
import GRDB

/// `game_platforms` — where a game exists / was played (PLAN §4).
struct GamePlatformRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var gameID: Int64
    var platformID: String
    var played: Bool

    static let databaseTableName = "game_platforms"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case gameID = "game_id"
        case platformID = "platform_id"
        case played
    }

    typealias Columns = CodingKeys
}

/// `genres` — a genre name (PLAN §4).
struct GenreRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var name: String

    static let databaseTableName = "genres"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case name
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `game_genres` — game ⇄ genre join (PLAN §4).
struct GameGenreRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var gameID: Int64
    var genreID: Int64

    static let databaseTableName = "game_genres"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case gameID = "game_id"
        case genreID = "genre_id"
    }

    typealias Columns = CodingKeys
}

/// `product_games` — product ⇄ game membership with position (PLAN §4).
struct ProductGameRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var productID: Int64
    var gameID: Int64
    var position: Int

    static let databaseTableName = "product_games"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case productID = "product_id"
        case gameID = "game_id"
        case position
    }

    typealias Columns = CodingKeys
}

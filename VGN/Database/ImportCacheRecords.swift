import Foundation
import GRDB

/// One validated importer response, cached for 30 days (PLAN §14.2). Written only
/// through ``ImportResponseCacheStore`` and only for responses that passed the
/// source's ``ImportResponseValidator`` — a bogus response is never stored here, so
/// a good entry can never be overwritten by a rejected one. `body` is the raw
/// (validated) response bytes; for a paged list there is one row per page plus a
/// manifest row (see ``ImportPageManifest``).
struct ImportCacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var source: String
    var key: String
    var endpoint: String
    var paramsJSON: String
    var fetchedAt: Date
    var expiresAt: Date
    var status: Int
    var body: Data
    var itemCount: Int
    var schemaVersion: Int

    static let databaseTableName = "import_cache"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case source
        case key
        case endpoint
        case paramsJSON = "params_json"
        case fetchedAt = "fetched_at"
        case expiresAt = "expires_at"
        case status
        case body
        case itemCount = "item_count"
        case schemaVersion = "schema_version"
    }

    typealias Columns = CodingKeys
}

/// One bogus importer response, kept for diagnostics (PLAN §14.2 — last 50 per
/// source, 4 KB excerpts, all identifiers already redacted). Never overwrites the
/// cache; pruned to 50/source by ``ImportResponseCacheStore``.
struct ImportCacheRejectRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var source: String
    var endpoint: String
    var paramsJSON: String
    var receivedAt: Date
    var status: Int?
    var reason: String
    var bodyExcerpt: String

    static let databaseTableName = "import_cache_rejects"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case source
        case endpoint
        case paramsJSON = "params_json"
        case receivedAt = "received_at"
        case status
        case reason
        case bodyExcerpt = "body_excerpt"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

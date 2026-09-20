import Foundation
import GRDB

/// `tiers` — GRDB record. Maps to the Foundation-only ``TierInfo``.
struct TierRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var letter: String
    var label: String
    var color: String
    var sort: Int

    static let databaseTableName = "tiers"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, letter, label, color, sort
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var info: TierInfo? {
        guard let id else { return nil }
        return TierInfo(id: id, letter: letter, label: label, colorHex: color, sort: sort)
    }
}

/// `comparisons` — the append-only duel log (PLAN §7).
struct ComparisonRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var winnerID: Int64
    var loserID: Int64
    var context: String              // 'placement' | 'refine'
    var createdAt: Date

    static let databaseTableName = "comparisons"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case winnerID = "winner_id"
        case loserID = "loser_id"
        case context
        case createdAt = "created_at"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `import_titles` — generic importer staging (PLAN §4/§6.3).
struct ImportTitleRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var source: String
    var externalID: String
    var name: String
    var platform: String?
    var signals: String?
    var playDurationS: Int?
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?
    var matchedGameID: Int64?
    var ignored: Bool
    /// The explicit "Send to the Vault" fate (PLAN §16, v13) — a vaulted row leaves the
    /// importable buckets and never re-proposes.
    var vaulted: Bool = false
    /// When the IGDB match was last attempted (v13, resume-after-cancel §5.1); NULL = never.
    var matchAttemptedAt: Date?
    /// The persisted per-title match outcome JSON (v13) — restored on a resumed sync.
    var matchJSON: String?

    static let databaseTableName = "import_titles"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case source
        case externalID = "external_id"
        case name
        case platform
        case signals
        case playDurationS = "play_duration_s"
        case firstPlayedAt = "first_played_at"
        case lastPlayedAt = "last_played_at"
        case matchedGameID = "matched_game_id"
        case ignored
        case vaulted
        case matchAttemptedAt = "match_attempted_at"
        case matchJSON = "match_json"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// `catalog_cache` — IGDB payload cache keyed by igdb id (PLAN §4/§9).
struct CatalogCacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var igdbID: Int64
    var json: String
    var fetchedAt: Date

    static let databaseTableName = "catalog_cache"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case igdbID = "igdb_id"
        case json
        case fetchedAt = "fetched_at"
    }

    typealias Columns = CodingKeys
}

/// The three background enrichment kinds (PLAN §9).
enum EnrichmentKind: String, Codable, Sendable, CaseIterable {
    case metadata
    case cover
    case timeToBeat
}

/// Enrichment job lifecycle state.
enum EnrichmentState: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case failed
    case done
}

/// `enrichment_jobs` — persisted background job queue (PLAN §9).
struct EnrichmentJobRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var kind: String                 // EnrichmentKind rawValue
    var gameID: Int64
    var state: String                // EnrichmentState rawValue
    var attempts: Int
    var nextAttemptAt: Date?
    var lastError: String?
    var createdAt: Date

    static let databaseTableName = "enrichment_jobs"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case kind
        case gameID = "game_id"
        case state
        case attempts
        case nextAttemptAt = "next_attempt_at"
        case lastError = "last_error"
        case createdAt = "created_at"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    init(
        id: Int64? = nil,
        kind: EnrichmentKind,
        gameID: Int64,
        state: EnrichmentState = .pending,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.gameID = gameID
        self.state = state.rawValue
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

/// `app_state` — generic key → JSON blob (holds resumable ranking sessions,
/// PLAN §7).
struct AppStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var key: String
    var json: String
    var updatedAt: Date

    static let databaseTableName = "app_state"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case key
        case json
        case updatedAt = "updated_at"
    }

    typealias Columns = CodingKeys
}

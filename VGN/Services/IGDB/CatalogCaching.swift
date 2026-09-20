import Foundation

/// One cached IGDB game payload: the raw JSON object for a game plus when it was
/// fetched (PLAN §4 `catalog_cache` table: `igdb_id · json · fetched_at`).
struct CatalogCacheEntry: Sendable, Equatable {
    let igdbID: Int64
    let json: Data
    let fetchedAt: Date
}

/// Read/write raw IGDB JSON keyed by igdb id. The DB-backed implementation
/// (`catalog_cache` table) arrives next wave from the Database lane; this wave ships
/// the protocol and an in-memory implementation so search can populate a cache and
/// tests can assert it.
protocol CatalogCaching: Sendable {
    /// A *fresh* cached entry (within the implementation's staleness window), or `nil`.
    func entry(forID id: Int64) async -> CatalogCacheEntry?
    /// Bulk fresh get for a set of ids (read-through by id). Default loops `entry(forID:)`.
    func freshEntries(forIDs ids: [Int64]) async -> [Int64: CatalogCacheEntry]
    func store(_ entry: CatalogCacheEntry) async
    /// Bulk store; default calls `store` per entry.
    func store(_ entries: [CatalogCacheEntry]) async
}

extension CatalogCaching {
    func store(_ entries: [CatalogCacheEntry]) async {
        for entry in entries { await store(entry) }
    }

    func freshEntries(forIDs ids: [Int64]) async -> [Int64: CatalogCacheEntry] {
        var out: [Int64: CatalogCacheEntry] = [:]
        for id in ids where out[id] == nil {
            if let entry = await entry(forID: id) { out[id] = entry }
        }
        return out
    }
}

/// A simple actor-backed in-memory cache. Every write is shape-merged onto whatever
/// is already stored for the id (see ``CatalogCacheMerge``) so a slimmer write never
/// drops richer fields — the same policy the DB-backed store uses.
actor InMemoryCatalogCache: CatalogCaching {
    private var storage: [Int64: CatalogCacheEntry] = [:]

    init() {}

    func entry(forID id: Int64) async -> CatalogCacheEntry? { storage[id] }

    func store(_ entry: CatalogCacheEntry) async {
        storage[entry.igdbID] = CatalogCacheMerge.merged(existing: storage[entry.igdbID], incoming: entry)
    }

    /// Test/inspection helper.
    var count: Int { storage.count }
}

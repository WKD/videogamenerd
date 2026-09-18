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
    func entry(forID id: Int64) async -> CatalogCacheEntry?
    func store(_ entry: CatalogCacheEntry) async
    /// Bulk store; default calls `store` per entry.
    func store(_ entries: [CatalogCacheEntry]) async
}

extension CatalogCaching {
    func store(_ entries: [CatalogCacheEntry]) async {
        for entry in entries { await store(entry) }
    }
}

/// A simple actor-backed in-memory cache.
actor InMemoryCatalogCache: CatalogCaching {
    private var storage: [Int64: CatalogCacheEntry] = [:]

    init() {}

    func entry(forID id: Int64) async -> CatalogCacheEntry? { storage[id] }

    func store(_ entry: CatalogCacheEntry) async { storage[entry.igdbID] = entry }

    /// Test/inspection helper.
    var count: Int { storage.count }
}

import Foundation
import GRDB

/// DB-backed ``CatalogCaching`` over the `catalog_cache` table (PLAN §4/§9): raw
/// IGDB game JSON keyed by igdb id with a `fetched_at` stamp. This is what makes
/// repeat autocomplete instant/offline and lets the enrichment metadata job skip
/// the network on a fresh hit.
///
/// Staleness policy: `entry(forID:)` returns only a *fresh* entry (within
/// `staleAfter`, 30 days by default) so a stale row transparently forces a refetch;
/// ``rawEntry(forID:)`` ignores staleness for callers that want whatever is cached
/// (e.g. offline autocomplete). `Sendable` — GRDB owns the synchronisation.
struct CatalogCacheStore: CatalogCaching, CatalogTitleSearching {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }
    var dbReader: any DatabaseReader { database.dbWriter }

    /// How long a cached payload is considered fresh (PLAN §4: 30 days).
    let staleAfter: TimeInterval
    let now: @Sendable () -> Date

    /// The in-process title index (shared reference) that powers instant/offline
    /// Quick Add title search (PLAN §6.1). `nil` disables title search (tests that
    /// don't need it); writes still keep a present index warm.
    let titleIndex: CatalogTitleIndex?

    init(
        _ database: AppDatabase,
        staleAfter: TimeInterval = 30 * 24 * 60 * 60,
        now: @Sendable @escaping () -> Date = { Date() },
        titleIndex: CatalogTitleIndex? = nil
    ) {
        self.database = database
        self.staleAfter = staleAfter
        self.now = now
        self.titleIndex = titleIndex
    }

    // MARK: - CatalogCaching

    /// A *fresh* cached entry, or `nil` when absent or stale.
    func entry(forID id: Int64) async -> CatalogCacheEntry? {
        guard let entry = await rawEntry(forID: id) else { return nil }
        return isFresh(entry) ? entry : nil
    }

    func store(_ entry: CatalogCacheEntry) async {
        try? await dbWriter.write { db in try Self.upsert(entry, db) }
        await titleIndex?.upsert([entry])
    }

    func store(_ entries: [CatalogCacheEntry]) async {
        guard !entries.isEmpty else { return }
        try? await dbWriter.write { db in
            for entry in entries { try Self.upsert(entry, db) }
        }
        await titleIndex?.upsert(entries)
    }

    // MARK: - CatalogTitleSearching (instant/offline Quick Add title search)

    func searchTitles(_ text: String, limit: Int) async -> [IGDBSearchResult] {
        guard let titleIndex else { return [] }
        await titleIndex.loadIfNeeded(reader: dbReader)
        return await titleIndex.search(text, limit: limit)
    }

    // MARK: - Extras (enrichment / search)

    /// The cached entry regardless of staleness (offline autocomplete path).
    func rawEntry(forID id: Int64) async -> CatalogCacheEntry? {
        try? await dbReader.read { db in
            try CatalogCacheRecord.fetchOne(db, key: id).map(Self.entry(from:))
        } ?? nil
    }

    /// Bulk get for a set of ids (search results / a metadata batch). By default
    /// returns only fresh entries; pass `includingStale: true` for offline reads.
    func entries(forIDs ids: [Int64], includingStale: Bool = false) async -> [Int64: CatalogCacheEntry] {
        guard !ids.isEmpty else { return [:] }
        let fetched: [CatalogCacheEntry] = (try? await dbReader.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try CatalogCacheRecord
                .fetchAll(db, sql: "SELECT * FROM catalog_cache WHERE igdb_id IN (\(placeholders))",
                          arguments: StatementArguments(ids))
                .map(Self.entry(from:))
        }) ?? []
        var out: [Int64: CatalogCacheEntry] = [:]
        for entry in fetched where includingStale || isFresh(entry) {
            out[entry.igdbID] = entry
        }
        return out
    }

    func isFresh(_ entry: CatalogCacheEntry) -> Bool {
        now().timeIntervalSince(entry.fetchedAt) < staleAfter
    }

    /// Delete stale rows (housekeeping). `olderThan` defaults to `staleAfter`.
    @discardableResult
    func prune(olderThan interval: TimeInterval? = nil) async throws -> Int {
        let cutoff = now().addingTimeInterval(-(interval ?? staleAfter))
        return try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM catalog_cache WHERE fetched_at < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    func count() async throws -> Int {
        try await dbReader.read { db in try CatalogCacheRecord.fetchCount(db) }
    }

    // MARK: - Record <-> entry

    private static func upsert(_ entry: CatalogCacheEntry, _ db: Database) throws {
        try CatalogCacheRecord(
            igdbID: entry.igdbID,
            json: String(decoding: entry.json, as: UTF8.self),
            fetchedAt: entry.fetchedAt
        ).save(db)
    }

    private static func entry(from record: CatalogCacheRecord) -> CatalogCacheEntry {
        CatalogCacheEntry(igdbID: record.igdbID, json: Data(record.json.utf8), fetchedAt: record.fetchedAt)
    }
}

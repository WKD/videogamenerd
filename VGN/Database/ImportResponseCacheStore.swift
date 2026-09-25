import Foundation
import GRDB

/// A page manifest for a paged list (PLAN §14.2): the total item/page count and the
/// per-page cache keys, so a sync interrupted mid-list resumes without re-requesting
/// the good pages. Stored as its own `import_cache` row (see
/// ``ImportResponseCacheStore/storeManifest(source:key:_:fetchedAt:expiresAt:)``).
struct ImportPageManifest: Codable, Sendable, Hashable {
    var totalItems: Int
    var totalPages: Int
    /// Cache keys for the pages already fetched and validated, in page order.
    var pageKeys: [String]

    init(totalItems: Int, totalPages: Int, pageKeys: [String] = []) {
        self.totalItems = totalItems
        self.totalPages = totalPages
        self.pageKeys = pageKeys
    }
}

/// The one 30-day importer response cache for every source (PLAN §14.2). Cache-first
/// reads (`freshEntry`), stores that only ever hold **validated** responses (so a good
/// entry is never overwritten by a rejected one), per-page rows plus a manifest for
/// resumable paged fetches, a redaction-and-prune reject log, `wipe(source:)` for Sign
/// out, and `ages(source:)` for the Settings pane.
///
/// `Sendable`; a thin value over ``AppDatabase``. Time is injected by the caller: an
/// entry's `expiresAt` is computed up-front (from `ImportPolicy.cacheTTL`) and freshness
/// is a plain `expiresAt > now` comparison, so nothing here reads the wall clock.
struct ImportResponseCacheStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    // MARK: - Reads

    /// The cached entry for `(source, key)` **iff** it is still fresh at `now`
    /// (PLAN §14.2 — inside the window a sync makes zero requests). Stale/missing → nil.
    func freshEntry(source: String, key: String, now: Date) async throws -> ImportCacheRecord? {
        try await dbWriter.read { db in
            guard let record = try Self.fetch(source: source, key: key, db) else { return nil }
            return record.expiresAt > now ? record : nil
        }
    }

    /// The cached entry for `(source, key)` regardless of freshness — used to read a
    /// manifest, resume a partial paged fetch, and hand the validator the previous
    /// valid item count for the suspicious-emptiness check.
    func entry(source: String, key: String) async throws -> ImportCacheRecord? {
        try await dbWriter.read { db in try Self.fetch(source: source, key: key, db) }
    }

    /// The item count of the last validated cache for `(source, key)`, or nil if none
    /// — the "≥ 1 item last time" baseline for `suspiciouslyEmpty` (PLAN §14.2).
    func lastItemCount(source: String, key: String) async throws -> Int? {
        try await entry(source: source, key: key)?.itemCount
    }

    /// The cache age of every data set for a source, newest first (PLAN §14.2 Settings).
    func ages(source: String) async throws -> [ImportCacheAge] {
        try await dbWriter.read { db in
            try ImportCacheRecord
                .filter(ImportCacheRecord.Columns.source == source)
                .order(ImportCacheRecord.Columns.fetchedAt.desc)
                .fetchAll(db)
                .map {
                    ImportCacheAge(key: $0.key, endpoint: $0.endpoint,
                                   fetchedAt: $0.fetchedAt, expiresAt: $0.expiresAt,
                                   itemCount: $0.itemCount)
                }
        }
    }

    // MARK: - Writes

    /// Store (upsert) a **validated** response. This method is only ever handed a
    /// response that passed the source validator, so it can never overwrite a good
    /// entry with a rejected one — rejects go to ``recordReject(_:keepLast:redact:)``.
    func store(_ entry: ImportCacheRecord) async throws {
        try await dbWriter.write { db in try entry.save(db) }
    }

    /// Store a page manifest as its own cache row so a partial paged fetch can resume.
    func storeManifest(source: String, key: String, _ manifest: ImportPageManifest,
                       fetchedAt: Date, expiresAt: Date) async throws {
        let body = try JSONEncoder().encode(manifest)
        let record = ImportCacheRecord(
            source: source, key: key, endpoint: "manifest", paramsJSON: "{}",
            fetchedAt: fetchedAt, expiresAt: expiresAt, status: 200,
            body: body, itemCount: manifest.totalItems, schemaVersion: 1)
        try await store(record)
    }

    /// Read a page manifest previously stored with ``storeManifest``.
    func manifest(source: String, key: String) async throws -> ImportPageManifest? {
        guard let record = try await entry(source: source, key: key) else { return nil }
        return try? JSONDecoder().decode(ImportPageManifest.self, from: record.body)
    }

    /// Append a bogus response to the reject log and prune to the newest `keepLast`
    /// per source (PLAN §14.2). Endpoint / params / excerpt are passed through
    /// `redact` (default: the excerpt is assumed already redacted) so no identifier
    /// is ever persisted. The excerpt is capped at 4 KB.
    func recordReject(_ reject: ImportReject, keepLast: Int = 50,
                      redact: (@Sendable (String) -> String)? = nil) async throws {
        let scrub = redact ?? { $0 }
        let endpoint = scrub(reject.endpoint)
        let excerpt = String(scrub(reject.redactedExcerpt).prefix(4096))
        try await dbWriter.write { db in
            var record = ImportCacheRejectRecord(
                id: nil,
                source: reject.source,
                endpoint: endpoint,
                paramsJSON: "{}",
                receivedAt: reject.receivedAt,
                status: reject.status,
                reason: reject.reason.code,
                bodyExcerpt: excerpt
            )
            try record.insert(db)
            try db.execute(sql: """
                DELETE FROM import_cache_rejects
                WHERE source = ? AND id NOT IN (
                    SELECT id FROM import_cache_rejects
                    WHERE source = ? ORDER BY received_at DESC, id DESC LIMIT ?
                )
                """, arguments: [reject.source, reject.source, keepLast])
        }
    }

    /// Delete every cache and reject row for a source — Sign out & wipe (PLAN §14.1).
    func wipe(source: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM import_cache WHERE source = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM import_cache_rejects WHERE source = ?", arguments: [source])
        }
    }

    /// Delete this source's rejected-response log — the owner's explicit, confirmed
    /// "Clear rejected-response log (N)" action (wave 21 E). Existing rows are never
    /// rewritten by a background repair (PLAN §4 inv. 5); they only go away through this.
    /// One transaction; the cache itself is untouched. Returns the number of rows removed.
    @discardableResult
    func clearRejects(source: String) async throws -> Int {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM import_cache_rejects WHERE source = ?", arguments: [source])
            return db.changesCount
        }
    }

    /// Count of reject rows for a source (diagnostics / tests).
    func rejectCount(source: String) async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_cache_rejects WHERE source = ?",
                             arguments: [source]) ?? 0
        }
    }

    // MARK: - Internals

    private static func fetch(source: String, key: String, _ db: Database) throws -> ImportCacheRecord? {
        try ImportCacheRecord
            .filter(ImportCacheRecord.Columns.source == source && ImportCacheRecord.Columns.key == key)
            .fetchOne(db)
    }
}

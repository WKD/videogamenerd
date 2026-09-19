import Foundation
import Testing
import GRDB
@testable import VGN

/// ``ImportResponseCacheStore``: 30-day freshness, no good-entry overwrite by a reject,
/// per-page manifest resume, reject pruning + redaction, wipe, ages. Injected `Date`.
@Suite struct ImportResponseCacheStoreTests {

    private func makeStore() async throws -> ImportResponseCacheStore {
        ImportResponseCacheStore(try AppDatabase.inMemory())
    }

    private func entry(key: String, fetchedAt: Date, ttl: TimeInterval = ImportPolicy.cacheTTL,
                       itemCount: Int = 1, body: String = "{}") -> ImportCacheRecord {
        ImportCacheRecord(source: ImportSourceID.gog, key: key, endpoint: "e", paramsJSON: "{}",
                          fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ttl),
                          status: 200, body: Data(body.utf8), itemCount: itemCount, schemaVersion: 1)
    }

    @Test func freshWithinTTLStaleAfter() async throws {
        let store = try await makeStore()
        let now = importFixedNow
        try await store.store(entry(key: "k", fetchedAt: now))
        // Fresh 29 days later, stale 31 days later.
        #expect(try await store.freshEntry(source: ImportSourceID.gog, key: "k",
                                           now: now.addingTimeInterval(29 * 86400)) != nil)
        #expect(try await store.freshEntry(source: ImportSourceID.gog, key: "k",
                                           now: now.addingTimeInterval(31 * 86400)) == nil)
    }

    @Test func rejectNeverOverwritesGoodEntry() async throws {
        let store = try await makeStore()
        let now = importFixedNow
        try await store.store(entry(key: "k", fetchedAt: now, itemCount: 7))
        // A reject is recorded separately; the good cache entry is untouched.
        try await store.recordReject(ImportReject(
            source: ImportSourceID.gog, endpoint: "e", reason: .loginPageOrHTML,
            redactedExcerpt: "x", receivedAt: now))
        let still = try await store.freshEntry(source: ImportSourceID.gog, key: "k", now: now)
        #expect(still?.itemCount == 7)
        #expect(try await store.rejectCount(source: ImportSourceID.gog) == 1)
    }

    @Test func manifestResumeReadsBackPageKeys() async throws {
        let store = try await makeStore()
        let now = importFixedNow
        // Page 1 and 3 cached, page 2 missing → resume should skip 1 & 3.
        try await store.store(entry(key: "page=1", fetchedAt: now))
        try await store.store(entry(key: "page=3", fetchedAt: now))
        try await store.storeManifest(source: ImportSourceID.gog, key: "manifest",
                                      ImportPageManifest(totalItems: 10, totalPages: 3,
                                                         pageKeys: ["page=1", "page=2", "page=3"]),
                                      fetchedAt: now, expiresAt: now.addingTimeInterval(ImportPolicy.cacheTTL))
        let manifest = try await store.manifest(source: ImportSourceID.gog, key: "manifest")
        #expect(manifest?.totalPages == 3)
        #expect(try await store.freshEntry(source: ImportSourceID.gog, key: "page=1", now: now) != nil)
        #expect(try await store.freshEntry(source: ImportSourceID.gog, key: "page=2", now: now) == nil)
        #expect(try await store.freshEntry(source: ImportSourceID.gog, key: "page=3", now: now) != nil)
    }

    @Test func rejectsPrunedToFiftyPerSource() async throws {
        let store = try await makeStore()
        for i in 0..<60 {
            try await store.recordReject(ImportReject(
                source: ImportSourceID.gog, endpoint: "e\(i)", reason: .unknown,
                redactedExcerpt: "x", receivedAt: importFixedNow.addingTimeInterval(Double(i))))
        }
        #expect(try await store.rejectCount(source: ImportSourceID.gog) == 50)
    }

    @Test func recordRejectAppliesRedaction() async throws {
        let store = try await makeStore()
        let redactor = ImportRedactor(literals: ["secret-token-value"])
        try await store.recordReject(ImportReject(
            source: ImportSourceID.gog, endpoint: "e", reason: .unknown,
            redactedExcerpt: "body has secret-token-value inside", receivedAt: importFixedNow),
            redact: redactor.closure)
        let excerpt = try await store.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT body_excerpt FROM import_cache_rejects LIMIT 1")
        }
        #expect(excerpt?.contains("secret-token-value") == false)
        #expect(excerpt?.contains("‹redacted›") == true)
    }

    @Test func wipeAndAges() async throws {
        let store = try await makeStore()
        try await store.store(entry(key: "a", fetchedAt: importFixedNow, itemCount: 2))
        try await store.store(entry(key: "b", fetchedAt: importFixedNow, itemCount: 5))
        let ages = try await store.ages(source: ImportSourceID.gog)
        #expect(ages.count == 2)
        #expect(ages.allSatisfy { $0.isFresh(now: importFixedNow) })
        try await store.wipe(source: ImportSourceID.gog)
        #expect(try await store.ages(source: ImportSourceID.gog).isEmpty)
    }
}

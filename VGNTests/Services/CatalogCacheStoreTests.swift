import Foundation
import Testing
@testable import VGN

/// Tests for the DB-backed catalogue cache (PLAN §4/§9): round-trip, staleness,
/// bulk get, prune. Uses a controllable wall-clock so "30 days later" is exact.
struct CatalogCacheStoreTests {

    private func makeStore(staleAfter: TimeInterval = 30 * 24 * 60 * 60) async throws
        -> (CatalogCacheStore, MutableDate) {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        return (CatalogCacheStore(db, staleAfter: staleAfter, now: { date.now }), date)
    }

    private func entry(_ id: Int64, _ date: Date) -> CatalogCacheEntry {
        CatalogCacheEntry(igdbID: id, json: Data(#"{"id":\#(id),"name":"x"}"#.utf8), fetchedAt: date)
    }

    @Test("Round-trips a raw JSON payload and upserts on the same id")
    func roundTrip() async throws {
        let (store, date) = try await makeStore()
        await store.store(entry(7334, date.now))
        let got = try #require(await store.entry(forID: 7334))
        #expect(got.igdbID == 7334)
        #expect(String(decoding: got.json, as: UTF8.self).contains("\"id\":7334"))

        // Upsert (same id, newer JSON) replaces, not duplicates.
        await store.store(CatalogCacheEntry(igdbID: 7334, json: Data(#"{"id":7334,"name":"y"}"#.utf8), fetchedAt: date.now))
        #expect(try await store.count() == 1)
        #expect(String(decoding: (await store.entry(forID: 7334))!.json, as: UTF8.self).contains("\"name\":\"y\""))
    }

    @Test("A stale entry is not returned by entry(forID:), but rawEntry still sees it")
    func staleness() async throws {
        let (store, date) = try await makeStore()
        await store.store(entry(1, date.now))
        #expect(await store.entry(forID: 1) != nil)             // fresh
        date.advance(by: 31 * 24 * 60 * 60)                     // > 30 days
        #expect(await store.entry(forID: 1) == nil)             // stale → forces refetch
        #expect(await store.rawEntry(forID: 1) != nil)          // still cached for offline reads
    }

    @Test("Bulk get returns only fresh entries by default")
    func bulkGet() async throws {
        let (store, date) = try await makeStore()
        await store.store(entry(1, date.now))
        await store.store(entry(2, date.now.addingTimeInterval(-40 * 24 * 60 * 60)))   // stale
        await store.store(entry(3, date.now))

        let fresh = await store.entries(forIDs: [1, 2, 3])
        #expect(Set(fresh.keys) == [1, 3])
        let all = await store.entries(forIDs: [1, 2, 3], includingStale: true)
        #expect(Set(all.keys) == [1, 2, 3])
        #expect(await store.entries(forIDs: []).isEmpty)
    }

    @Test("Prune deletes stale rows")
    func prune() async throws {
        let (store, date) = try await makeStore()
        await store.store(entry(1, date.now))
        await store.store(entry(2, date.now.addingTimeInterval(-40 * 24 * 60 * 60)))
        let deleted = try await store.prune()
        #expect(deleted == 1)
        #expect(try await store.count() == 1)
        #expect(await store.rawEntry(forID: 2) == nil)
    }
}

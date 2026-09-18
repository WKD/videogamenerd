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

    // MARK: - Instant/offline title search (PLAN §6.1)

    /// A store whose in-process title index is enabled (the live app's wiring).
    private func makeSearchableStore() async throws -> CatalogCacheStore {
        let db = try await TestDB.makeSeeded()
        return CatalogCacheStore(db, titleIndex: CatalogTitleIndex(catalog: TestCatalog.catalog))
    }

    private func gameEntry(
        _ id: Int64, name: String, alt: [String] = [], platforms: [Int] = [48], now: Date = Date()
    ) -> CatalogCacheEntry {
        let obj: [String: Any] = [
            "id": id, "name": name, "first_release_date": 1_420_070_400,
            "cover": ["image_id": "img\(id)"],
            "platforms": platforms.map { ["id": $0] },
            "alternative_names": alt.map { ["name": $0] },
        ]
        return CatalogCacheEntry(igdbID: id, json: try! JSONSerialization.data(withJSONObject: obj), fetchedAt: now)
    }

    @Test("Title search is prefix, multi-token and accent-insensitive; searches alt names")
    func titleSearch() async throws {
        let store = try await makeSearchableStore()
        await store.store([
            gameEntry(7334, name: "Bloodborne", alt: ["Project Beast"]),
            gameEntry(42, name: "Blood Omen: Legacy of Kain"),
            gameEntry(100, name: "Broken Sword", alt: ["Les Chevaliers de Baphomet"]),
            gameEntry(200, name: "Pokémon Red"),
            gameEntry(300, name: "Metal Gear Solid 3: Snake Eater"),
        ])

        // Mid-token prefix on the title (uniquely Bloodborne).
        #expect(await store.searchTitles("bloodb", limit: 12).map(\.id) == [7334])
        // A shared prefix returns both, title-start matches only.
        #expect(Set(await store.searchTitles("blood", limit: 12).map(\.id)) == [7334, 42])
        // Multi-token, order-independent, over an alternative name (French box title).
        #expect(await store.searchTitles("chev bapho", limit: 12).map(\.id) == [100])
        // Accent-insensitive.
        #expect(await store.searchTitles("pokemon", limit: 12).map(\.id) == [200])
        // Multi-token on the title itself.
        #expect(await store.searchTitles("metal snake", limit: 12).map(\.id) == [300])
        // No match.
        #expect(await store.searchTitles("zelda", limit: 12).isEmpty)
        // The mapped result carries slugs from the shared catalogue.
        #expect(await store.searchTitles("bloodb", limit: 12).first?.platformSlugs == ["ps4"])
    }

    @Test("Title search reads an existing cache (loaded from the DB, no index warm-up)")
    func titleSearchLoadsFromDB() async throws {
        // Populate the table through a store WITHOUT an index (so nothing is warmed)…
        let db = try await TestDB.makeSeeded()
        let writer = CatalogCacheStore(db)
        await writer.store([gameEntry(7334, name: "Bloodborne")])
        // …then a fresh store with an index must still find it (lazy DB load).
        let reader = CatalogCacheStore(db, titleIndex: CatalogTitleIndex(catalog: TestCatalog.catalog))
        #expect(await reader.searchTitles("blood", limit: 12).map(\.id) == [7334])
    }

    @Test("Title search is disabled (empty) when no index is attached")
    func titleSearchDisabledWithoutIndex() async throws {
        let (store, date) = try await makeStore()
        await store.store(gameEntry(7334, name: "Bloodborne", now: date.now))
        #expect(await store.searchTitles("blood", limit: 12).isEmpty)
    }
}

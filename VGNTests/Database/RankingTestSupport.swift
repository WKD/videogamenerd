import Foundation
import GRDB
@testable import VGN

/// Shared helpers for the RankingStore test suite.
enum RankTestDB {
    /// A seeded in-memory DB with a `LibraryStore` and a `RankingStore` over it.
    static func make() async throws -> (db: AppDatabase, lib: LibraryStore, rank: RankingStore) {
        let db = try await TestDB.makeSeeded()
        return (db, LibraryStore(db), RankingStore(db))
    }

    /// Add a played, tiered, **unplaced** game (tier set, no fine-rank key).
    /// `owned` makes it a physical copy on `platform` (needed when a test later
    /// un-plays it without deleting).
    @discardableResult
    static func addGame(_ lib: LibraryStore, title: String, tier: Int64,
                        owned: Bool = false, platform: String = "pc") async throws -> Int64 {
        try await lib.addGame(GameDraft(
            title: title,
            platformIDs: owned ? [platform] : [],
            owned: owned,
            tierID: tier
        )).gameID
    }

    /// Load the SQL ranking snapshot.
    static func snapshot(_ rank: RankingStore) async throws -> RankSnapshot {
        try await rank.dbReader.read { db in try RankingStore.loadSnapshot(db) }
    }

    /// Directly assign a fine-rank key (bypassing duels) to build a known order.
    static func setKey(_ rank: RankingStore, _ gameID: Int64, _ key: RankKey) async throws {
        try await rank.dbWriter.write { db in
            try RankingStore.applyMutations([.setKey(id: gameID, key: key)], db)
        }
    }

    /// Number of comparison rows logged.
    static func comparisonCount(_ rank: RankingStore) async throws -> Int {
        try await rank.dbReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM comparisons") ?? 0
        }
    }

    /// The placed game ids of a tier, in fine-rank order.
    static func placedOrder(_ snap: RankSnapshot, tier: Int64) -> [Int64] {
        snap.slice(for: tier)?.placed.map(\.id) ?? []
    }

    static func unplaced(_ snap: RankSnapshot, tier: Int64) -> [Int64] {
        snap.slice(for: tier)?.unplaced ?? []
    }
}

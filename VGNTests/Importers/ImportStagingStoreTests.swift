import Foundation
import Testing
import GRDB
@testable import VGN

/// ``ImportStagingStore``: decision-preserving upsert, buckets, `setDecision`, and the
/// one-transaction idempotent `commit` (PLAN §14.3).
@Suite struct ImportStagingStoreTests {

    private func make() async throws -> (AppDatabase, ImportStagingStore) {
        let db = try await ImportTestDB.makeSeeded()
        return (db, ImportStagingStore(db))
    }

    private func rows() -> [ImportStagingRow] {
        [
            ImportStagingRow(source: ImportSourceID.gog, externalID: "100001", name: "Synthetic Quest",
                             platform: "mac", releaseYear: 2018),
            ImportStagingRow(source: ImportSourceID.gog, externalID: "100002", name: "Synthetic Racer",
                             platform: "pc", releaseYear: 2011),
            ImportStagingRow(source: ImportSourceID.gog, externalID: "100003", name: "Synthetic Soundtrack",
                             platform: "pc", ignoreReason: .soundtrackOrGoodies),
        ]
    }

    @Test func upsertBucketsAndDefaultIgnore() async throws {
        let (_, staging) = try await make()
        try await staging.upsert(rows())
        let buckets = try await staging.buckets(source: ImportSourceID.gog)
        #expect(buckets[.new]?.count == 2)          // 100001, 100002
        #expect(buckets[.ignored]?.count == 1)      // 100003 (noise, ignored by default)
        #expect(buckets[.alreadyMatched] == nil)
    }

    @Test func reSyncPreservesDecisions() async throws {
        let (db, staging) = try await make()
        try await staging.upsert(rows())
        // A real game to match to (import_titles.matched_game_id has an FK to games).
        let gameID = try await LibraryStore(db).addGame(GameDraft(
            title: "Synthetic Quest", igdbID: 5001, platformIDs: ["mac"], owned: false, played: true)).gameID
        try await staging.setDecision(source: ImportSourceID.gog, externalID: "100001", .match(gameID: gameID))
        try await staging.setDecision(source: ImportSourceID.gog, externalID: "100002", .ignore)

        // Re-sync the same rows (fresh metadata, defaults would re-ignore nothing).
        try await staging.upsert(rows())
        let titles = try await staging.titles(source: ImportSourceID.gog)
        let byID = Dictionary(uniqueKeysWithValues: titles.map { ($0.externalID, $0) })
        #expect(byID["100001"]?.matchedGameID == gameID)  // match preserved
        #expect(byID["100001"]?.bucket == .alreadyMatched)
        #expect(byID["100002"]?.ignored == true)          // user ignore preserved
        #expect(byID["100003"]?.ignored == true)          // default-noise still ignored
    }

    @Test func commitCreatesNewGameOwnedNotPlayedAndIsIdempotent() async throws {
        let (db, staging) = try await make()
        let item = ImportCommitItem(
            source: ImportSourceID.gog, externalID: "100001", platformID: "mac", format: .digital,
            target: .newGame(ImportNewGameSpec(title: "Synthetic Quest", igdbID: 5001, releaseYear: 2018)))

        let first = try await staging.commit([item])
        #expect(first.gamesCreated == 1)
        #expect(first.productsAdded == 1)
        #expect(first.skippedExisting == 0)

        let state = try await db.dbWriter.read { db -> (games: Int, products: Int, played: Int, tier: Int64?) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='gog' AND external_id='100001'") ?? -1,
             try Int.fetchOne(db, sql: "SELECT played FROM games LIMIT 1") ?? -1,
             try Int64.fetchOne(db, sql: "SELECT tier_id FROM games LIMIT 1"))
        }
        #expect(state.games == 1)
        #expect(state.products == 1)
        #expect(state.played == 0)          // owned, NOT played (Backlog)
        #expect(state.tier == nil)          // no tier touched

        // Commit again → nothing new (idempotent on (source, external_id)).
        let second = try await staging.commit([item])
        #expect(second.skippedExisting == 1)
        #expect(second.gamesCreated == 0)
        let after = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1
        }
        #expect(after == 1)
    }

    @Test func commitAttachesProductToExistingGame() async throws {
        let (db, staging) = try await make()
        let store = LibraryStore(db)
        // An existing played library game (no product yet).
        let gameID = try await store.addGame(GameDraft(
            title: "Owned Elsewhere", igdbID: 6001, platformIDs: ["pc"], owned: false, played: true)).gameID

        let item = ImportCommitItem(
            source: ImportSourceID.gog, externalID: "100002", platformID: "pc",
            target: .existingGame(gameID: gameID))
        let result = try await staging.commit([item])
        #expect(result.productsAdded == 1)
        #expect(result.affectedGameIDs == [gameID])

        let owned = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM products p JOIN product_games pg ON pg.product_id = p.id
                WHERE pg.game_id = ? AND p.source = 'gog'
                """, arguments: [gameID]) ?? -1
        }
        #expect(owned == 1)
    }

    @Test func commitCompilationCreatesPackWithMembers() async throws {
        let (db, staging) = try await make()
        let item = ImportCommitItem(
            source: ImportSourceID.gog, externalID: "100008", platformID: "pc",
            target: .compilation(title: "Synthetic Trilogy", members: [
                CompilationMemberDraft(title: "Synthetic Part 1", igdbID: 7001, position: 0),
                CompilationMemberDraft(title: "Synthetic Part 2", igdbID: 7002, position: 1),
            ]))
        let result = try await staging.commit([item])
        #expect(result.productsAdded == 1)
        #expect(result.gamesCreated == 2)

        let shape = try await db.dbWriter.read { db -> (kind: String?, members: Int, playedSum: Int) in
            (try String.fetchOne(db, sql: "SELECT kind FROM products WHERE source='gog' AND external_id='100008'"),
             try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM product_games pg JOIN products p ON p.id = pg.product_id
                WHERE p.external_id='100008'
                """) ?? -1,
             try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(played),0) FROM games") ?? -1)
        }
        #expect(shape.kind == "compilation")
        #expect(shape.members == 2)
        #expect(shape.playedSum == 0)      // members land owned, not played
    }
}

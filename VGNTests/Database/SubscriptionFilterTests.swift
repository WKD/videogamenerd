import Foundation
import Testing
import GRDB
@testable import VGN

/// PLAN §13.3 "PS Plus copies": the model + SQL side (the menu wiring is the UI lane's).
///  - ``ProductSubscription`` tolerates unknown membership strings, folds `PS_PLUS`.
///  - ``GameSummary/ownedOnlyViaSubscription`` is true only when *every* owned copy is a
///    subscription copy (a disc copy clears it).
///  - ``LibraryFilter/includeSubscriptionOnly`` selects exactly those games.
@Suite struct SubscriptionFilterTests {

    // MARK: - Tolerant model

    @Test func subscriptionParsingIsTolerant() {
        #expect(ProductSubscription(storage: nil) == nil)
        #expect(ProductSubscription(storage: "") == nil)
        #expect(ProductSubscription(storage: "  ") == nil)
        #expect(ProductSubscription(storage: "ps_plus") == .psPlus)
        #expect(ProductSubscription(storage: "PS_PLUS") == .psPlus)          // folded
        #expect(ProductSubscription(storage: "Ps_Plus")?.isPSPlus == true)
        // An unknown membership string is kept raw and shown, never guessed.
        let unknown = ProductSubscription(storage: "PS_PLUS_DELUXE_2027")
        #expect(unknown?.rawValue == "PS_PLUS_DELUXE_2027")
        #expect(unknown?.isPSPlus == false)
        #expect(unknown?.label == "PS_PLUS_DELUXE_2027")
        #expect(ProductSubscription.psPlus.label == "PS Plus")
    }

    // MARK: - Query + filter

    /// Seed four games: (1) owned only via PS Plus, (2) PS Plus + disc, (3) really owned
    /// digital, (4) played-only (no copy).
    private func seed(_ db: AppDatabase) async throws {
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, sort_title, played) VALUES (1,'Plus Only','plus only',0),(2,'Plus And Disc','plus and disc',0),(3,'Bought','bought',0),(4,'Borrowed','borrowed',1)")
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, subscription) VALUES
                    (10,'ps5','single','digital','psn','ps_plus'),
                    (11,'ps5','single','digital','psn','ps_plus'),
                    (12,'ps5','single','physical','photo',NULL),
                    (13,'ps5','single','digital','psn',NULL)
                """)
            try db.execute(sql: """
                INSERT INTO product_games (product_id, game_id, position) VALUES (10,1,0),(11,2,0),(12,2,0),(13,3,0)
                """)
        }
    }

    private func summaries(_ db: AppDatabase, _ filter: LibraryFilter) async throws -> [GameSummary] {
        let (sql, args) = LibraryQuery.gamesSQL(filter)
        return try await db.dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: args).map(LibraryQuery.gameSummary(from:))
        }
    }

    @Test func ownedOnlyViaSubscriptionDerivation() async throws {
        let db = try await TestDB.makeSeeded()
        try await seed(db)
        let all = try await summaries(db, LibraryFilter())
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        #expect(byID[1]?.ownedOnlyViaSubscription == true)   // only a PS Plus copy
        #expect(byID[2]?.ownedOnlyViaSubscription == false)  // also on disc → not at risk
        #expect(byID[3]?.ownedOnlyViaSubscription == false)  // really owned
        #expect(byID[4]?.ownedOnlyViaSubscription == false)  // played-only, not owned
    }

    @Test func includeSubscriptionOnlyFilterSelectsOnlyAtRiskGames() async throws {
        let db = try await TestDB.makeSeeded()
        try await seed(db)
        let filter = LibraryFilter(includeSubscriptionOnly: true)
        #expect(filter.hasActiveFacets)
        let ids = try await summaries(db, filter).map(\.id).sorted()
        #expect(ids == [1])   // only the game owned solely through PS Plus
    }

    @Test func subscriptionOnlyWithNotPlayedIsTheFinishBeforeUnsubscribingList() async throws {
        let db = try await TestDB.makeSeeded()
        try await seed(db)
        // game 1 is not played; make a second plus-only game that IS played to prove the AND.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, sort_title, played) VALUES (5,'Plus Played','plus played',1)")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source, subscription) VALUES (14,'ps5','single','digital','psn','ps_plus')")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (14,5,0)")
        }
        let filter = LibraryFilter(includeNotPlayed: true, includeSubscriptionOnly: true)
        let ids = try await summaries(db, filter).map(\.id).sorted()
        #expect(ids == [1])   // plus-only AND not played
    }
}

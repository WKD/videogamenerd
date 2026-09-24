import Foundation
import Testing
import GRDB
@testable import VGN

/// The "PS Plus Only" sidebar smart list (PLAN §8/§13.3): games owned only through a PS Plus
/// claim — the same single SQL predicate as Format ▸ PS Plus. Scope SQL ≡ in-memory evaluator,
/// count ≡ list, hidden at 0, stable id, header copy.
@Suite struct PSPlusOnlyListTests {

    /// (1) owned only via PS Plus, (2) PS Plus + disc, (3) really owned digital, (4) played-only,
    /// (5) a second PS-Plus-only game.
    private func seed(_ db: AppDatabase) async throws {
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, sort_title, played) VALUES
                    (1,'Plus Only','plus only',0),(2,'Plus And Disc','plus and disc',0),
                    (3,'Bought','bought',0),(4,'Borrowed','borrowed',1),(5,'Plus Two','plus two',1)
                """)
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, subscription) VALUES
                    (10,'ps5','single','digital','psn','ps_plus'),
                    (11,'ps5','single','digital','psn','ps_plus'),
                    (12,'ps5','single','physical','photo',NULL),
                    (13,'ps5','single','digital','psn',NULL),
                    (14,'ps4','single','digital','psn','ps_plus')
                """)
            try db.execute(sql: """
                INSERT INTO product_games (product_id, game_id, position) VALUES (10,1,0),(11,2,0),(12,2,0),(13,3,0),(14,5,0)
                """)
        }
    }

    @Test func scopeCountAndEvaluatorAgree() async throws {
        let db = try await TestDB.makeSeeded()
        try await seed(db)
        let store = LibraryStore(db)
        let scoped = Set(try await store.gamesOnce(filter: LibraryFilter(scope: .psPlusOnly)).map(\.id))
        #expect(scoped == [1, 5])
        let count = try await db.dbWriter.read { db in try LibraryQuery.fetchPSPlusOnlyCount(db) }
        #expect(count == scoped.count)
        // SQL ≡ in-memory evaluator, alone and composed with other facets.
        let all = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        for f in [LibraryFilter(scope: .psPlusOnly),
                  LibraryFilter(includeNotPlayed: true, scope: .psPlusOnly),
                  LibraryFilter(includeSubscriptionOnly: true, scope: .psPlusOnly)] {
            let sql = Set(try await store.gamesOnce(filter: f).map(\.id))
            let mem = Set(LibraryFilterEvaluator.apply(f, to: all).map(\.id))
            #expect(sql == mem)
        }
        // The scope and the Format ▸ PS Plus facet are the same set (one predicate).
        let facet = Set(try await store.gamesOnce(filter: LibraryFilter(includeSubscriptionOnly: true)).map(\.id))
        #expect(facet == scoped)
        // Preview derivation agrees.
        #expect(SidebarCounts.derive(from: all).psPlusOnly == 2)
    }

    @Test func buyingTheGameTakesItOffTheList() async throws {
        let db = try await TestDB.makeSeeded()
        try await seed(db)
        let store = LibraryStore(db)
        _ = try await store.addCopy(gameID: 1, platformID: "ps5", format: .physical)
        let count = try await db.dbWriter.read { db in try LibraryQuery.fetchPSPlusOnlyCount(db) }
        #expect(count == 1)
    }

    @Test @MainActor func rowIdentityHiddenAtZeroAndHeaderCopy() {
        #expect(SidebarSelection.psPlusOnly.id == "psPlusOnly")
        var counts = SidebarCounts()
        #expect(counts.count(for: .psPlusOnly) == 0)                 // hidden at 0
        counts.psPlusOnly = 3
        #expect(counts.count(for: .psPlusOnly) == 3)
        #expect(SidebarView.title(for: .psPlusOnly) == "PS Plus Only")
        #expect(SidebarView.psPlusOnlyTooltip.hasPrefix("Games you only have through PS Plus — they leave with the subscription"))
        #expect(PSPlusOnlyHeader.message(count: 12, deadline: (2027, 3))
                == "Leaves with PS Plus around March 2027 · 12 games you only have through PS Plus.")
        #expect(PSPlusOnlyHeader.message(count: 1, deadline: nil).hasSuffix("· 1 game"))
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.select(.psPlusOnly)
        #expect(vm.filter.scope == .psPlusOnly)
        #expect(vm.isPSPlusOnlySelection)
    }
}

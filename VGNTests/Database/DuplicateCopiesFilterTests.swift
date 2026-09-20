import Foundation
import Testing
import GRDB
@testable import VGN

/// The "Duplicate Copies" toolbar facet (owner request 2026-09-20): a game matches only
/// when it has ≥ 2 really-owned copies (`subscription IS NULL`) sharing the SAME platform
/// AND format (e.g. two physical PS3 discs). Narrower than "Multiple Copies"; ANDs across
/// kinds like any other facet (PLAN §8).
@Suite struct DuplicateCopiesFilterTests {

    private func ids(_ store: LibraryStore, _ f: LibraryFilter) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: f).map(\.id))
    }

    @Test func matchesOnlySamePlatformSameFormatDuplicates() async throws {
        let store = try await TestDB.makeStore()
        // Two physical PS3 discs of one game → duplicate.
        let dupe = try await store.addGame(GameDraft(title: "Dupe", igdbID: 1,
                                                     platformIDs: ["ps3"], owned: true, format: .physical))
        _ = try await store.addCopy(gameID: dupe.gameID, platformID: "ps3", format: .physical)
        // Multiple copies but DIFFERENT platform/format → NOT a duplicate (physical ps4 + digital ps5).
        let multi = try await store.addGame(GameDraft(title: "Multi", igdbID: 2,
                                                      platformIDs: ["ps4"], owned: true, format: .physical))
        _ = try await store.addCopy(gameID: multi.gameID, platformID: "ps5", format: .digital)
        // Same platform, DIFFERENT format (physical + digital PS3) → NOT a duplicate.
        let mixed = try await store.addGame(GameDraft(title: "Mixed", igdbID: 3,
                                                      platformIDs: ["ps3"], owned: true, format: .physical))
        _ = try await store.addCopy(gameID: mixed.gameID, platformID: "ps3", format: .digital)
        // Single copy → excluded.
        _ = try await store.addGame(GameDraft(title: "Single", igdbID: 4, platformIDs: ["pc"], owned: true))

        #expect(try await ids(store, LibraryFilter(duplicateCopies: true, scope: .all)) == [dupe.gameID])
        // Multiple Copies is broader: it matches the multi + mixed + dupe games (≥ 2 products).
        #expect(try await ids(store, LibraryFilter(multipleCopies: true, scope: .all))
                == [dupe.gameID, multi.gameID, mixed.gameID])

        // ANDs across kinds.
        var f = LibraryFilter(duplicateCopies: true, scope: .all)
        f.platforms = ["ps3"]
        #expect(try await ids(store, f) == [dupe.gameID])
        f.platforms = ["snes"]
        #expect(try await ids(store, f).isEmpty)
    }

    @Test func subscriptionCopiesDoNotCountAndDefaultOff() async throws {
        let store = try await TestDB.makeStore()
        // One real physical PS4 + one PS Plus (subscription) PS4 → NOT a duplicate
        // (a subscription copy is never a "really-owned" copy).
        let g = try await store.addGame(GameDraft(title: "Plus", igdbID: 1,
                                                  platformIDs: ["ps4"], owned: true, format: .physical))
        _ = try await store.addCopy(gameID: g.gameID, platformID: "ps4", format: .digital)
        try await store.dbWriter.write { db in
            // Mark the digital PS4 copy a PS Plus claim.
            try db.execute(sql: """
                UPDATE products SET subscription = 'ps_plus'
                WHERE platform_id = 'ps4' AND format = 'digital'
                  AND id IN (SELECT product_id FROM product_games WHERE game_id = ?)
                """, arguments: [g.gameID])
        }
        #expect(try await ids(store, LibraryFilter(duplicateCopies: true, scope: .all)).isEmpty)
        #expect(LibraryFilter(scope: .all).duplicateCopies == false)
    }

    /// A compilation copy counts as a copy of each member: a member owned once as a single
    /// physical PS3 AND once inside a physical PS3 compilation is a duplicate on ps3/physical.
    @Test func compilationCopyCountsPerMember() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "Member", igdbID: 10,
                                                  platformIDs: ["ps3"], owned: true, format: .physical)).gameID
        _ = try await store.addCompilation(
            product: ProductDraft(title: "Collection", platformID: "ps3", format: .physical),
            members: [CompilationMemberDraft(title: "Member", igdbID: 10, position: 0),
                      CompilationMemberDraft(title: "Other", igdbID: 11, position: 1)])
        #expect(try await ids(store, LibraryFilter(duplicateCopies: true, scope: .all)) == [g])
    }

    /// Prints (does not assert) grid time at 2 000 games with the facet on.
    @Test func gridTimeAt2000Games() async throws {
        let store = try await TestDB.makeStore()
        try await store.dbWriter.write { db in
            for i in 0..<2000 {
                try db.execute(sql: "INSERT INTO games (title, sort_title, played) VALUES (?, ?, 0)",
                               arguments: ["Game \(i)", "game \(i)"])
                let gid = db.lastInsertedRowID
                // Every 5th game gets two physical PS3 discs (a duplicate).
                let copies = i % 5 == 0 ? 2 : 1
                for _ in 0..<copies {
                    try db.execute(sql: """
                        INSERT INTO products (platform_id, kind, format, source) VALUES ('ps3','single','physical','manual')
                        """)
                    let pid = db.lastInsertedRowID
                    try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                                   arguments: [pid, gid])
                }
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await store.gamesOnce(filter: LibraryFilter(duplicateCopies: true, scope: .all))
        let elapsed = start.duration(to: clock.now)
        print("DuplicateCopies grid at 2000 games: \(rows.count) rows in \(elapsed)")
        #expect(rows.count == 400)
    }
}

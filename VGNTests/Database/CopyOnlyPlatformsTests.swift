import Foundation
import Testing
import GRDB
@testable import VGN

/// The **effective-platform read rule** (PLAN §4, owner decision 2026-09-20): the platforms a
/// game shows / is counted / filtered under are its copies' platforms ∪ its `played = 1` rows
/// (for an owned game), or all its `game_platforms` rows (for a played-not-owned game). Nothing
/// is ever pruned — a stale `game_platforms` row simply stops showing because the copy is gone.
@Suite struct CopyOnlyPlatformsTests {

    private func copyID(_ store: LibraryStore, game gameID: Int64, platform: String) async throws -> Int64 {
        let detail = try #require(try await store.gameDetail(id: gameID))
        return try #require(detail.copies.first { $0.platformID == platform }).productID
    }

    private func summary(_ store: LibraryStore, _ id: Int64) async throws -> GameSummary {
        try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == id })
    }

    private func rawPlatformRows(_ store: LibraryStore, _ gameID: Int64) async throws -> Set<String> {
        try await store.dbWriter.read { db in
            Set(try String.fetchAll(db, sql: "SELECT platform_id FROM game_platforms WHERE game_id = ?",
                                    arguments: [gameID]))
        }
    }

    // MARK: - The owner's original report

    @Test func removingOneCopyShowsRemainingPlatformButLeavesTheRow() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Celeste", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)

        let before = try await summary(store, id)
        #expect(Set(before.platformIDs) == ["mac", "pc"])
        #expect(FormatBadges.badges(for: before).map(\.kind) == [.digital])

        let macPID = try await copyID(store, game: id, platform: "mac")
        #expect(try await store.removeProduct(macPID) == .ok)

        // The display drops Mac everywhere…
        let after = try await summary(store, id)
        #expect(after.platformIDs == ["pc"])
        #expect(after.digitalPlatformIDs == ["pc"])
        let badges = FormatBadges.badges(for: after)
        #expect(badges.map(\.kind) == [.digital])
        #expect(badges.first?.platformIDs == ["pc"])
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.platformIDs == ["pc"])
        let counts = try await store.sidebarCountsOnce()
        #expect(counts.perPlatform["mac"] == nil)
        #expect(counts.perPlatform["pc"] == 1)

        // …but the underlying game_platforms row is UNTOUCHED (nothing pruned).
        #expect(try await rawPlatformRows(store, id) == ["mac", "pc"])
    }

    /// The grid observation re-emits a changed value on the copy delete.
    @Test(.timeLimit(.minutes(1)))
    func observationEmitsAfterCopyDelete() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Hades", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)

        var iterator = store.games(filter: LibraryFilter(scope: .all)).makeAsyncIterator()
        let before = try #require(try await iterator.next())
        #expect(Set(before.first { $0.id == id }?.platformIDs ?? []) == ["mac", "pc"])

        _ = try await store.removeProduct(try await copyID(store, game: id, platform: "mac"))
        let after = try #require(try await iterator.next())
        #expect(after.first { $0.id == id }?.platformIDs == ["pc"])
    }

    // MARK: - Rule edges

    /// A platform the owner marked *played on* (played = 1) always shows, even with no copy.
    @Test func playedOnPlatformWithoutACopyStillShows() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Hollow Knight", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: id, platformID: "mac", played: true, db: db)
        }
        _ = try await store.removeProduct(try await copyID(store, game: id, platform: "mac"))

        let after = try await summary(store, id)
        #expect(Set(after.platformIDs) == ["mac", "pc"])   // played-on Mac kept
        #expect(after.digitalPlatformIDs == ["pc"])         // but no owned Digital copy on Mac
    }

    /// A game that loses its LAST copy falls back to its rows — never zero platforms.
    @Test func losingLastCopyFallsBackToRows() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Braid", platformIDs: ["mac"], owned: true, played: true, format: .digital)).gameID
        // Copy-only shape (played = 0) — the row is the echo of the copy.
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE game_platforms SET played = 0 WHERE game_id = ?", arguments: [id])
        }
        #expect(try await store.removeProduct(try await copyID(store, game: id, platform: "mac")) == .ok)

        let after = try await summary(store, id)
        #expect(after.platformIDs == ["mac"])   // falls back to the row (no copy left)
        #expect(after.owned == false)
    }

    /// A played-not-owned game shows all its rows.
    @Test func playedNotOwnedShowsItsRows() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(title: "Journey", platformIDs: ["ps3"], played: true)).gameID
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: id, platformID: "ps4", played: true, db: db)
        }
        #expect(Set(try await summary(store, id).platformIDs) == ["ps3", "ps4"])
    }

    // MARK: - Re-platforming a copy

    @Test func rePlatformingACopyShowsTheNewPlatformOnly() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Rayman", platformIDs: ["ps4"], owned: true, format: .physical)).gameID
        let pid = try await copyID(store, game: id, platform: "ps4")
        try await store.updateProductDetails(productID: pid, platformID: "ps5")

        #expect(try await summary(store, id).platformIDs == ["ps5"])
        // The old ps4 row is still in the table, just not shown.
        #expect(try await rawPlatformRows(store, id) == ["ps4", "ps5"])
    }

    @Test func compilationPlatformChangeShowsNewForEveryMemberPlayedOnKept() async throws {
        let store = try await TestDB.makeStore()
        let (pid, _) = try await store.addCompilation(
            product: ProductDraft(title: "Sly Trilogy", platformID: "ps3", format: .physical),
            members: [CompilationMemberDraft(title: "Sly 1", igdbID: 2001, position: 0),
                      CompilationMemberDraft(title: "Sly 2", igdbID: 2002, position: 1)])
        let members = try await store.compilationMembers(productID: pid).map(\.gameID)
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: members[0], platformID: "ps3", played: true, db: db)
        }
        try await store.updateProductDetails(productID: pid, platformID: "ps2")

        #expect(Set(try await summary(store, members[0]).platformIDs) == ["ps2", "ps3"])  // played-on kept
        #expect(try await summary(store, members[1]).platformIDs == ["ps2"])              // stale ps3 hidden
    }

    // MARK: - Compilation / PS Plus copies

    @Test func compilationMemberShowsTheCompilationsPlatform() async throws {
        let store = try await TestDB.makeStore()
        let (_, _) = try await store.addCompilation(
            product: ProductDraft(title: "Orange Box", platformID: "ps3", format: .physical),
            members: [CompilationMemberDraft(title: "HL2", igdbID: 3001, position: 0)])
        let g = try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.title == "HL2" })
        #expect(g.platformIDs == ["ps3"])
    }

    @Test func psPlusOnlyGameShowsItsClaimsPlatform() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(title: "Returnal", platformIDs: ["ps5"], owned: true, format: .digital)).gameID
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE products SET subscription = 'ps_plus' WHERE id IN (SELECT product_id FROM product_games WHERE game_id = ?)",
                           arguments: [id])
        }
        #expect(try await summary(store, id).platformIDs == ["ps5"])
    }

    // MARK: - Cross-reader agreement + the owner's 12 shapes

    /// Pills, the platform filter, and the sidebar per-platform count all agree (one shared rule).
    @Test func pillsFilterAndCountsAgree() async throws {
        let store = try await TestDB.makeStore()
        // A game owned on PC, with a stale "mac" copy-only row (the owner's shape).
        let id = try await store.addGame(GameDraft(title: "Baldur's Gate", platformIDs: ["pc"], owned: true)).gameID
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: id, platformID: "mac", played: false, db: db)
        }
        // Pills: PC only.
        #expect(try await summary(store, id).platformIDs == ["pc"])
        // Filter: matches on PC, not on Mac.
        func ids(_ slug: String) async throws -> Set<Int64> {
            var f = LibraryFilter(scope: .all); f.platforms = [slug]
            return Set(try await store.gamesOnce(filter: f).map(\.id))
        }
        #expect(try await ids("pc").contains(id))
        #expect(try await ids("mac").contains(id) == false)
        // Counts: PC counts it, Mac does not (nor does Mac appear in platformsInUse).
        let counts = try await store.sidebarCountsOnce()
        #expect(counts.perPlatform["pc"] == 1)
        #expect(counts.perPlatform["mac"] == nil)
        #expect(try await store.platformsInUseOnce().contains { $0.id == "mac" } == false)
    }

    // MARK: - No automatic clean-up (owner decision, PLAN §4 inv. 5)

    /// The launch/read paths never write to `game_platforms`. A seeded DB carrying a stale
    /// copy-only row is byte-identical after the operations the app runs at launch.
    @Test func launchTimeOperationsPerformNoGamePlatformsWrite() async throws {
        let database = try await TestDB.makeSeeded()
        let store = LibraryStore(database)
        let g = try await store.addGame(GameDraft(title: "Baldur's Gate", platformIDs: ["pc"], owned: true)).gameID
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: g, platformID: "mac", played: false, db: db)
        }
        func snapshot() async throws -> [String] {
            try await store.dbWriter.read { db in
                try String.fetchAll(db, sql: """
                    SELECT game_id || ':' || platform_id || ':' || played
                    FROM game_platforms ORDER BY game_id, platform_id
                    """)
            }
        }
        let before = try await snapshot()
        #expect(before.contains("\(g):mac:0"))

        _ = try await database.seedPlatforms(from: TestDB.platforms)   // platform (re)seed
        _ = try await store.sidebarCountsOnce()
        _ = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        _ = try await store.platformsInUseOnce()

        #expect(try await snapshot() == before)
    }

    /// Prints (does not assert) grid + sidebar-count timings at 2 000 games under the shared
    /// effective-platform rule, a third of them carrying a stale copy-only platform row.
    @Test func effectivePlatformTimingsAt2000Games() async throws {
        let store = try await TestDB.makeStore()
        try await store.dbWriter.write { db in
            for i in 0..<2000 {
                try db.execute(sql: "INSERT INTO games (title, sort_title, played) VALUES (?, ?, 0)",
                               arguments: ["Game \(i)", "game \(i)"])
                let gid = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','digital','manual')")
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                               arguments: [db.lastInsertedRowID, gid])
                if i % 3 == 0 {   // a stale copy-only mac row on a third of them
                    try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, 'mac', 0)",
                                   arguments: [gid])
                }
            }
        }
        let clock = ContinuousClock()
        var start = clock.now
        let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        let gridMs = start.duration(to: clock.now)
        start = clock.now
        let counts = try await store.sidebarCountsOnce()
        let countsMs = start.duration(to: clock.now)
        print("EffectivePlatforms @2000: grid \(rows.count) rows in \(gridMs); sidebarCounts in \(countsMs)")
        // Correctness: pc counts all 2000, mac counts none (all mac rows are copy-only echoes).
        #expect(counts.perPlatform["pc"] == 2000)
        #expect(counts.perPlatform["mac"] == nil)
    }

    // MARK: - Undoable merge still restores its platform rows (unchanged)

    @Test func mergeUndoRestoresPlatformRows() async throws {
        let store = try await TestDB.makeStore()
        let source = try await store.addGame(GameDraft(
            title: "Doom", igdbID: 1001, platformIDs: ["ps2"], owned: true, format: .physical)).gameID
        let target = try await store.addGame(GameDraft(
            title: "Doom (2016)", igdbID: 1002, platformIDs: ["ps4"], owned: true, format: .physical)).gameID

        func platformRows(_ gameID: Int64) async throws -> [String: Bool] {
            try await store.dbWriter.read { db in
                var out: [String: Bool] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT platform_id, played FROM game_platforms WHERE game_id = ?",
                                            arguments: [gameID]) { out[row["platform_id"]] = row["played"] }
                return out
            }
        }
        let sourceBefore = try await platformRows(source)
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        let undo = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        #expect(try await Set(platformRows(target).keys) == ["ps2", "ps4"])

        try await store.restoreReconcile(undo)
        #expect(try await platformRows(source) == sourceBefore)
        #expect(try await Set(platformRows(target).keys) == ["ps4"])
    }
}

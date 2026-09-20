import Foundation
import Testing
import GRDB
@testable import VGN

/// Deleting a copy of a game that owns several must drop the platform that copy alone
/// put on the game, so the grid pills / inspector / sidebar counts update (owner bug
/// 2026-09-20: the "Mac" pill of a Mac+PC game survived deleting the Mac copy for ever).
/// The format-badge tooltip already updated (it reads the per-format `own` CTE); the
/// stale part was the `plat` CTE union `game_platforms ∪ product platforms`.
@Suite struct CopyOnlyPlatformsTests {

    /// The product id of `gameID`'s single copy on `platformID`.
    private func copyID(_ store: LibraryStore, game gameID: Int64, platform: String) async throws -> Int64 {
        let detail = try #require(try await store.gameDetail(id: gameID))
        return try #require(detail.copies.first { $0.platformID == platform }).productID
    }

    // MARK: - D1 — reproduce + fix

    @Test func removingOneCopyDropsThatPlatformFromTheSummary() async throws {
        let store = try await TestDB.makeStore()
        // Mac digital + PC digital, both from copies (played = 0 on the platform rows).
        let id = try await store.addGame(GameDraft(
            title: "Celeste", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)

        func summary() async throws -> GameSummary {
            try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == id })
        }

        // Before: on both platforms, one Digital badge listing both.
        let before = try await summary()
        #expect(Set(before.platformIDs) == ["mac", "pc"])
        #expect(Set(before.digitalPlatformIDs) == ["mac", "pc"])
        #expect(FormatBadges.badges(for: before).map(\.kind) == [.digital])

        // Delete the Mac copy.
        let macPID = try await copyID(store, game: id, platform: "mac")
        let outcome = try await store.removeProduct(macPID)
        #expect(outcome == .ok)

        // After: only PC remains, on the pill AND the Digital badge tooltip.
        let after = try await summary()
        #expect(after.platformIDs == ["pc"])                 // the fix (was [mac, pc])
        #expect(after.digitalPlatformIDs == ["pc"])
        let badges = FormatBadges.badges(for: after)
        #expect(badges.map(\.kind) == [.digital])
        #expect(badges.first?.platformIDs == ["pc"])

        // D5 — the inspector's platform union + copy rows drop Mac too.
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.platformIDs == ["pc"])
        #expect(detail.copies.map(\.platformID) == ["pc"])

        // D5 — the sidebar per-platform counts (same union) no longer count Mac.
        let counts = try await store.sidebarCountsOnce()
        #expect(counts.perPlatform["mac"] == nil)
        #expect(counts.perPlatform["pc"] == 1)
    }

    /// D1 — the grid observation re-emits a *changed* value on the copy delete.
    @Test(.timeLimit(.minutes(1)))
    func observationEmitsAfterCopyDelete() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Hades", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)

        var iterator = store.games(filter: LibraryFilter(scope: .all)).makeAsyncIterator()
        let before = try #require(try await iterator.next())
        #expect(Set(before.first { $0.id == id }?.platformIDs ?? []) == ["mac", "pc"])

        let macPID = try await copyID(store, game: id, platform: "mac")
        _ = try await store.removeProduct(macPID)

        let after = try #require(try await iterator.next())
        #expect(after.first { $0.id == id }?.platformIDs == ["pc"])
    }

    // MARK: - D2 rule edges

    /// (b) A platform the owner marked *played on* (played = 1) is never pruned, even with
    /// no copy behind it.
    @Test func playedPlatformRowSurvivesCopyRemoval() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Hollow Knight", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)
        // Owner states they played it on Mac (played flag on the mac platform row).
        try await store.dbWriter.write { db in
            try LibraryStore.ensureGamePlatform(gameID: id, platformID: "mac", played: true, db: db)
        }
        let macPID = try await copyID(store, game: id, platform: "mac")
        _ = try await store.removeProduct(macPID)

        let after = try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == id })
        #expect(Set(after.platformIDs) == ["mac", "pc"])     // Mac kept (played-on statement)
        #expect(after.digitalPlatformIDs == ["pc"])           // but no longer an owned Digital copy on Mac
    }

    /// (c) A played-not-owned game whose only platform came from its single copy keeps that
    /// platform — a game must never end with zero platforms.
    @Test func lastPlatformKeptWhenCopyRemovalWouldEmptyIt() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Braid", platformIDs: ["mac"], owned: true, played: true, format: .digital)).gameID
        // Played-and-owned only on Mac; the platform row came from the copy but is marked
        // played (addGame with played:true). Force the copy-only shape (played = 0) to test (c).
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE game_platforms SET played = 0 WHERE game_id = ?", arguments: [id])
        }
        let macPID = try await copyID(store, game: id, platform: "mac")
        // Removing the only copy of a *played* game keeps it (played), so it must keep a platform.
        let outcome = try await store.removeProduct(macPID)
        #expect(outcome == .ok)                               // still played → not orphaned

        let after = try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == id })
        #expect(after.platformIDs == ["mac"])                 // last platform kept (rule c)
        #expect(after.owned == false)
    }

    // MARK: - D3 — undoable paths restore the rows exactly

    /// The reconcile/merge undo snapshot captures `game_platforms` verbatim, so undoing a
    /// merge restores every platform row with its exact `played` value.
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
                                            arguments: [gameID]) {
                    out[row["platform_id"]] = row["played"]
                }
                return out
            }
        }

        let sourceBefore = try await platformRows(source)
        let inputs = try await store.mergeInputs(sourceGameID: source, targetGameID: target)
        let undo = try await store.mergeGame(sourceGameID: source, into: target, decisions: inputs.decisions)
        // Source is gone, its platform folded into the target.
        #expect(try await Set(platformRows(target).keys) == ["ps2", "ps4"])

        // Undo restores both games' rows verbatim (UndoManager.undo() hangs headless — apply the inverse directly).
        try await store.restoreReconcile(undo)
        #expect(try await platformRows(source) == sourceBefore)
        #expect(try await Set(platformRows(target).keys) == ["ps4"])
    }

    // MARK: - D4 — one-shot repair of pre-fix leftovers

    @Test func oneShotRepairRemovesStaleRowsAndIsIdempotent() async throws {
        let db = try await TestDB.makeSeeded()
        let store = LibraryStore(db)

        // A: stale copy-only row (pc copy owned; a leftover mac row with no copy).
        let a = try await store.addGame(GameDraft(title: "A", platformIDs: ["pc"], owned: true, format: .digital)).gameID
        // B: a played-on row (played = 1) with no copy — must be kept.
        let b = try await store.addGame(GameDraft(title: "B", platformIDs: ["ps4"], owned: true, played: true, format: .physical)).gameID
        // C: a played game whose only platform row is copy-only (no copy) — last platform, kept.
        let c = try await store.addGame(GameDraft(title: "C", platformIDs: ["snes"], owned: false, played: true)).gameID

        try await store.dbWriter.write { db in
            // A: inject the stale leftover.
            try LibraryStore.ensureGamePlatform(gameID: a, platformID: "mac", played: false, db: db)
            // B: a played-on-ps3 row with no copy.
            try LibraryStore.ensureGamePlatform(gameID: b, platformID: "ps3", played: true, db: db)
            // C: force its lone platform row to copy-only shape (played = 0), no copy exists.
            try db.execute(sql: "UPDATE game_platforms SET played = 0 WHERE game_id = ?", arguments: [c])
        }

        let removed = try await store.repairCopyOnlyPlatforms()
        #expect(removed == 1)                                 // only A's stale mac row

        func rows(_ gameID: Int64) async throws -> Set<String> {
            try await store.dbWriter.read { db in
                Set(try String.fetchAll(db, sql: "SELECT platform_id FROM game_platforms WHERE game_id = ?",
                                        arguments: [gameID]))
            }
        }
        #expect(try await rows(a) == ["pc"])                  // stale mac gone
        #expect(try await rows(b) == ["ps4", "ps3"])          // played-on row kept
        #expect(try await rows(c) == ["snes"])                // last platform kept

        // Idempotent: a second run is a no-op.
        #expect(try await store.repairCopyOnlyPlatforms() == 0)
    }
}

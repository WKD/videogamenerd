import Foundation
import Testing
import GRDB
@testable import VGN

/// Ranking ▸ Reset All Duels / Reset Duels in Tier (PLAN §7, owner request 2026-09-25):
/// counts, what is cleared and what is kept (tiers / played / status / holds_up / feedback /
/// updated_at), the snapshot file, and the exact undo inverse (applied directly).
@Suite(.timeLimit(.minutes(1))) struct DuelResetTests {

    /// Two tiers (S = 1, A = 2): 4 placed games each built by real duels, plus 1 unplaced in S.
    /// Returns ids and the comparison count.
    private func library() async throws -> (AppDatabase, LibraryStore, RankingStore, s: [Int64], a: [Int64]) {
        let (db, lib, rank) = try await RankTestDB.make()
        var s: [Int64] = [], a: [Int64] = []
        for i in 0..<4 {
            s.append(try await RankTestDB.addGame(lib, title: "S\(i)", tier: 1))
            a.append(try await RankTestDB.addGame(lib, title: "A\(i)", tier: 2))
        }
        // Place everything through real placement duels (better id wins).
        while let prompt = try await rank.currentDuel(), prompt.kind == .placement {
            _ = try await rank.answer(winner: min(prompt.candidate, prompt.opponent))
        }
        // One cross-tier comparison + an unplaced S game + a holds-up mark + status + feedback.
        let (s0, a0) = (s[0], a[0])
        _ = try await db.dbWriter.write { db in
            try RankingStore.insertComparison(winner: s0, loser: a0, context: "refine", db)
        }
        s.append(try await RankTestDB.addGame(lib, title: "S-unplaced", tier: 1))
        try await lib.setHoldsUp(.ofItsTime, for: [s[1]])
        try await lib.setStatus([a[2]], .finished)
        try await RecommendationStore(db).snooze(gameID: a[3])
        try await rank.enqueuePair(s[0], s[1])   // leaves a duel-state blob behind
        return (db, lib, rank, s, a)
    }

    private struct GameFacts: Equatable {
        var tier: Int64?, played: Bool, status: String?, holdsUp: String?, updatedAt: String?
    }

    private func facts(_ db: AppDatabase) async throws -> [Int64: GameFacts] {
        try await db.dbWriter.read { db in
            var out: [Int64: GameFacts] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, tier_id, played, status, holds_up, CAST(updated_at AS TEXT) AS u FROM games") {
                out[r["id"]] = GameFacts(tier: r["tier_id"], played: r["played"], status: r["status"],
                                         holdsUp: r["holds_up"], updatedAt: r["u"])
            }
            return out
        }
    }

    private func keys(_ db: AppDatabase) async throws -> [Int64: Int64] {
        try await db.dbWriter.read { db in
            var out: [Int64: Int64] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, rank_key FROM games WHERE rank_key IS NOT NULL") {
                out[r["id"]] = r["rank_key"]
            }
            return out
        }
    }

    private func comparisonRows(_ db: AppDatabase) async throws -> [[String]] {
        try await db.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT id, winner_id, loser_id, context, CAST(created_at AS TEXT) AS c FROM comparisons ORDER BY id")
                .map { r in ["\(r["id"] as Int64)", "\(r["winner_id"] as Int64)", "\(r["loser_id"] as Int64)",
                             r["context"] as String, (r["c"] as String?) ?? ""] }
        }
    }

    private func duelState(_ db: AppDatabase) async throws -> String? {
        try await db.dbWriter.read { db in try AppStateRecord.fetchOne(db, key: RankingStore.duelStateKey)?.json }
    }

    @Test func countsNameTheRealNumbers() async throws {
        let (_, _, rank, _, _) = try await library()
        let all = try await rank.duelResetCounts(.all)
        #expect(all.placedGames == 8)
        #expect(all.comparisons >= 5)          // placement duels + the refine one
        #expect(all.hasDuelState)
        let tierA = try await rank.duelResetCounts(.tier(2))
        #expect(tierA.placedGames == 4)
        let text = DuelResetPresenter.confirmationText(
            .init(comparisons: 126, placedGames: 34, hasDuelState: true), tierLetter: nil)
        #expect(text.title == "Forget 126 duels and un-place 34 games? Tiers are kept.")
        #expect(DuelResetPresenter.confirmationText(
            .init(comparisons: 1, placedGames: 1, hasDuelState: false), tierLetter: "S").title
                == "Forget 1 duel and un-place 1 game in tier S? Tiers are kept.")
    }

    @Test func resetAllClearsPlacementsDuelsAndStateOnly() async throws {
        let (db, _, rank, s, _) = try await library()
        let beforeFacts = try await facts(db)
        let beforeKeys = try await keys(db)
        let beforeRows = try await comparisonRows(db)
        let beforeState = try await duelState(db)
        let feedbackBefore = try await db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback") }

        let undo = try await rank.resetDuels(.all, snapshotDirectory: nil)
        #expect(undo.placements.count == beforeKeys.count)
        #expect(undo.comparisons.count == beforeRows.count)

        #expect(try await keys(db).isEmpty)                              // everyone unplaced…
        #expect(try await comparisonRows(db).isEmpty)                    // …every duel forgotten
        #expect(try await duelState(db) == nil)                          // resumable session gone
        let afterFacts = try await facts(db)
        for (id, f) in beforeFacts where afterFacts[id] != f {
            Issue.record("game \(id) changed: \(f) → \(String(describing: afterFacts[id]))")
        }
        #expect(afterFacts == beforeFacts)                               // tiers/played/status/holds_up/updated_at kept
        let feedbackAfter = try await db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback") }
        #expect(feedbackAfter == feedbackBefore)
        // Invariants hold, every tiered game is in the unplaced tail, and Duel offers placing.
        let snap = try await RankTestDB.snapshot(rank)
        #expect(Consistency.checkInvariants(snap).isEmpty)
        #expect(RankTestDB.unplaced(snap, tier: 1).count == s.count)
        // Duel now offers to place every tiered game (read-only count — asking for the next
        // prompt would auto-place a tier's first game).
        #expect(try await rank.duelQueueCountOnce() == s.count + 4)
        // The taste model reads the tier bands: every game of a tier gets its tier's midpoint.
        let ranked = try await RecommendationStore(db).rankedGames()
        #expect(ranked.count == s.count + 4)
        let sScores = Set(ranked.filter { s.contains($0.id) }.map(\.score))
        #expect(sScores.count == 1)
        // The Top / derived scores: every game approximate (band midpoint), none numbered.
        let snapAfter = try await RankTestDB.snapshot(rank)
        let derived = DerivedScore.scores(snapAfter)
        let allApprox = derived.values.allSatisfy { $0.isApproximate }
        #expect(allApprox)

        // The exact inverse.
        try await rank.undoDuelReset(undo)
        #expect(try await keys(db) == beforeKeys)
        #expect(try await comparisonRows(db) == beforeRows)
        #expect(try await duelState(db) == beforeState)
        let undoneFacts = try await facts(db)
        for (id, f) in beforeFacts where undoneFacts[id] != f {
            Issue.record("after undo, game \(id) changed: \(f) → \(String(describing: undoneFacts[id]))")
        }
    }

    @Test func resetOneTierLeavesTheOtherAlone() async throws {
        let (db, _, rank, s, a) = try await library()
        let beforeKeys = try await keys(db)
        let beforeRows = try await comparisonRows(db)

        let undo = try await rank.resetDuels(.tier(2), snapshotDirectory: nil)
        let after = try await keys(db)
        for id in a { #expect(after[id] == nil) }                        // tier A un-placed
        for id in s.prefix(4) { #expect(after[id] == beforeKeys[id]) }   // tier S untouched
        // Only comparisons touching a tier-A game are gone (incl. the S-vs-A refine one).
        let aSet = Set(a.map { "\($0)" })
        let remaining = try await comparisonRows(db)
        #expect(remaining == beforeRows.filter { !aSet.contains($0[1]) && !aSet.contains($0[2]) })
        #expect(!remaining.isEmpty)
        // The duel state is trimmed, not deleted; the S-S enqueued pair survives.
        #expect(try await duelState(db) != nil)
        #expect(Consistency.checkInvariants(try await RankTestDB.snapshot(rank)).isEmpty)

        try await rank.undoDuelReset(undo)
        #expect(try await keys(db) == beforeKeys)
        #expect(try await comparisonRows(db) == beforeRows)
    }

    @Test func undoNeverOverwritesALaterMove() async throws {
        let (db, _, rank, _, a) = try await library()
        let undo = try await rank.resetDuels(.all, snapshotDirectory: nil)
        // After the reset the owner drags a[0] to the top of tier S.
        try await rank.move(gameID: a[0], toTier: 1, atIndex: 0)
        let moved = try await keys(db)[a[0]]
        try await rank.undoDuelReset(undo)
        let after = try await keys(db)
        #expect(after[a[0]] == moved)                                     // later move kept
        #expect(Consistency.checkInvariants(try await RankTestDB.snapshot(rank)).isEmpty)
    }

    @Test func snapshotIsWrittenFirstAndNeverRotated() async throws {
        let (tempDB, dir) = try AppDatabase.temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = LibraryStore(tempDB)
        let rank = RankingStore(tempDB)
        _ = try await tempDB.seedPlatformsFromBundle()
        let g = try await lib.addGame(GameDraft(title: "G", platformIDs: ["ps4"], owned: true, played: true, tierID: 1)).gameID
        try await rank.move(gameID: g, toTier: 1, atIndex: 0)
        let backups = dir.appendingPathComponent("backups", isDirectory: true)

        let undo = try await rank.resetDuels(.all, snapshotDirectory: backups)
        let url = try #require(undo.snapshotURL)
        #expect(url.lastPathComponent.hasPrefix("before-duel-reset-"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The snapshot holds the PRE-reset state.
        let snapKey = try await DatabaseQueue(path: url.path).read { db in
            try Int64.fetchOne(db, sql: "SELECT rank_key FROM games WHERE id = ?", arguments: [g])
        }
        #expect(snapKey != nil)
        // Launch-snapshot rotation (vgn-*.sqlite only) never removes it.
        try AppDatabase.rotateBackups(inDirectory: backups, keeping: 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// The presenter: confirmation from real counts, one "Reset All Duels" undo step whose
/// inverse (applied directly — `UndoManager.undo()` hangs headless) restores everything.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DuelResetPresenterTests {

    @Test func confirmThenUndoStep() async throws {
        let (db, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "G", tier: 1)
        let h = try await RankTestDB.addGame(lib, title: "H", tier: 1)
        while let p = try await rank.currentDuel(), p.kind == .placement {
            _ = try await rank.answer(winner: min(p.candidate, p.opponent))
        }
        let presenter = DuelResetPresenter(ranking: rank, snapshotDirectory: nil)
        let um = UndoManager()
        presenter.undoManagerOverride = um

        await presenter.request(.all)
        let pending = try #require(presenter.confirmation)
        #expect(pending.title.hasPrefix("Forget "))
        #expect(pending.title.hasSuffix("Tiers are kept."))
        let generation = presenter.resetGeneration

        let undo = try #require(await presenter.perform(.all))
        #expect(presenter.resetGeneration == generation + 1)
        #expect(um.canUndo)
        #expect(um.undoActionName == DuelResetPresenter.resetAllTitle)
        let keysAfter = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE rank_key IS NOT NULL")
        }
        #expect(keysAfter == 0)

        await presenter.performUndo(undo)
        let restored = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE rank_key IS NOT NULL AND id IN (?, ?)",
                             arguments: [g, h])
        }
        #expect(restored == 2)

        // Nothing left to reset in an empty tier → no confirmation.
        presenter.cancel()
        await presenter.request(.tier(6))
        #expect(presenter.confirmation == nil)
    }
}

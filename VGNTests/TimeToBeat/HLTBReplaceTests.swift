import Foundation
import Testing
import GRDB
@testable import VGN

/// The "Refresh Time Estimates from HowLongToBeat…" replace path (PLAN §5.3, D4): it
/// overwrites the three times when HLTB has the game, leaves an unknown game flagged, and
/// exposes one batch of previous values for a single Undo. Reuses ``FakeHLTBSearch`` (no
/// network). `@MainActor` + GRDB ⇒ `.serialized`; `UndoManager.undo()` hangs headless, so
/// the batch inverse is applied directly.
@MainActor
@Suite(.serialized)
struct HLTBReplaceTests {

    private let h = 3600

    private func store(_ games: [(Int64, String, Int?, Int?, Int?)]) async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            for (id, title, r, m, c) in games {
                try db.execute(sql: """
                    INSERT INTO games (id, title, played, ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                    VALUES (?, ?, 1, ?, ?, ?, 'igdb')
                    """, arguments: [id, title, r, m, c])
            }
        }
        return LibraryStore(db)
    }

    /// A confident HLTB match carrying all three times (main→hastily, main+extra→normally,
    /// completionist→completely).
    private func candidate(_ id: Int64, _ name: String) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, releaseYear: 2015,
                      mainSeconds: 1 * h, mainExtraSeconds: 5 * h, completionistSeconds: 10 * h)
    }

    private func runReplace(_ model: HLTBBulkFetchModel, ids: [Int64]) async {
        model.start(gameIDs: ids)
        if model.needsConfirmation { model.confirmAndRun() }
        for _ in 0..<4000 where model.phase == .running { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func replaceOverwritesTheThreeTimesAndClaimsHLTB() async throws {
        let store = try await store([(1, "Alpha", 8 * h, 10 * h, 100 * h)])  // flagged (100 ≥ 4×10)
        let fake = FakeHLTBSearch(byTitle: ["Alpha": [candidate(10, "Alpha")]])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake }, mode: .replace)
        // Replace confirms first.
        model.start(gameIDs: [1])
        #expect(model.needsConfirmation)
        model.confirmAndRun()
        for _ in 0..<4000 where model.phase == .running { await Task.yield() }

        #expect(model.phase == .finished)
        #expect(model.filled == 1)
        let d = try await store.gameDetail(id: 1)
        #expect(d?.ttbHastilyS == 1 * h)
        #expect(d?.ttbNormallyS == 5 * h)
        #expect(d?.ttbCompletelyS == 10 * h)
        #expect(d?.ttbSource == "hltb")
        #expect(d?.hltbID == 10)
        // No longer flagged (hltb is the reference).
        #expect(try await store.suspiciousEstimateGameIDs().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func replaceLeavesAnUnknownGameFlagged() async throws {
        let store = try await store([(1, "Ghost", nil, 10 * h, 100 * h)])
        let fake = FakeHLTBSearch(byTitle: ["Ghost": []])   // HLTB doesn't know it
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake }, mode: .replace)
        await runReplace(model, ids: [1])

        #expect(model.filled == 0)
        #expect(model.notFound == 1)
        let d = try await store.gameDetail(id: 1)
        #expect(d?.ttbNormallyS == 10 * h)         // untouched
        #expect(d?.ttbCompletelyS == 100 * h)
        #expect(d?.ttbSource == "igdb")            // still not the reference
        #expect(try await store.suspiciousEstimateGameIDs() == [1])   // stays flagged
    }

    @Test(.timeLimit(.minutes(1)))
    func oneBatchUndoRestoresEveryReplacedGame() async throws {
        let store = try await store([(1, "Alpha", 8 * h, 10 * h, 100 * h),
                                     (2, "Beta", 9 * h, 12 * h, 200 * h)])
        let fake = FakeHLTBSearch(byTitle: ["Alpha": [candidate(10, "Alpha")],
                                            "Beta": [candidate(20, "Beta")]])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake }, mode: .replace)
        var captured: [Int64: HLTBTimeSnapshot] = [:]
        model.onReplaceFinished = { captured = $0 }
        await runReplace(model, ids: [1, 2])

        #expect(model.filled == 2)
        #expect(captured.count == 2)

        // Apply the inverse directly (UndoManager.undo() hangs headless).
        try await store.restoreTimeToBeatBatch(captured)
        let d1 = try await store.gameDetail(id: 1)
        let d2 = try await store.gameDetail(id: 2)
        #expect(d1?.ttbHastilyS == 8 * h && d1?.ttbNormallyS == 10 * h && d1?.ttbCompletelyS == 100 * h)
        #expect(d1?.ttbSource == "igdb")
        #expect(d2?.ttbNormallyS == 12 * h && d2?.ttbCompletelyS == 200 * h)
        #expect(d2?.ttbSource == "igdb")
    }

    @Test(.timeLimit(.minutes(1)))
    func stopOnUnexpectedResponseLeavesEarlierReplacementsIntact() async throws {
        let store = try await store([(1, "Alpha", 8 * h, 10 * h, 100 * h),
                                     (2, "Reject", nil, 10 * h, 100 * h),
                                     (3, "Later", nil, 10 * h, 100 * h)])
        let fake = FakeHLTBSearch(byTitle: ["Alpha": [candidate(10, "Alpha")]],
                                  rejectTitles: ["Reject"])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake }, mode: .replace)
        var captured: [Int64: HLTBTimeSnapshot] = [:]
        model.onReplaceFinished = { captured = $0 }
        await runReplace(model, ids: [1, 2, 3])

        #expect(model.phase == .stopped)
        #expect(model.stoppedNote == "VGN stopped and made no further requests.")
        #expect(!fake.calls.contains("Later"))         // stopped at the reject
        // Alpha's replacement survived the stop; its snapshot is in the batch.
        #expect(captured.keys.contains(1))
        let d1 = try await store.gameDetail(id: 1)
        #expect(d1?.ttbSource == "hltb")
        // Later untouched.
        let d3 = try await store.gameDetail(id: 3)
        #expect(d3?.ttbSource == "igdb")
    }

    @Test(.timeLimit(.minutes(1)))
    func fillGapsModeStillOnlyFillsEmptyFields() async throws {
        // Alpha already has a main story; fill-gaps must not overwrite it, only fill the gap.
        let store = try await store([(1, "Alpha", nil, 10 * h, nil)])
        let fake = FakeHLTBSearch(byTitle: ["Alpha": [candidate(10, "Alpha")]])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake }, mode: .fillGaps)
        model.start(gameIDs: [1])
        for _ in 0..<4000 where model.phase == .running { await Task.yield() }

        let d = try await store.gameDetail(id: 1)
        #expect(d?.ttbNormallyS == 10 * h)        // kept (not overwritten by candidate's 5 h)
        #expect(d?.ttbHastilyS == 1 * h)          // gap filled
        #expect(d?.ttbCompletelyS == 10 * h)      // gap filled
        #expect(d?.ttbSource == "igdb")           // had a prior source, keeps it
    }
}

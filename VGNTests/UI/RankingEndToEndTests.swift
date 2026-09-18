import Testing
@testable import VGN

/// End-to-end: seed 12 played games, triage them into one tier through
/// ``TriageModel``, then run every placement duel to completion through
/// ``DuelModel`` with a consistent oracle, and assert the store's final order
/// matches (PLAN §7). Drives the live ``LiveRankingBackend`` over an in-memory
/// database — so `@MainActor`, serialized, hard-timeout (EXECUTION test hygiene).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RankingEndToEndTests {

    @Test func triageThenDuelToCompletionOrdersTheTier() async throws {
        let db = try await TestDB.makeSeeded()
        let library = LibraryStore(db)
        let ranking = RankingStore(db)
        let backend = LiveRankingBackend(ranking: ranking, library: library, coverLoader: NoopCoverLoader())

        // 12 played + owned games, each with a distinct "true quality" score.
        var scoreByID: [Int64: Int] = [:]
        let scores = [50, 12, 88, 33, 71, 5, 99, 46, 27, 63, 80, 19]
        for (i, score) in scores.enumerated() {
            let id = try await library.addGame(
                GameDraft(title: "Game \(i)", platformIDs: ["pc"], owned: true, played: true)).gameID
            scoreByID[id] = score
        }

        // Triage every unranked game into tier S (id 1) via the model's keystrokes.
        let triage = TriageModel(backend: backend)
        await triage.start()
        #expect(triage.pending.count == 12)
        var guardT = 0
        while triage.current != nil, guardT < 100 {
            guardT += 1
            _ = await triage.handle(character: "S")
        }
        #expect(triage.isDone)
        #expect(try await backend.duelQueueCountOnce() == 12)

        // Run duels to completion. The oracle always prefers the higher score, so
        // the resulting order is a clean total order.
        let duel = DuelModel(backend: backend)
        await duel.refresh()
        var guardD = 0
        while try await backend.duelQueueCountOnce() > 0 {
            guardD += 1
            #expect(guardD < 2000)
            if guardD >= 2000 { break }
            guard let d = duel.display else { await duel.refresh(); continue }
            let winner = (scoreByID[d.candidate.id] ?? 0) >= (scoreByID[d.opponent.id] ?? 0)
                ? d.candidate.id : d.opponent.id
            await duel.choose(winner: winner)
        }

        // The queue is drained and tier S is ordered best → worst by true score.
        #expect(try await backend.duelQueueCountOnce() == 0)

        let board = try await backend.tierBoardOnce()
        let sRow = try #require(board.first { $0.tier.letter == "S" })
        #expect(sRow.unplaced.isEmpty)
        let placedIDs = sRow.placed.map(\.id)
        #expect(placedIDs.count == 12)

        let expected = scoreByID.keys.sorted { scoreByID[$0]! > scoreByID[$1]! }
        #expect(placedIDs == expected)
    }
}

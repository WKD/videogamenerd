import Testing
@testable import VGN

/// TriageModel tests against ``ScriptedRankingBackend`` (no database): tiering
/// advances, skip cycles to the end, back undoes, keystroke handling, and the
/// end-state summary counts (PLAN §7).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RankingTriageModelTests {

    private func games(_ ids: [Int64]) -> [GameSummary] {
        ids.map { GameSummary(id: $0, title: "Game \($0)", played: true, platformIDs: ["pc"]) }
    }

    private func backend(_ ids: [Int64]) -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.unranked = games(ids)
        b.tierList = TierInfo.defaults
        return b
    }

    @Test func startLoadsTheQueue() async {
        let m = TriageModel(backend: backend([10, 11, 12]))
        await m.start()
        #expect(m.pending.count == 3)
        #expect(m.current?.id == 10)
        #expect(m.progressText == "1 of 3")
        #expect(m.total == 3)
        #expect(m.canGoBack == false)
    }

    @Test func tieringAdvancesAndRecords() async {
        let b = backend([10, 11, 12])
        let m = TriageModel(backend: b)
        await m.start()

        await m.tierCurrent(1)            // S
        #expect(b.tierCalls.count == 1)
        #expect(b.tierCalls.first?.ids == [10])
        #expect(b.tierCalls.first?.tierID == 1)
        #expect(m.tieredCount == 1)
        #expect(m.current?.id == 11)
        #expect(m.progressText == "2 of 3")
        #expect(m.perTierCounts[1] == 1)
    }

    @Test func tieringAllReachesTheSummary() async {
        let m = TriageModel(backend: backend([10, 11, 12]))
        await m.start()
        await m.tierCurrent(1)
        await m.tierCurrent(2)
        await m.tierCurrent(3)
        #expect(m.isDone)
        #expect(m.tieredCount == 3)
        #expect(m.perTierCounts == [1: 1, 2: 1, 3: 1])
    }

    @Test func skipCyclesToTheEnd() async {
        let m = TriageModel(backend: backend([10, 11, 12]))
        await m.start()
        #expect(m.current?.id == 10)
        m.skip(); #expect(m.current?.id == 11)
        m.skip(); #expect(m.current?.id == 12)
        m.skip(); #expect(m.current?.id == 10)   // back to the start, nothing tiered
        #expect(m.tieredCount == 0)
    }

    @Test func backUndoesTheLastTiering() async {
        let b = backend([10, 11, 12])
        let m = TriageModel(backend: b)
        await m.start()
        await m.tierCurrent(1)
        #expect(m.current?.id == 11)

        await m.back()
        #expect(b.tierCalls.last?.ids == [10])      // clear-tier inverse
        #expect(b.tierCalls.last?.tierID == nil)
        #expect(m.current?.id == 10)
        #expect(m.tieredCount == 0)
        #expect(m.perTierCounts[1] == nil)
        #expect(m.canGoBack == false)
    }

    @Test func keystrokeHandlingTiersSkipsAndIgnores() async {
        let m = TriageModel(backend: backend([10, 11, 12]))
        await m.start()

        #expect(await m.handle(character: "s"))     // case-insensitive tier
        #expect(m.current?.id == 11)
        #expect(await m.handle(character: "0"))     // skip
        #expect(m.current?.id == 12)
        #expect(await m.handle(character: " "))     // skip
        #expect(m.current?.id == 11)
        #expect(await m.handle(character: "x") == false)   // not a tier key
    }

    @Test func summaryCountsPerTier() async {
        let m = TriageModel(backend: backend([10, 11, 12, 13]))
        await m.start()
        await m.tierCurrent(1)   // S
        await m.tierCurrent(1)   // S
        await m.tierCurrent(3)   // B
        await m.tierCurrent(6)   // F
        #expect(m.isDone)
        #expect(m.perTierCounts == [1: 2, 3: 1, 6: 1])
    }

    // MARK: - Safe un-play (`U`)

    @Test func unplayOwnedDropsWithoutPrompt() async {
        let b = backend([10, 11, 12])
        b.unplayOutcome = .becameBacklog
        let m = TriageModel(backend: b)
        await m.start()
        #expect(await m.handle(character: "u"))
        #expect(b.unplayed == [10])
        #expect(m.removalPrompt == nil)
        #expect(m.current?.id == 11)          // dropped from the queue
        #expect(m.pending.count == 2)
    }

    @Test func unplayNotOwnedRaisesRemovalPrompt() async {
        let b = backend([10, 11, 12])
        b.unplayOutcome = .notOwned
        let m = TriageModel(backend: b)
        await m.start()
        await m.unplayCurrent()
        #expect(m.removalPrompt?.id == 10)    // explicit decision, no surprise delete
        #expect(m.pending.count == 3)         // still in the queue until decided
        #expect(b.deleted.isEmpty)

        await m.confirmRemoval()
        #expect(b.deleted == [10])
        #expect(m.removalPrompt == nil)
        #expect(m.pending.count == 2)
        #expect(m.current?.id == 11)
    }

    @Test func cancelRemovalKeepsGame() async {
        let b = backend([10, 11, 12])
        b.unplayOutcome = .notOwned
        let m = TriageModel(backend: b)
        await m.start()
        await m.unplayCurrent()
        m.cancelRemoval()
        #expect(m.removalPrompt == nil)
        #expect(m.pending.count == 3)
        #expect(b.deleted.isEmpty)
    }
}

import Testing
@testable import VGN

/// Wave 23 — Triage follows the library while shown: games tiered / un-played elsewhere
/// leave the queue, newly eligible games are appended, and the current card is never
/// swapped for another eligible game (if it becomes ineligible itself, Triage moves on
/// with a quiet note). Driven by a hand-fed unranked-games stream (no database).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TriageLiveQueueTests {

    private func games(_ ids: [Int64]) -> [GameSummary] {
        ids.map { GameSummary(id: $0, title: "Game \($0)", played: true, platformIDs: ["pc"]) }
    }

    /// A started model + its live observation and the stream's feeding end.
    private func liveModel(_ ids: [Int64]) async
        -> (TriageModel, ScriptedRankingBackend, AsyncStream<[GameSummary]>.Continuation, Task<Void, Never>) {
        let b = ScriptedRankingBackend()
        b.unranked = games(ids)
        b.tierList = TierInfo.defaults
        let (stream, continuation) = AsyncStream<[GameSummary]>.makeStream()
        b.liveUnranked = stream
        let m = TriageModel(backend: b)
        await m.start()
        let task = Task { await m.observeLibrary() }
        return (m, b, continuation, task)
    }

    private func waitUntil(_ cond: () -> Bool) async {
        let start = ContinuousClock.now
        while !cond(), ContinuousClock.now - start < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func gameTieredElsewhereLeavesTheQueue() async {
        let (m, _, feed, task) = await liveModel([10, 11, 12])
        feed.yield(games([10, 12]))
        await waitUntil { m.pending.map(\.id) == [10, 12] }
        #expect(m.pending.map(\.id) == [10, 12])
        #expect(m.current?.id == 10)
        #expect(m.notice == nil)
        #expect(m.progressText == "1 of 2")
        task.cancel()
    }

    @Test func newlyEligibleGameIsAppended() async {
        let (m, _, feed, task) = await liveModel([10, 11])
        feed.yield(games([13, 10, 11]))
        await waitUntil { m.pending.count == 3 }
        #expect(m.pending.map(\.id) == [10, 11, 13])
        #expect(m.current?.id == 10)
        task.cancel()
    }

    @Test func currentCardIsNeverSwappedForAnotherEligibleGame() async {
        let (m, _, feed, task) = await liveModel([10, 11, 12])
        m.skip()                                   // current = 11, queue 10 at the end
        #expect(m.current?.id == 11)
        feed.yield(games([12, 11, 10, 14]))        // reordered + a new one
        await waitUntil { m.pending.count == 4 }
        #expect(m.current?.id == 11)
        #expect(m.notice == nil)
        task.cancel()
    }

    @Test func currentGameBecomingIneligibleAdvancesWithANote() async {
        let (m, _, feed, task) = await liveModel([10, 11, 12])
        feed.yield(games([11, 12]))                // 10 tiered in the grid meanwhile
        await waitUntil { m.current?.id == 11 }
        #expect(m.current?.id == 11)
        #expect(m.notice?.contains("Game 10") == true)
        m.skip()                                   // the next action clears the note
        #expect(m.notice == nil)
        task.cancel()
    }

    @Test func lastEligibleGameGoingAwayEndsTriage() async {
        let (m, _, feed, task) = await liveModel([10])
        feed.yield([])
        await waitUntil { m.isDone }
        #expect(m.isDone)
        #expect(m.current == nil)
        task.cancel()
    }

    /// An emission that lands while our own tier write is in flight may predate it; it is
    /// held back and replaced by one fresh read once the write settles.
    @Test func staleEmissionDuringOwnWriteIsReplacedByAFreshRead() async {
        let (m, b, feed, task) = await liveModel([10, 11, 12])
        b.duringSetTier = { @Sendable in
            feed.yield([                            // pre-write state, 10 still untiered
                GameSummary(id: 10, title: "Game 10", played: true),
                GameSummary(id: 11, title: "Game 11", played: true),
                GameSummary(id: 12, title: "Game 12", played: true),
            ])
            for _ in 0..<20 { await Task.yield() }
        }
        b.unranked = games([11, 12])               // what a read after the write returns
        await m.tierCurrent(1)
        await waitUntil { m.pending.map(\.id) == [11, 12] }
        #expect(m.pending.map(\.id) == [11, 12])   // 10 did not come back
        #expect(m.current?.id == 11)
        #expect(m.tieredCount == 1)
        task.cancel()
    }

    @Test func backNeverDuplicatesAGameAReconcileAlreadyReAdded() async {
        let (m, _, feed, task) = await liveModel([10, 11])
        await m.tierCurrent(1)
        feed.yield(games([11, 10]))                // 10 un-tiered elsewhere → re-appended
        await waitUntil { m.pending.count == 2 }
        await m.back()
        #expect(m.pending.map(\.id).filter { $0 == 10 }.count == 1)
        #expect(m.current?.id == 10)
        task.cancel()
    }

    @Test func observationEndsWhenTheViewTaskIsCancelled() async {
        let (_, _, _, task) = await liveModel([10])
        task.cancel()
        await task.value                           // returns — no dangling loop
    }
}

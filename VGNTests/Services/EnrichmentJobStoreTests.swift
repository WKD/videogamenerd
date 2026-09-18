import Foundation
import Testing
@testable import VGN

/// Unit tests for the persisted job queue (PLAN §9): idempotent enqueue, atomic
/// claim under concurrency, backoff schedule, crash recovery, permanent failure,
/// retry on demand, counts observation, and the cover→metadata dependency.
struct EnrichmentJobStoreTests {

    /// A seeded in-memory library plus `count` owned IGDB games (FK targets).
    private static func makeStoreWithGames(
        _ count: Int, backoff: EnrichmentBackoff = EnrichmentBackoff(),
        date: MutableDate = MutableDate(), jitter: Double = 0.5
    ) async throws -> (EnrichmentJobStore, [Int64]) {
        let library = try await TestDB.makeStore()
        var ids: [Int64] = []
        for i in 0..<count {
            let outcome = try await library.addGame(GameDraft(
                title: "Game \(i)", igdbID: Int64(5000 + i), platformIDs: ["ps4"], owned: true))
            ids.append(outcome.gameID)
        }
        let store = EnrichmentJobStore(library.database, backoff: backoff,
                                       now: { date.now }, jitter: { jitter })
        return (store, ids)
    }

    @Test("Enqueue is idempotent per (kind, game)")
    func idempotentEnqueue() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(1)
        let first = try await store.enqueue(kind: .metadata, gameID: ids[0])
        let second = try await store.enqueue(kind: .metadata, gameID: ids[0])
        #expect(first == true)
        #expect(second == false)                      // no duplicate row
        let counts = try await store.countsOnce()
        #expect(counts.pending == 1)
        // A different kind for the same game is a distinct job.
        _ = try await store.enqueue(kind: .cover, gameID: ids[0])
        #expect(try await store.countsOnce().pending == 2)
    }

    @Test("Re-enqueue with reset re-arms a done/failed job but not a running one")
    func resetEnqueue() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(1)
        _ = try await store.enqueue(kind: .metadata, gameID: ids[0])
        let claimed = try await store.claimBatch(kind: .metadata, limit: 10)
        try await store.complete(jobID: claimed[0].id!)
        #expect(try await store.countsOnce().done == 1)

        // Plain re-enqueue leaves the done job alone; reset re-arms it.
        _ = try await store.enqueue(kind: .metadata, gameID: ids[0], reset: false)
        #expect(try await store.countsOnce().done == 1)
        let changed = try await store.enqueue(kind: .metadata, gameID: ids[0], reset: true)
        #expect(changed == true)
        #expect(try await store.countsOnce().pending == 1)
    }

    @Test("Two concurrent claimers never get the same job")
    func atomicClaim() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(40)
        for id in ids { _ = try await store.enqueue(kind: .metadata, gameID: id) }

        async let a = store.claimBatch(kind: .metadata, limit: 40)
        async let b = store.claimBatch(kind: .metadata, limit: 40)
        let (claimedA, claimedB) = try await (a, b)

        let idsA = Set(claimedA.map(\.gameID))
        let idsB = Set(claimedB.map(\.gameID))
        #expect(idsA.isDisjoint(with: idsB))                   // no double-claim
        #expect(idsA.count + idsB.count == 40)                 // all claimed, none lost
        #expect(try await store.countsOnce().running == 40)
    }

    @Test("Backoff schedule grows exponentially, then goes permanent after maxAttempts")
    func backoffSchedule() async throws {
        let date = MutableDate()
        let backoff = EnrichmentBackoff(maxAttempts: 4, baseDelay: 60, factor: 2,
                                        maxDelay: 100_000, jitterRange: 1.0...1.0)   // no jitter
        let (store, ids) = try await Self.makeStoreWithGames(1, backoff: backoff, date: date, jitter: 0.5)
        _ = try await store.enqueue(kind: .metadata, gameID: ids[0])
        let job = try await store.claimBatch(kind: .metadata, limit: 1)
        let jobID = job[0].id!

        let base = date.now
        // Delays 60/120/240 accumulate as the clock is advanced to each retry:
        // fail@base→+60, fail@base+60→+120 (base+180), fail@base+180→+240 (base+420).
        for (attempt, expected) in [(1, 60.0), (2, 180.0), (3, 420.0)] {
            try await store.fail(jobID: jobID, error: "boom", transient: true)
            let row = try #require(try await store.job(kind: .metadata, gameID: ids[0]))
            #expect(row.attempts == attempt)
            let next = try #require(row.nextAttemptAt)
            #expect(abs(next.timeIntervalSince(base) - expected) < 0.5)
            // Re-claim for the next failure (make it due).
            date.set(next)
            _ = try await store.claimBatch(kind: .metadata, limit: 1)
        }
        // 4th failure hits maxAttempts → permanent (no next_attempt_at).
        try await store.fail(jobID: jobID, error: "boom", transient: true)
        let row = try #require(try await store.job(kind: .metadata, gameID: ids[0]))
        #expect(row.attempts == 4)
        #expect(row.state == EnrichmentState.failed.rawValue)
        #expect(row.nextAttemptAt == nil)
        // A permanent job is never claimed automatically.
        #expect(try await store.claimBatch(kind: .metadata, limit: 1).isEmpty)
    }

    @Test("A non-transient failure is permanent immediately")
    func permanentFailure() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(1)
        _ = try await store.enqueue(kind: .metadata, gameID: ids[0])
        let job = try await store.claimBatch(kind: .metadata, limit: 1)
        try await store.fail(jobID: job[0].id!, error: "decode", transient: false)
        let row = try #require(try await store.job(kind: .metadata, gameID: ids[0]))
        #expect(row.attempts == 1)
        #expect(row.nextAttemptAt == nil)
        #expect(try await store.claimBatch(kind: .metadata, limit: 1).isEmpty)
    }

    @Test("Crash recovery resets running jobs to pending")
    func crashRecovery() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(3)
        for id in ids { _ = try await store.enqueue(kind: .metadata, gameID: id) }
        _ = try await store.claimBatch(kind: .metadata, limit: 3)     // all running (simulate a crash)
        #expect(try await store.countsOnce().running == 3)

        let recovered = try await store.recoverRunning()
        #expect(recovered == 3)
        let counts = try await store.countsOnce()
        #expect(counts.running == 0)
        #expect(counts.pending == 3)
        #expect(try await store.claimBatch(kind: .metadata, limit: 3).count == 3)   // claimable again
    }

    @Test("A permanently failed job is retryable on demand")
    func retryOnDemand() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(2)
        for id in ids { _ = try await store.enqueue(kind: .metadata, gameID: id) }
        let jobs = try await store.claimBatch(kind: .metadata, limit: 2)
        for job in jobs { try await store.fail(jobID: job.id!, error: "x", transient: false) }
        #expect(try await store.countsOnce().failed == 2)
        #expect(try await store.claimBatch(kind: .metadata, limit: 2).isEmpty)

        let rearmed = try await store.retryFailed()
        #expect(rearmed == 2)
        let counts = try await store.countsOnce()
        #expect(counts.failed == 0)
        #expect(counts.pending == 2)
        let claimed = try await store.claimBatch(kind: .metadata, limit: 2)
        #expect(claimed.count == 2)
        #expect(claimed.allSatisfy { $0.attempts == 0 })            // backoff restarts
    }

    @Test("Counts observation emits the queue state")
    func countsObservation() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(3)
        for id in ids { _ = try await store.enqueue(kind: .metadata, gameID: id) }
        var iterator = store.counts().makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.pending == 3)
        #expect(first?.remaining == 3)
    }

    @Test("Cover jobs wait for their game's metadata (dependency, not luck)")
    func coverWaitsForMetadata() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(1)
        _ = try await store.enqueue(kind: .metadata, gameID: ids[0])
        _ = try await store.enqueue(kind: .cover, gameID: ids[0])

        // While metadata is pending, the cover job is not claimable.
        #expect(try await store.claimBatch(kind: .cover, limit: 5, requireMetadataDone: true).isEmpty)

        let meta = try await store.claimBatch(kind: .metadata, limit: 1)
        #expect(try await store.claimBatch(kind: .cover, limit: 5, requireMetadataDone: true).isEmpty)  // still running
        try await store.complete(jobID: meta[0].id!)

        // Metadata done → cover becomes claimable.
        #expect(try await store.claimBatch(kind: .cover, limit: 5, requireMetadataDone: true).count == 1)
    }

    @Test("Purge deletes done jobs only")
    func purgeDone() async throws {
        let (store, ids) = try await Self.makeStoreWithGames(2)
        for id in ids { _ = try await store.enqueue(kind: .metadata, gameID: id) }
        let jobs = try await store.claimBatch(kind: .metadata, limit: 2)
        try await store.complete(jobID: jobs[0].id!)
        // jobs[1] left running.
        let purged = try await store.purgeDone()
        #expect(purged == 1)
        let counts = try await store.countsOnce()
        #expect(counts.done == 0)
        #expect(counts.running == 1)
    }
}

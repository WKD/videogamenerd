import Foundation
import Testing
import GRDB
@testable import VGN

/// A scripted, no-network HLTB search for the bulk-model tests.
final class FakeHLTBSearch: HLTBSearching, @unchecked Sendable {
    private let byTitle: [String: [HLTBCandidate]]
    private let rejectTitles: Set<String>
    private let perCallDelay: TimeInterval
    private let lock = NSLock()
    private var _calls: [String] = []

    init(byTitle: [String: [HLTBCandidate]], rejectTitles: Set<String> = [], perCallDelay: TimeInterval = 0) {
        self.byTitle = byTitle
        self.rejectTitles = rejectTitles
        self.perCallDelay = perCallDelay
    }

    var calls: [String] { lock.withLock { _calls } }

    func search(title: String) async throws -> [HLTBCandidate] {
        lock.withLock { _calls.append(title) }
        if perCallDelay > 0 { try await Task.sleep(for: .seconds(perCallDelay)) }
        if rejectTitles.contains(title) {
            throw ImportError.rejected(ImportReject(
                source: HLTBSource.id, endpoint: "hltb/search", status: 403, reason: .authChallenge))
        }
        return byTitle[title] ?? []
    }
}

/// The bulk "Fetch Missing Time Estimates…" model (PLAN §5.3): progress, the summary
/// counts, the ambiguous list + one-by-one pick, stop-on-reject, and cancel.
@MainActor
@Suite(.serialized)
struct HLTBBulkFetchModelTests {

    private func seededStore(_ titles: [(Int64, String)]) async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            for (id, title) in titles {
                try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (?, ?, 1)",
                               arguments: [id, title])
            }
        }
        return LibraryStore(db)
    }

    private func confident(_ id: Int64, _ name: String) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, releaseYear: 2015, mainSeconds: 3600, mainExtraSeconds: 7200)
    }

    private func waitUntilDone(_ model: HLTBBulkFetchModel) async {
        for _ in 0..<2000 where model.phase == .running { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func fillsConfidentCountsNotFoundAndListsAmbiguous() async throws {
        let store = try await seededStore([(1, "Alpha"), (2, "Beta"), (3, "Gamma")])
        let fake = FakeHLTBSearch(byTitle: [
            "Alpha": [confident(10, "Alpha")],
            "Beta": [HLTBCandidate(id: 20, name: "Beta", releaseYear: 1996, mainSeconds: 3600),
                     HLTBCandidate(id: 21, name: "Beta", releaseYear: 2013, mainSeconds: 3600)],
            "Gamma": [],
        ])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake })
        model.start(gameIDs: [1, 2, 3])
        await waitUntilDone(model)

        #expect(model.phase == .finished)
        #expect(model.filled == 1)
        #expect(model.notFound == 1)
        #expect(model.ambiguous.count == 1)
        #expect(model.ambiguous.first?.gameID == 2)
        #expect(model.completed == 3)

        // The Alpha fill actually wrote the times.
        let detail = try await store.gameDetail(id: 1)
        #expect(detail?.ttbHastilyS == 3600)
        #expect(detail?.ttbSource == "hltb")
    }

    @Test(.timeLimit(.minutes(1)))
    func pickResolvesAnAmbiguousGame() async throws {
        let store = try await seededStore([(2, "Beta")])
        let fake = FakeHLTBSearch(byTitle: [
            "Beta": [HLTBCandidate(id: 20, name: "Beta", releaseYear: 1996, mainSeconds: 3600),
                     HLTBCandidate(id: 21, name: "Beta", releaseYear: 2013, mainSeconds: 3600)],
        ])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake })
        model.start(gameIDs: [2])
        await waitUntilDone(model)
        #expect(model.ambiguous.count == 1)

        model.pick(gameID: 2, candidate: HLTBCandidate(id: 21, name: "Beta", releaseYear: 2013, mainSeconds: 3600))
        for _ in 0..<2000 where !model.ambiguous.isEmpty { await Task.yield() }
        #expect(model.ambiguous.isEmpty)
        for _ in 0..<2000 where model.filled == 0 { await Task.yield() }
        #expect(model.filled == 1)
        let detail = try await store.gameDetail(id: 2)
        #expect(detail?.hltbID == 21)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsOnRejectAndMakesNoFurtherRequests() async throws {
        let store = try await seededStore([(1, "Alpha"), (2, "Reject"), (3, "Later")])
        let fake = FakeHLTBSearch(
            byTitle: ["Alpha": [confident(10, "Alpha")]],
            rejectTitles: ["Reject"])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake })
        model.start(gameIDs: [1, 2, 3])
        await waitUntilDone(model)

        #expect(model.phase == .stopped)
        #expect(model.stoppedReason != nil)
        #expect(model.stoppedNote == "VGN stopped and made no further requests.")
        // "Later" was never searched — the run stopped at the reject.
        #expect(!fake.calls.contains("Later"))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelStopsTheRun() async throws {
        let store = try await seededStore([(1, "A"), (2, "B"), (3, "C"), (4, "D")])
        let fake = FakeHLTBSearch(byTitle: [:], perCallDelay: 0.2)
        let model = HLTBBulkFetchModel(store: store, makeSearch: { fake })
        model.start(gameIDs: [1, 2, 3, 4])
        try await Task.sleep(for: .milliseconds(50))
        model.cancel()
        await waitUntilDone(model)
        #expect(model.phase == .stopped)
        #expect(model.completed < model.total)
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyScopeFinishesImmediately() async throws {
        let store = try await seededStore([])
        let model = HLTBBulkFetchModel(store: store, makeSearch: { FakeHLTBSearch(byTitle: [:]) })
        model.start(gameIDs: [])
        #expect(model.phase == .finished)
        #expect(model.summaryLine == "0 filled · 0 need your pick · 0 no HLTB entry")
    }
}

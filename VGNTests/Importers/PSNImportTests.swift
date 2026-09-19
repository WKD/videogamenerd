import Foundation
import Testing
@testable import VGN

/// The whole PSN importer end to end on the synthetic fixtures (PLAN §13): probe → full
/// per data set, the three-list merge, cache-first zero-request re-sync, and the DEBUG dev
/// cache. All offline.
@Suite struct PSNImportTests {

    private func makeImporter(_ db: AppDatabase, transport: HTTPTransport,
                              devCache: DevImportResponseCache? = nil) -> PSNImporter {
        PSNImporter(auth: seededPSNAuth(transport: transport), transport: transport,
                    cache: ImportResponseCacheStore(db),
                    pacing: ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: 40),
                    clock: RecordingImmediateClock(), wallClock: { importFixedNow },
                    devCache: devCache)
    }

    @Test func fullSyncProbesThenPagesEachDataSet() async throws {
        let db = try await TestDB.makeSeeded()
        let transport = try psnHappyPathTransport()
        let importer = makeImporter(db, transport: transport)
        let result = try await importer.fetch { _ in }

        // profile(1) + trophyTitles[probe+2 pages](3) + gamelist[probe+1](2)
        //   + purchases[probe+1](2) = 8 network requests (one trophy list, no PS3/Vita probe).
        #expect(result.fromNetwork == 8)
        #expect(transport.requestCount == 8)
        #expect(result.rows.count > 10)

        let byName = Dictionary(result.rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Synthetic Saga"]?.signals.contains(.played) == true)
        #expect(byName["Synthetic Saga"]?.signals.contains(.owned) == true)
        #expect(byName["Fake Fantasy X1"]?.subscription == .psPlus)
        #expect(byName["Retro Relic"]?.platform == "ps3")        // PS3/Vita from the trophy list
    }

    @Test func secondSyncMakesZeroNetworkRequests() async throws {
        let db = try await TestDB.makeSeeded()
        let transport = try psnHappyPathTransport()
        _ = try await makeImporter(db, transport: transport).fetch { _ in }
        let firstCount = transport.requestCount
        // A second sync against the same cache.
        let second = try await makeImporter(db, transport: transport).fetch { _ in }
        #expect(second.fromNetwork == 0)
        #expect(transport.requestCount == firstCount)   // no new network traffic
        #expect(second.fromCache > 0)
    }

    @Test func devCacheServesASyncWithAFreshRuntimeCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-psn-devcache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let devCache = DevImportResponseCache(root: root)

        // First sync populates the dev cache (and a runtime cache we then throw away).
        let dbA = try await TestDB.makeSeeded()
        let transportA = try psnHappyPathTransport()
        _ = try await makeImporter(dbA, transport: transportA, devCache: devCache).fetch { _ in }
        #expect(!devCache.indexEntries().isEmpty)

        // Second sync with a BRAND-NEW runtime cache but the same dev cache → zero network.
        let dbB = try await TestDB.makeSeeded()
        let transportB = try psnHappyPathTransport()
        let result = try await makeImporter(dbB, transport: transportB, devCache: devCache).fetch { _ in }
        #expect(result.fromNetwork == 0)
        #expect(transportB.requestCount == 0)
    }

    @Test func coordinatorStagesAndSummarises() async throws {
        let db = try await TestDB.makeSeeded()
        let transport = try psnHappyPathTransport()
        let importer = makeImporter(db, transport: transport)
        let coordinator = ImportSyncCoordinator(staging: ImportStagingStore(db))
        let result = try await coordinator.run(importer, matcher: NoMatchImportMatcher())
        #expect(result.summary.stagedTotal > 10)
        // The noise rows (pre-order, inactive, beta) land in Ignored.
        #expect(result.summary.ignoredCount >= 3)
        #expect(result.summary.source == ImportSourceID.psn)
    }
}

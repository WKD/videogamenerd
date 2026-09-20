import Foundation
import Testing
@testable import VGN

private extension EnrichmentStatus {
    var isOffline: Bool { if case .offline = self { return true } else { return false } }
}

/// Poll `condition` until true or `timeout` elapses.
private func waitUntil(timeout: TimeInterval, _ condition: () async throws -> Bool) async throws {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if try await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// End-to-end tests for the enrichment worker (PLAN §6.1/§9) over an in-memory DB
/// with a scripted transport — no network.
struct EnrichmentCoordinatorTests {

    @Test("Adding 25 games then draining fills metadata, cover and TTB, with batched requests")
    func endToEnd() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let ids = try await harness.addGames(25)

        await harness.coordinator.pump()

        for id in ids {
            let game = try #require(try await harness.game(id))
            #expect(game.summary?.isEmpty == false)
            #expect(game.coverFile != nil)
            #expect(game.ttbSource == "igdb")
            #expect(game.igdbCoverImageID != nil)
            #expect(game.ttbNormallyS == 7200)
        }
        // FTS finds an alt title (PLAN §5.2/§8).
        #expect(try await harness.ftsMatchCount("altbaphomet*") == 25)
        // Batching: one metadata request and one TTB request cover all 25 games.
        #expect(harness.transport.requestCount(urlContains: "/v4/games") == 1)
        #expect(harness.transport.requestCount(urlContains: "/v4/game_time_to_beats") == 1)
        #expect(harness.transport.requestCount(urlContains: "images.igdb.com") == 25)
        #expect(await harness.coordinator.currentStatus == .idle)
    }

    @Test("No credentials → idle quietly, then resumes when they appear")
    func noCredentialsThenResumes() async throws {
        let creds = MutableCreds(nil)
        let harness = try await EnrichmentHarness.make(creds: creds)
        defer { harness.cleanup() }
        let ids = try await harness.addGames(2)

        await harness.coordinator.pump()
        #expect(await harness.coordinator.currentStatus == .needsCredentials)
        #expect(try await harness.jobStore.countsOnce().isEmpty)      // nothing enqueued yet

        creds.set(IGDBCredentials(clientID: "cid", secret: "sec"))
        await harness.coordinator.credentialsDidChange()
        for id in ids {
            #expect(try #require(try await harness.game(id)).summary?.isEmpty == false)
        }
        #expect(await harness.coordinator.currentStatus == .idle)
    }

    @Test("429 → backoff → eventual success on the next drain")
    func backoffThenSuccess() async throws {
        let harness = try await EnrichmentHarness.make(
            backoff: EnrichmentBackoff(maxAttempts: 5, baseDelay: 60))
        defer { harness.cleanup() }
        let ids = try await harness.addGames(1)

        harness.transport.failAPI { HTTPStatusError(status: 429, body: Data(), retryAfter: nil) }
        await harness.coordinator.pump()

        let first = try #require(try await harness.game(ids[0]))
        #expect(first.summary == nil)                                // not filled
        #expect(await harness.coordinator.currentStatus.isOffline)
        let job = try #require(try await harness.jobStore.job(kind: .metadata, gameID: ids[0]))
        #expect(job.state == EnrichmentState.failed.rawValue)
        #expect(job.nextAttemptAt != nil)                            // scheduled retry (transient)

        // Recover the network, jump past the backoff, drain again.
        harness.transport.failAPI(nil)
        harness.date.advance(by: 10_000)
        await harness.coordinator.pump()

        let second = try #require(try await harness.game(ids[0]))
        #expect(second.summary?.isEmpty == false)
        #expect(second.coverFile != nil)
        #expect(await harness.coordinator.currentStatus == .idle)
    }

    @Test("Background enrichment never clobbers a user-set cover")
    func manualCoverNotClobbered() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        // A user-set cover + an image id that would otherwise let the fetch succeed.
        try await harness.library.updateMetadata(
            gameID: id, MetadataPatch(coverFile: "manual.png", igdbCoverImageID: "imgManual"))
        _ = try await harness.jobStore.enqueue(kind: .cover, gameID: id)

        await harness.coordinator.pump()
        #expect(try #require(try await harness.game(id)).coverFile == "manual.png")
    }

    @Test("A user-set cover (marker) survives even an explicit refresh; clearing it re-fetches")
    func userCoverSacredEndToEnd() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        // Enrichment fills metadata + a fetched cover first (the usual order).
        await harness.coordinator.pump()
        #expect(try #require(try await harness.game(id)).coverFile?.hasPrefix("\(id)-") == true)

        // The user then hand-picks a cover → `cover` is marked user-edited.
        try await harness.library.setUserCover(gameID: id, coverFile: "manual.png")
        #expect(try #require(try await harness.game(id)).userEdited.contains("cover"))

        // An explicit refresh must NOT clobber it (a plain updateMetadata cover would be).
        await harness.coordinator.refresh(gameID: id)
        #expect(try #require(try await harness.game(id)).coverFile == "manual.png")

        // "Remove custom cover": clears the file + marker, so a refresh re-fetches.
        try await harness.library.clearUserCover(gameID: id)
        let cleared = try #require(try await harness.game(id))
        #expect(cleared.coverFile == nil)
        #expect(!cleared.userEdited.contains("cover"))

        await harness.coordinator.refresh(gameID: id)
        let refetched = try #require(try await harness.game(id))
        #expect(refetched.coverFile != nil)
        #expect(refetched.coverFile != "manual.png")
        #expect(refetched.coverFile?.hasPrefix("\(id)-") == true)
    }

    @Test("refresh(gameID:) forces a re-fetch, overwriting user values")
    func refreshForces() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        await harness.coordinator.pump()
        #expect(try #require(try await harness.game(id)).coverFile != nil)

        try await harness.library.updateMetadata(
            gameID: id, MetadataPatch(summary: "USER EDIT", coverFile: "manual.png"))
        await harness.coordinator.refresh(gameID: id)

        let after = try #require(try await harness.game(id))
        #expect(after.summary?.contains("Summary of game") == true)   // overwritten
        #expect(after.coverFile != "manual.png")                      // re-fetched
        #expect(after.coverFile?.hasPrefix("\(id)-") == true)
    }

    @Test("A fresh catalogue-cache hit avoids the network")
    func cacheHitAvoidsNetwork() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1, firstIGDBID: 2000)[0]

        // Tag the blob with the metadata shape it satisfies, so the read-through serves it
        // (an untagged/older blob is a miss and would refetch).
        let json = CatalogCacheShapeJSON.tagged(ScriptedIGDBTransport.syntheticGame(id: 2000), shapes: [.search, .metadata])
        await harness.catalogCache.store(CatalogCacheEntry(igdbID: 2000, json: json, fetchedAt: harness.date.now))
        _ = try await harness.jobStore.enqueue(kind: .metadata, gameID: id)

        await harness.coordinator.pump()
        #expect(harness.transport.requestCount(urlContains: "/v4/games") == 0)   // served from cache
        #expect(try #require(try await harness.game(id)).summary?.isEmpty == false)
    }

    @Test("A stale catalogue-cache entry forces a refetch")
    func staleCacheForcesRefetch() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1, firstIGDBID: 3000)[0]

        let stale = harness.date.now.addingTimeInterval(-40 * 24 * 60 * 60)
        let json = CatalogCacheShapeJSON.tagged(ScriptedIGDBTransport.syntheticGame(id: 3000), shapes: [.search, .metadata])
        await harness.catalogCache.store(CatalogCacheEntry(igdbID: 3000, json: json, fetchedAt: stale))
        _ = try await harness.jobStore.enqueue(kind: .metadata, gameID: id)

        await harness.coordinator.pump()
        #expect(harness.transport.requestCount(urlContains: "/v4/games") == 1)   // stale → network
    }

    @Test("Cancellation mid-drain leaves no running rows after recovery")
    func cancellationLeavesNoRunning() async throws {
        let harness = try await EnrichmentHarness.make(imageDelay: 0.2)
        defer { harness.cleanup() }
        let ids = try await harness.addGames(12)

        let coordinator = harness.coordinator
        let task = Task { await coordinator.pump() }
        // Wait until cover downloads are in flight.
        try await waitUntil(timeout: 5) { try await harness.jobStore.countsOnce().running > 0 }
        task.cancel()
        _ = await task.value

        _ = try await harness.jobStore.recoverRunning()
        #expect(try await harness.jobStore.countsOnce().running == 0)

        // A fresh drain finishes the work with no leftover running rows.
        await harness.coordinator.pump()
        for id in ids { #expect(try #require(try await harness.game(id)).coverFile != nil) }
        #expect(try await harness.jobStore.countsOnce().running == 0)
    }

    @Test("Manual entries (no igdb_id) get no metadata/TTB job; cover only when searchable")
    func manualEntryPolicy() async throws {
        let library = try await TestDB.makeStore()
        // A manual game on PS4 (no libretro repo) — not searchable for a cover.
        let ps4 = try await library.addGame(GameDraft(title: "Homebrew", platformIDs: ["ps4"], owned: true)).gameID
        // A manual game on SNES (has a libretro repo) — a cover search is plausible.
        let snes = try await library.addGame(GameDraft(title: "Some ROM", platformIDs: ["snes"], owned: true)).gameID

        let jobStore = EnrichmentJobStore(library.database)
        try await jobStore.dbWriter.write { db in
            try EnrichmentCoordinator.enqueueMissingJobs(now: Date(), db: db)
        }
        // No igdb_id → no metadata or TTB jobs for either.
        #expect(try await jobStore.job(kind: .metadata, gameID: ps4) == nil)
        #expect(try await jobStore.job(kind: .timeToBeat, gameID: snes) == nil)
        // Cover: only the SNES game (libretro repo) is enqueued.
        #expect(try await jobStore.job(kind: .cover, gameID: ps4) == nil)
        #expect(try await jobStore.job(kind: .cover, gameID: snes) != nil)
    }
}

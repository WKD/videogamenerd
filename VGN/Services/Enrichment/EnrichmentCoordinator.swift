import Foundation
import GRDB

/// The background enrichment worker (PLAN §6.1/§9): "adding never waits on the
/// network". Games are inserted locally and instantly; this actor fills in
/// metadata, covers and time-to-beat afterwards, from a queue persisted in the DB
/// that resumes after relaunch and retries with backoff.
///
/// Behaviour:
///  - **Batched.** Metadata and TTB are batch IGDB endpoints, so jobs of one kind
///    are claimed together and resolved with a single request (request count ≪
///    game count). Covers run concurrently, capped at ``coverBatchSize`` (the
///    `CoverStore` caps downloads at 6 too).
///  - **Ordering by dependency.** A cover job is only claimed once the same game's
///    metadata job is `done` — the cover needs the IGDB image id + alt titles.
///  - **No credentials → idle quietly** (`.needsCredentials`); resumes on
///    ``credentialsDidChange()``.
///  - **A failing job never blocks the queue.** Transient (offline/5xx/429)
///    failures back off and the worker keeps going with other jobs.
///  - **Never clobbers user edits.** There is no `user_edited` column (see the
///    handoff), so the worker only fills a field that is currently empty — unless
///    a `refresh(gameID:)` explicitly forces a re-fetch.
///  - **Quit-safe.** A job interrupted mid-flight is left `running`; crash recovery
///    resets it to `pending` at the next start.
actor EnrichmentCoordinator {
    private let jobStore: EnrichmentJobStore
    private let libraryStore: LibraryStore
    private let catalogCache: CatalogCacheStore
    private let igdbClient: IGDBClient
    private let coverStore: CoverStore
    private let credentials: @Sendable () async -> IGDBCredentials?

    private let metadataBatchSize: Int
    private let ttbBatchSize: Int
    private let coverBatchSize: Int

    /// Games whose current enrichment pass should overwrite existing values
    /// (a `refresh(gameID:)`). Cleared when the drain finishes.
    private var forced: Set<Int64> = []
    private var isPaused = false

    private var statusContinuations: [UUID: AsyncStream<EnrichmentStatus>.Continuation] = [:]
    private(set) var currentStatus: EnrichmentStatus = .idle

    init(
        jobStore: EnrichmentJobStore,
        libraryStore: LibraryStore,
        catalogCache: CatalogCacheStore,
        igdbClient: IGDBClient,
        coverStore: CoverStore,
        credentials: @Sendable @escaping () async -> IGDBCredentials?,
        metadataBatchSize: Int = 40,
        ttbBatchSize: Int = 40,
        coverBatchSize: Int = 6
    ) {
        self.jobStore = jobStore
        self.libraryStore = libraryStore
        self.catalogCache = catalogCache
        self.igdbClient = igdbClient
        self.coverStore = coverStore
        self.credentials = credentials
        self.metadataBatchSize = metadataBatchSize
        self.ttbBatchSize = ttbBatchSize
        self.coverBatchSize = coverBatchSize
    }

    // MARK: - Status stream

    /// Observe the worker's status (PLAN §9). Replays the current status, then
    /// every transition. Multiple observers are supported.
    func statusUpdates() -> AsyncStream<EnrichmentStatus> {
        let (stream, continuation) = AsyncStream<EnrichmentStatus>.makeStream()
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.yield(currentStatus)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unregister(id) }
        }
        return stream
    }

    private func unregister(_ id: UUID) { statusContinuations[id] = nil }

    private func emit(_ status: EnrichmentStatus) {
        currentStatus = status
        for continuation in statusContinuations.values { continuation.yield(status) }
    }

    // MARK: - Public control surface (the app container calls these)

    /// App start-up: recover jobs a previous launch left `running`, scan for
    /// missing enrichment, then drain.
    func startup() async {
        _ = try? await jobStore.recoverRunning()
        await pump()
    }

    /// Scan + drain. Called on demand: after the Quick Add / import lanes insert
    /// games (they call ``notifyLibraryChanged()``), at start, and after a drain.
    func pump() async {
        guard !isPaused else { emit(.paused); return }
        guard await hasCredentials() else { emit(.needsCredentials); return }
        await enqueueMissing()
        await drain()
    }

    /// The UI / Quick Add lanes call this after inserting games.
    func notifyLibraryChanged() async { await pump() }

    /// Credentials appeared or changed — resume if we were idling on their absence.
    func credentialsDidChange() async { await pump() }

    /// Force a full re-fetch of everything for one game (the inspector's
    /// "Refresh metadata"). Overwrites existing values.
    func refresh(gameID: Int64) async {
        forced.insert(gameID)
        if let row = (try? await fetchRows([gameID]))?[gameID] {
            if row.igdbID != nil {
                _ = try? await jobStore.enqueue(kind: .metadata, gameID: gameID, reset: true)
                _ = try? await jobStore.enqueue(kind: .timeToBeat, gameID: gameID, reset: true)
            }
            _ = try? await jobStore.enqueue(kind: .cover, gameID: gameID, reset: true)
        }
        guard await hasCredentials() else { emit(.needsCredentials); return }
        await drain()
    }

    /// Re-arm every failed job and drain (the "retry failed" action).
    func retryFailed() async {
        _ = try? await jobStore.retryFailed()
        await pump()
    }

    /// Pause the worker (it finishes the batch in flight, then stops).
    func pause() { isPaused = true; emit(.paused) }

    /// Resume after a pause.
    func resume() async { isPaused = false; await pump() }

    // MARK: - Enqueue-missing scan

    /// Enqueue jobs for games that lack a field and have no job for it yet
    /// (PLAN §9). A game with no `igdb_id` (manual entry) gets **no** metadata/TTB
    /// job; it gets a **cover** job only when a title+platform search is plausible
    /// — i.e. it is on a platform with a libretro-thumbnails repo (the only cover
    /// source that works from a title alone). IGDB games always get all three.
    func enqueueMissing() async {
        let stamp = jobStore.now()
        try? await jobStore.dbWriter.write { db in
            try Self.enqueueMissingJobs(now: stamp, db: db)
        }
    }

    static func enqueueMissingJobs(now: Date, db: Database) throws {
        // metadata: igdb games whose summary was never filled.
        try db.execute(sql: """
            INSERT INTO enrichment_jobs (kind, game_id, state, attempts, next_attempt_at, created_at)
            SELECT 'metadata', g.id, 'pending', 0, :now, :now FROM games g
            WHERE g.igdb_id IS NOT NULL AND g.summary IS NULL
              AND NOT EXISTS (SELECT 1 FROM enrichment_jobs j WHERE j.game_id = g.id AND j.kind = 'metadata')
            ON CONFLICT(kind, game_id) DO NOTHING
            """, arguments: ["now": now])

        // timeToBeat: igdb games whose ttb_source was never set ('igdb' marks tried).
        try db.execute(sql: """
            INSERT INTO enrichment_jobs (kind, game_id, state, attempts, next_attempt_at, created_at)
            SELECT 'timeToBeat', g.id, 'pending', 0, :now, :now FROM games g
            WHERE g.igdb_id IS NOT NULL AND g.ttb_source IS NULL
              AND NOT EXISTS (SELECT 1 FROM enrichment_jobs j WHERE j.game_id = g.id AND j.kind = 'timeToBeat')
            ON CONFLICT(kind, game_id) DO NOTHING
            """, arguments: ["now": now])

        // cover: any game without a cover file, if it is searchable — an igdb game
        // (has key art) or a game on a platform with a libretro repo.
        try db.execute(sql: """
            INSERT INTO enrichment_jobs (kind, game_id, state, attempts, next_attempt_at, created_at)
            SELECT 'cover', g.id, 'pending', 0, :now, :now FROM games g
            WHERE g.cover_file IS NULL
              AND (
                    g.igdb_id IS NOT NULL
                 OR EXISTS (
                      SELECT 1 FROM (
                        SELECT platform_id AS pid FROM game_platforms WHERE game_id = g.id
                        UNION
                        SELECT p.platform_id FROM products p
                          JOIN product_games pg ON pg.product_id = p.id WHERE pg.game_id = g.id
                      ) s JOIN platforms pl ON pl.id = s.pid WHERE pl.libretro_repo IS NOT NULL)
                  )
              AND NOT EXISTS (SELECT 1 FROM enrichment_jobs j WHERE j.game_id = g.id AND j.kind = 'cover')
            ON CONFLICT(kind, game_id) DO NOTHING
            """, arguments: ["now": now])
    }

    // MARK: - Drain loop

    private func drain() async {
        emit(.running(remaining: (try? await jobStore.countsOnce().remaining) ?? 0))
        while !Task.isCancelled && !isPaused {
            let didMeta = await processMetadataBatch()
            let didTTB = await processTimeToBeatBatch()
            let didCover = await processCoverBatch()
            if !(didMeta || didTTB || didCover) { break }
            emit(.running(remaining: (try? await jobStore.countsOnce().remaining) ?? 0))
        }
        forced.removeAll()
        if isPaused { emit(.paused); return }
        if Task.isCancelled { return }
        let retryAt = (try? await jobStore.earliestScheduledRetry()) ?? nil
        emit(retryAt == nil ? .idle : .offline(retryAt: retryAt))
    }

    // MARK: - Metadata job

    private func processMetadataBatch() async -> Bool {
        let jobs = (try? await jobStore.claimBatch(kind: .metadata, limit: metadataBatchSize)) ?? []
        guard !jobs.isEmpty else { return false }

        let rows = (try? await fetchRows(jobs.map(\.gameID))) ?? [:]
        let neededIGDBIDs = Set(jobs.compactMap { rows[$0.gameID]?.igdbID })

        // Fresh catalogue-cache hits avoid the network (PLAN §4).
        let cached = await catalogCache.entries(forIDs: Array(neededIGDBIDs))
        var metaByIGDB: [Int64: IGDBGameMetadata] = [:]
        for (id, entry) in cached {
            if let meta = igdbClient.metadata(fromCachedGameJSON: entry.json) { metaByIGDB[id] = meta }
        }
        let toFetch = neededIGDBIDs.subtracting(metaByIGDB.keys)

        var fetchError: Error?
        if !toFetch.isEmpty {
            do {
                let fetched = try await igdbClient.games(ids: Array(toFetch))   // write-through cache inside the client
                for meta in fetched { metaByIGDB[meta.id] = meta }
            } catch {
                fetchError = error
            }
        }

        for job in jobs {
            guard let jobID = job.id else { continue }
            guard let row = rows[job.gameID], let igdbID = row.igdbID else {
                try? await jobStore.complete(jobID: jobID); continue
            }
            if let meta = metaByIGDB[igdbID] {
                let full = EnrichmentMetadataMapping.fullPatch(from: meta)
                let patch = guardMetadata(full, row: row, force: forced.contains(job.gameID))
                try? await libraryStore.updateMetadata(gameID: job.gameID, patch)
                try? await jobStore.complete(jobID: jobID)
            } else if let error = fetchError, toFetch.contains(igdbID) {
                try? await jobStore.fail(jobID: jobID, error: "\(error)", transient: isRetryable(error))
            } else {
                // IGDB returned nothing for this id — a normal outcome, not a failure.
                try? await jobStore.complete(jobID: jobID)
            }
        }
        return true
    }

    // MARK: - Time-to-beat job

    private func processTimeToBeatBatch() async -> Bool {
        let jobs = (try? await jobStore.claimBatch(kind: .timeToBeat, limit: ttbBatchSize)) ?? []
        guard !jobs.isEmpty else { return false }

        let rows = (try? await fetchRows(jobs.map(\.gameID))) ?? [:]
        let igdbIDs = Array(Set(jobs.compactMap { rows[$0.gameID]?.igdbID }))

        var ttbByIGDB: [Int64: IGDBTimeToBeat] = [:]
        var fetchError: Error?
        if !igdbIDs.isEmpty {
            do {
                for row in try await igdbClient.timeToBeat(gameIDs: igdbIDs) { ttbByIGDB[row.gameID] = row }
            } catch {
                fetchError = error
            }
        }

        for job in jobs {
            guard let jobID = job.id else { continue }
            guard let row = rows[job.gameID], let igdbID = row.igdbID else {
                try? await jobStore.complete(jobID: jobID); continue
            }
            if let error = fetchError {
                try? await jobStore.fail(jobID: jobID, error: "\(error)", transient: isRetryable(error))
                continue
            }
            // Only fill when empty (don't clobber a manual/PSN value), unless force.
            // 'igdb' source marks "tried" even when there is no data, so the game is
            // not re-enqueued forever.
            if forced.contains(job.gameID) || row.ttbSource == nil {
                let ttb = ttbByIGDB[igdbID]
                let patch = MetadataPatch(
                    ttbHastilyS: ttb?.hastily,
                    ttbNormallyS: ttb?.normally,
                    ttbCompletelyS: ttb?.completely,
                    ttbSource: "igdb"
                )
                try? await libraryStore.updateMetadata(gameID: job.gameID, patch)
            }
            try? await jobStore.complete(jobID: jobID)
        }
        return true
    }

    // MARK: - Cover job

    private func processCoverBatch() async -> Bool {
        // Claim only covers whose metadata is done (dependency, not luck).
        let jobs = (try? await jobStore.claimBatch(
            kind: .cover, limit: coverBatchSize, requireMetadataDone: true)) ?? []
        guard !jobs.isEmpty else { return false }

        let rows = (try? await fetchRows(jobs.map(\.gameID))) ?? [:]
        let store = coverStore
        let library = libraryStore
        let queue = jobStore

        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                guard let jobID = job.id, let row = rows[job.gameID] else { continue }
                let force = forced.contains(job.gameID)
                group.addTask {
                    let query = CoverQuery(
                        title: row.title,
                        alternativeNames: row.altTitles,
                        platformSlugs: row.platformSlugs,
                        igdbCoverImageID: row.igdbCoverImageID
                    )
                    do {
                        let stored = try await store.fetchAndStoreCover(for: query, gameID: row.id)
                        if let stored {
                            // Don't clobber a user-set cover (only fill when empty, unless force).
                            let current: String? = (try? await library.dbReader.read { db in
                                try String.fetchOne(db, sql: "SELECT cover_file FROM games WHERE id = ?",
                                                    arguments: [row.id])
                            }) ?? nil
                            if force || current == nil {
                                try await library.updateMetadata(gameID: row.id, MetadataPatch(coverFile: stored.coverFile))
                            }
                        }
                        // A miss (nil) is a normal outcome (respects the negative cache).
                        try await queue.complete(jobID: jobID)
                    } catch is CancellationError {
                        // Leave the job 'running' — crash recovery resets it on next start.
                    } catch {
                        try? await queue.fail(jobID: jobID, error: "\(error)", transient: isRetryable(error))
                    }
                }
            }
        }
        return true
    }

    // MARK: - Helpers

    private func hasCredentials() async -> Bool {
        await credentials() != nil
    }

    /// Never rename/overwrite a value a user (or a prior fill) already set: keep a
    /// full patch field only when the current DB value is empty, unless `force`.
    private func guardMetadata(_ full: MetadataPatch, row: EnrichmentGameRow, force: Bool) -> MetadataPatch {
        if force { return full }
        var patch = full
        patch.title = nil                                   // never rename via background enrichment
        if row.summary?.isEmpty == false { patch.summary = nil }
        if row.year != nil { patch.year = nil }
        if row.releaseDate != nil { patch.releaseDate = nil }
        if !row.altTitles.isEmpty { patch.altTitles = nil }
        if row.hasGenres { patch.genres = nil }
        if row.igdbCoverImageID != nil { patch.igdbCoverImageID = nil }
        return patch
    }

    /// Slim per-game rows for building queries and applying the not-clobber guard.
    private func fetchRows(_ gameIDs: [Int64]) async throws -> [Int64: EnrichmentGameRow] {
        guard !gameIDs.isEmpty else { return [:] }
        return try await libraryStore.dbReader.read { db in
            let placeholders = gameIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM games WHERE id IN (\(placeholders))",
                arguments: StatementArguments(gameIDs))
            var out: [Int64: EnrichmentGameRow] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                let altRaw: String = row["alt_titles"]
                let hasGenres = (try Int.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM game_genres WHERE game_id = ?)",
                    arguments: [id]) ?? 0) == 1
                let slugs = try String.fetchAll(db, sql: """
                    SELECT DISTINCT pid FROM (
                      SELECT platform_id AS pid FROM game_platforms WHERE game_id = ?1
                      UNION
                      SELECT p.platform_id FROM products p JOIN product_games pg ON pg.product_id = p.id
                      WHERE pg.game_id = ?1
                    )
                    """, arguments: [id])
                out[id] = EnrichmentGameRow(
                    id: id,
                    igdbID: row["igdb_id"],
                    title: row["title"],
                    altTitles: altRaw.split(separator: "\n").map(String.init),
                    summary: row["summary"],
                    year: row["year"],
                    releaseDate: row["release_date"],
                    hasGenres: hasGenres,
                    coverFile: row["cover_file"],
                    igdbCoverImageID: row["igdb_cover_image_id"],
                    ttbSource: row["ttb_source"],
                    platformSlugs: slugs
                )
            }
            return out
        }
    }
}

/// Slim per-game snapshot the coordinator reads to build IGDB / cover queries and
/// to apply the "don't clobber user edits" guard.
struct EnrichmentGameRow: Sendable, Equatable {
    var id: Int64
    var igdbID: Int64?
    var title: String
    var altTitles: [String]
    var summary: String?
    var year: Int?
    var releaseDate: Date?
    var hasGenres: Bool
    var coverFile: String?
    var igdbCoverImageID: String?
    var ttbSource: String?
    var platformSlugs: [String]
}

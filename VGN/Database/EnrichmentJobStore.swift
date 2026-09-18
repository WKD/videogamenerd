import Foundation
import GRDB

/// Exponential-with-cap-and-jitter backoff schedule for a failed enrichment job
/// (PLAN §9: "retries with backoff"). `attempt` is 1-based (the attempt that just
/// failed). `jitter` is a value in `0...1` (injected so tests are deterministic).
struct EnrichmentBackoff: Sendable, Equatable {
    /// After this many failed attempts a *transient* failure becomes permanent —
    /// the job stays `failed`, is never retried automatically, but can be retried
    /// on demand (PLAN §9).
    var maxAttempts: Int
    var baseDelay: TimeInterval
    var factor: Double
    var maxDelay: TimeInterval
    /// Multiplier range applied to each computed delay (full jitter lives here).
    var jitterRange: ClosedRange<Double>

    init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 30,
        factor: Double = 2,
        maxDelay: TimeInterval = 60 * 60,
        jitterRange: ClosedRange<Double> = 0.7...1.3
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.factor = factor
        self.maxDelay = maxDelay
        self.jitterRange = jitterRange
    }

    /// Delay before the retry that follows failed `attempt`.
    func delay(afterAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = baseDelay * pow(factor, exponent)
        let capped = min(raw, maxDelay)
        let clampedJitter = min(max(jitter, 0), 1)
        let factor = jitterRange.lowerBound + (jitterRange.upperBound - jitterRange.lowerBound) * clampedJitter
        return capped * factor
    }
}

/// Live counts of the enrichment queue by state — feeds the UI ("Fetching
/// metadata · 12 left", PLAN §9).
struct EnrichmentCounts: Sendable, Equatable {
    var pending: Int = 0
    var running: Int = 0
    var failed: Int = 0
    var done: Int = 0

    /// Work still to do (what the UI shows as "N left").
    var remaining: Int { pending + running }
    var total: Int { pending + running + failed + done }
    var isEmpty: Bool { total == 0 }
}

/// The persisted background job queue over `enrichment_jobs` (PLAN §9). A thin,
/// `Sendable` value over ``AppDatabase`` (same shape as ``LibraryStore``).
///
/// Design notes:
///  - **Idempotent enqueue** on `(kind, game_id)` via the table's UNIQUE index.
///    A re-enqueue only resets a `done`/`failed` row when `reset` is asked for.
///  - **Atomic claim.** `claimBatch` runs a `SELECT … then UPDATE … running` inside
///    one write transaction; GRDB serialises writers, so two claimers can never
///    take the same job.
///  - **`next_attempt_at` is the schedule.** A claimable job has a non-NULL
///    `next_attempt_at <= now`. A *permanent* failure sets it to NULL, so the job
///    is never picked up automatically but `retryFailed` (which stamps it `now`)
///    brings it back. Enqueue always stamps `now`, so a fresh `pending` job is due
///    immediately.
///  - **Crash recovery.** `recoverRunning` resets jobs a previous launch left
///    `running` back to `pending` at start-up.
struct EnrichmentJobStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }
    var dbReader: any DatabaseReader { database.dbWriter }

    let backoff: EnrichmentBackoff
    /// Wall-clock source (injected so tests drive the backoff schedule by hand).
    let now: @Sendable () -> Date
    /// Jitter source in `0...1` (injected for deterministic backoff tests).
    let jitter: @Sendable () -> Double

    init(
        _ database: AppDatabase,
        backoff: EnrichmentBackoff = EnrichmentBackoff(),
        now: @Sendable @escaping () -> Date = { Date() },
        jitter: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.database = database
        self.backoff = backoff
        self.now = now
        self.jitter = jitter
    }

    // MARK: - Enqueue

    /// Enqueue one job. Idempotent on `(kind, game_id)`: an existing live job is
    /// left untouched unless `reset` is set, which re-arms a `done`/`failed` row
    /// (a `running` row is never disturbed). Returns `true` when a row was
    /// inserted or reset.
    @discardableResult
    func enqueue(kind: EnrichmentKind, gameID: Int64, reset: Bool = false) async throws -> Bool {
        let stamp = now()
        return try await dbWriter.write { db in
            try Self.enqueueRow(kind: kind, gameID: gameID, reset: reset, now: stamp, db: db)
        }
    }

    /// Enqueue many jobs in one transaction. Returns the number of rows inserted
    /// or reset.
    @discardableResult
    func enqueue(_ requests: [(kind: EnrichmentKind, gameID: Int64)], reset: Bool = false) async throws -> Int {
        let stamp = now()
        return try await dbWriter.write { db in
            var changed = 0
            for request in requests {
                if try Self.enqueueRow(kind: request.kind, gameID: request.gameID,
                                       reset: reset, now: stamp, db: db) {
                    changed += 1
                }
            }
            return changed
        }
    }

    /// Returns `true` when a new row was inserted or an existing `done`/`failed`
    /// row was re-armed. A live (`pending`/`running`) job, or a `reset: false`
    /// re-enqueue, is a no-op → `false`. (Done explicitly rather than via
    /// `ON CONFLICT DO UPDATE` because SQLite counts a no-op upsert as a change,
    /// which would make idempotent enqueues report `true`.)
    static func enqueueRow(
        kind: EnrichmentKind, gameID: Int64, reset: Bool, now: Date, db: Database
    ) throws -> Bool {
        let existing = try EnrichmentJobRecord
            .filter(sql: "kind = ? AND game_id = ?", arguments: [kind.rawValue, gameID])
            .fetchOne(db)
        if let existing {
            let resettable = existing.state == EnrichmentState.done.rawValue
                || existing.state == EnrichmentState.failed.rawValue
            guard reset, resettable, let id = existing.id else { return false }
            try db.execute(sql: """
                UPDATE enrichment_jobs SET state = 'pending', attempts = 0, next_attempt_at = ?, last_error = NULL
                WHERE id = ?
                """, arguments: [now, id])
            return true
        }
        try db.execute(sql: """
            INSERT INTO enrichment_jobs (kind, game_id, state, attempts, next_attempt_at, last_error, created_at)
            VALUES (?, ?, 'pending', 0, ?, NULL, ?)
            """, arguments: [kind.rawValue, gameID, now, now])
        return true
    }

    // MARK: - Claim

    /// Atomically claim up to `limit` due jobs of `kind`, marking them `running`.
    /// Due = `pending`/`failed` with a non-NULL `next_attempt_at <= now`, oldest
    /// first. When `requireMetadataDone` is set (used for `cover` jobs), a job is
    /// skipped while the same game still has a non-`done` `metadata` job — that is
    /// how "metadata before cover" is enforced by dependency, not by luck.
    func claimBatch(
        kind: EnrichmentKind, limit: Int, requireMetadataDone: Bool = false
    ) async throws -> [EnrichmentJobRecord] {
        let stamp = now()
        return try await dbWriter.write { db in
            var sql = """
                SELECT * FROM enrichment_jobs
                WHERE kind = :kind AND state IN ('pending','failed')
                  AND next_attempt_at IS NOT NULL AND next_attempt_at <= :now
                """
            if requireMetadataDone {
                sql += """
                 AND NOT EXISTS (
                    SELECT 1 FROM enrichment_jobs m
                    WHERE m.game_id = enrichment_jobs.game_id
                      AND m.kind = 'metadata' AND m.state <> 'done')
                """
            }
            sql += " ORDER BY next_attempt_at ASC, id ASC LIMIT :limit"

            var rows = try EnrichmentJobRecord.fetchAll(
                db, sql: sql,
                arguments: ["kind": kind.rawValue, "now": stamp, "limit": limit]
            )
            guard !rows.isEmpty else { return [] }
            let ids = rows.compactMap(\.id)
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE enrichment_jobs SET state = 'running' WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            for index in rows.indices { rows[index].state = EnrichmentState.running.rawValue }
            return rows
        }
    }

    // MARK: - Complete / fail

    /// Mark a job `done` and clear any recorded error.
    func complete(jobID: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE enrichment_jobs SET state = 'done', last_error = NULL WHERE id = ?",
                           arguments: [jobID])
        }
    }

    /// Record a failure. A `transient` failure is rescheduled with backoff until
    /// `maxAttempts`, after which — like any non-transient failure — it becomes
    /// permanent (`failed`, `next_attempt_at = NULL`): never retried automatically,
    /// retryable on demand.
    func fail(jobID: Int64, error: String, transient: Bool) async throws {
        let stamp = now()
        let jitterValue = jitter()
        try await dbWriter.write { db in
            guard var job = try EnrichmentJobRecord.fetchOne(db, key: jobID) else { return }
            job.attempts += 1
            job.lastError = String(error.prefix(500))
            job.state = EnrichmentState.failed.rawValue
            if transient && job.attempts < backoff.maxAttempts {
                let delay = backoff.delay(afterAttempt: job.attempts, jitter: jitterValue)
                job.nextAttemptAt = stamp.addingTimeInterval(delay)
            } else {
                job.nextAttemptAt = nil   // permanent
            }
            try job.update(db)
        }
    }

    // MARK: - Crash recovery / retry

    /// Reset jobs a previous launch left `running` back to `pending`, due now
    /// (PLAN §9 "resumes after relaunch"). Returns how many were recovered.
    @discardableResult
    func recoverRunning() async throws -> Int {
        let stamp = now()
        return try await dbWriter.write { db in
            try db.execute(sql: "UPDATE enrichment_jobs SET state = 'pending', next_attempt_at = ? WHERE state = 'running'",
                           arguments: [stamp])
            return db.changesCount
        }
    }

    /// Re-arm every `failed` job (or just one kind) for an immediate retry,
    /// restarting its backoff. Returns how many were re-armed.
    @discardableResult
    func retryFailed(kind: EnrichmentKind? = nil) async throws -> Int {
        let stamp = now()
        return try await dbWriter.write { db in
            if let kind {
                try db.execute(sql: """
                    UPDATE enrichment_jobs SET state = 'pending', next_attempt_at = ?, attempts = 0, last_error = NULL
                    WHERE state = 'failed' AND kind = ?
                    """, arguments: [stamp, kind.rawValue])
            } else {
                try db.execute(sql: """
                    UPDATE enrichment_jobs SET state = 'pending', next_attempt_at = ?, attempts = 0, last_error = NULL
                    WHERE state = 'failed'
                    """, arguments: [stamp])
            }
            return db.changesCount
        }
    }

    /// Re-arm the failed jobs for one game (the inspector's per-game retry).
    @discardableResult
    func retryFailed(gameID: Int64) async throws -> Int {
        let stamp = now()
        return try await dbWriter.write { db in
            try db.execute(sql: """
                UPDATE enrichment_jobs SET state = 'pending', next_attempt_at = ?, attempts = 0, last_error = NULL
                WHERE state = 'failed' AND game_id = ?
                """, arguments: [stamp, gameID])
            return db.changesCount
        }
    }

    // MARK: - Maintenance

    /// Delete `done` jobs (PLAN §9 housekeeping). Kept on-demand, not automatic:
    /// a retained `done` row is what stops a completed game being re-enqueued.
    @discardableResult
    func purgeDone() async throws -> Int {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM enrichment_jobs WHERE state = 'done'")
            return db.changesCount
        }
    }

    // MARK: - Reads / observation

    /// One-shot job for a `(kind, game)` — for tests and the inspector.
    func job(kind: EnrichmentKind, gameID: Int64) async throws -> EnrichmentJobRecord? {
        try await dbReader.read { db in
            try EnrichmentJobRecord
                .filter(sql: "kind = ? AND game_id = ?", arguments: [kind.rawValue, gameID])
                .fetchOne(db)
        }
    }

    /// Live per-state counts (PLAN §9 progress UI).
    func counts() -> AsyncValueObservation<EnrichmentCounts> {
        ValueObservation.tracking { db in try Self.fetchCounts(db) }
            .values(in: dbReader)
    }

    func countsOnce() async throws -> EnrichmentCounts {
        try await dbReader.read { db in try Self.fetchCounts(db) }
    }

    static func fetchCounts(_ db: Database) throws -> EnrichmentCounts {
        var counts = EnrichmentCounts()
        let rows = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM enrichment_jobs GROUP BY state")
        for row in rows {
            let n: Int = row["n"]
            switch EnrichmentState(rawValue: row["state"]) {
            case .pending: counts.pending = n
            case .running: counts.running = n
            case .failed: counts.failed = n
            case .done: counts.done = n
            case .none: break
            }
        }
        return counts
    }

    /// The soonest a scheduled (transient) retry becomes due, or `nil` when no job
    /// is waiting on a backoff timer. Used to drive the `.offline(retryAt:)` status.
    func earliestScheduledRetry() async throws -> Date? {
        try await dbReader.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(next_attempt_at) FROM enrichment_jobs
                WHERE state = 'failed' AND next_attempt_at IS NOT NULL
                """)
        }
    }
}

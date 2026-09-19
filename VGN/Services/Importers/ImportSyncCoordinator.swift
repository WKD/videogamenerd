import Foundation

/// One matched title, for pre-ticking the review sheet (PLAN §14.3 — confident
/// matches are pre-ticked, the rest wait under *New*).
struct ImportMatchResult: Sendable, Equatable {
    var externalID: String
    var name: String
    var outcome: ScanMatchOutcome
}

/// The outcome of one sync: the summary line data, the per-row match proposals, and
/// the fetched staging rows (carrying the transient mapping info — release year, Mac
/// availability, Linux-only note — the review sheet needs, PLAN §14.3).
struct ImportSyncResult: Sendable, Equatable {
    var summary: ImportSyncSummary
    var matches: [ImportMatchResult]
    var rows: [ImportStagingRow]

    init(summary: ImportSyncSummary, matches: [ImportMatchResult], rows: [ImportStagingRow] = []) {
        self.summary = summary
        self.matches = matches
        self.rows = rows
    }
}

/// Runs one sync for any ``LibraryImporter`` (PLAN §14.4): cache-first fetch → staging
/// upsert (decisions preserved) → matching through the shared ladder (behind
/// ``ImportMatcher`` so tests fake it) → summary. Progress is reported as plain
/// ``ImportProgress`` values, either through a callback (``run(_:matcher:onProgress:)``)
/// or an `AsyncStream` (``stream(for:matcher:)``).
///
/// On any bogus response the importer throws ``ImportError/rejected(_:)`` and this
/// rethrows it untouched — the sync stops, the reject is already recorded, and the last
/// good cache is left intact (PLAN §14.5). The coordinator never retries or tries a
/// variant.
struct ImportSyncCoordinator: Sendable {
    let staging: ImportStagingStore

    init(staging: ImportStagingStore) { self.staging = staging }

    /// Run a sync, reporting progress through `onProgress`.
    func run(_ importer: any LibraryImporter,
             matcher: any ImportMatcher,
             onProgress: @Sendable @escaping (ImportProgress) -> Void = { _ in }) async throws -> ImportSyncResult {
        // 1. Fetch (cache-first, budgeted, validated). Throws on any reject.
        let fetched = try await importer.fetch(progress: onProgress)

        // 2. Stage (decisions preserved on re-sync).
        onProgress(ImportProgress(phase: .staging, detail: "Saving \(fetched.rows.count) titles"))
        try await staging.upsert(fetched.rows)

        // 3. Match every *New* row through the ladder (fake in tests).
        let rowsByExternalID = Dictionary(uniqueKeysWithValues: fetched.rows.map { ($0.externalID, $0) })
        let titles = try await staging.titles(source: importer.source)
        let toMatch = titles.filter { $0.bucket == .new }
        var matches: [ImportMatchResult] = []
        for (index, title) in toMatch.enumerated() {
            onProgress(ImportProgress(phase: .matching, completed: index, total: toMatch.count,
                                      detail: title.name))
            let row = rowsByExternalID[title.externalID]
            // A file importer matches a cleaned title (`matchTitle`) while `name` keeps
            // the noisy original for display (PLAN §5.5); GOG leaves `matchTitle` nil.
            let request = ImportMatchRequest(
                title: row?.matchTitle ?? title.name,
                platformSlug: title.platform, releaseYear: row?.releaseYear)
            let outcome = try await matcher.match(request)
            matches.append(ImportMatchResult(externalID: title.externalID, name: title.name, outcome: outcome))
        }

        // 4. Summary.
        let buckets = Dictionary(grouping: titles, by: \.bucket)
        let summary = ImportSyncSummary(
            source: importer.source,
            fromCache: fetched.fromCache,
            fromNetwork: fetched.fromNetwork,
            stagedTotal: titles.count,
            newCount: buckets[.new]?.count ?? 0,
            alreadyMatchedCount: buckets[.alreadyMatched]?.count ?? 0,
            ignoredCount: buckets[.ignored]?.count ?? 0,
            budgetUsed: fetched.budgetUsed,
            rejects: [],
            ownedGap: fetched.ownedGap)
        onProgress(ImportProgress(phase: .finished))
        return ImportSyncResult(summary: summary, matches: matches, rows: fetched.rows)
    }

    /// The same sync as an `AsyncStream` of progress values; the final ``ImportSyncResult``
    /// (or the thrown error) is delivered through `completion`.
    func stream(for importer: any LibraryImporter,
                matcher: any ImportMatcher,
                completion: @Sendable @escaping (Result<ImportSyncResult, Error>) -> Void) -> AsyncStream<ImportProgress> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let result = try await run(importer, matcher: matcher) { progress in
                        continuation.yield(progress)
                    }
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

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
    /// **(The Vault, PLAN §16)** PS Plus claims the PSN fetch vaulted, carried through so the
    /// presenter upserts them into `rom_catalog`. Empty for every other source.
    var vaultEntries: [RomCatalogEntry]
    /// Every external id currently vaulted (for removing claims that vanished / crossed the gate).
    var vaultPresentIDs: Set<String>
    /// **(Bundles, PLAN §5.1)** external id → the bundle expansion resolved during matching
    /// (title + member drafts), for every *New* row whose best match is an IGDB bundle/pack.
    /// The review sheet commits these as compilations. Empty when no expander ran (PSN, no
    /// IGDB) or nothing matched a bundle.
    var bundleExpansions: [String: ImportBundleExpansion]

    init(summary: ImportSyncSummary, matches: [ImportMatchResult], rows: [ImportStagingRow] = [],
         vaultEntries: [RomCatalogEntry] = [], vaultPresentIDs: Set<String> = [],
         bundleExpansions: [String: ImportBundleExpansion] = [:]) {
        self.summary = summary
        self.matches = matches
        self.rows = rows
        self.vaultEntries = vaultEntries
        self.vaultPresentIDs = vaultPresentIDs
        self.bundleExpansions = bundleExpansions
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

    /// How long an *attempted, no match* outcome is trusted before a later sync re-queries it
    /// (PLAN §5.1). A matched outcome is trusted indefinitely (only "Re-match" re-queries it).
    static let noMatchTTL: TimeInterval = 30 * 24 * 60 * 60

    /// Whether a persisted attempt can be reused (skip the IGDB query, restore the proposals):
    /// a matched attempt always, a no-match one only while it is younger than the TTL (PLAN §5.1).
    static func canReuse(_ attempt: ImportStagingStore.PersistedAttempt, now: Date,
                         reQueryNoMatchAfter: TimeInterval) -> Bool {
        if attempt.match != nil { return true }
        return now.timeIntervalSince(attempt.attemptedAt) < reQueryNoMatchAfter
    }

    /// Run a sync, reporting progress through `onProgress`. When a `bundleExpander` is
    /// supplied, every *New* row whose best match is an IGDB bundle/pack has its member
    /// games fetched here (still in the matching phase, on the shared IGDB pipeline —
    /// never at commit time on the main actor) so the review sheet can commit it as a
    /// compilation (PLAN §5.1). Nil ⇒ today's behaviour (a bundle commits as a single).
    func run(_ importer: any LibraryImporter,
             matcher: any ImportMatcher,
             bundleExpander: (any ImportBundleExpanding)? = nil,
             now: Date = Date(),
             reQueryNoMatchAfter: TimeInterval = Self.noMatchTTL,
             onProgress: @Sendable @escaping (ImportProgress) -> Void = { _ in }) async throws -> ImportSyncResult {
        // 1. Fetch (cache-first, budgeted, validated). Throws on any reject.
        let fetched = try await importer.fetch(progress: onProgress)

        // 2. Stage (decisions preserved on re-sync).
        onProgress(ImportProgress(phase: .staging, detail: "Saving \(fetched.rows.count) titles"))
        try await staging.upsert(fetched.rows)

        // 3. Match every *New* row through the ladder (fake in tests) — resuming from the
        // persisted per-title outcomes (PLAN §5.1): a title already attracted (matched, or
        // no-match within the TTL) is restored from `match_json` instead of re-queried, so a
        // cancelled-then-restarted or a second sync only hits IGDB for never-attempted titles
        // and stale no-match ones (or on an explicit per-row "Re-match" that cleared the mark).
        let rowsByExternalID = Dictionary(uniqueKeysWithValues: fetched.rows.map { ($0.externalID, $0) })
        let titles = try await staging.titles(source: importer.source)
        let attempts = try await staging.persistedAttempts(source: importer.source)
        let toMatch = titles.filter { $0.bucket == .new }

        // Split into titles to (re)query and titles to restore from the persisted attempt.
        var queryTitles: [ImportStagedTitle] = []
        var matches: [ImportMatchResult] = []
        var bundleExpansions: [String: ImportBundleExpansion] = [:]
        for title in toMatch {
            if let attempt = attempts[title.externalID],
               Self.canReuse(attempt, now: now, reQueryNoMatchAfter: reQueryNoMatchAfter) {
                let outcome = attempt.match?.outcome
                    ?? ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
                matches.append(ImportMatchResult(externalID: title.externalID, name: title.name, outcome: outcome))
                if let bundle = attempt.match?.bundle { bundleExpansions[title.externalID] = bundle }
            } else {
                queryTitles.append(title)
            }
        }
        let reusedCount = toMatch.count - queryTitles.count

        for (index, title) in queryTitles.enumerated() {
            // Cancel stops promptly after the current item, not only at the next await; the
            // matches gathered so far (incl. the reused ones) are returned and persisted, so a
            // restart resumes rather than re-querying.
            if Task.isCancelled { break }
            // The title and the resume count travel in their own fields so the shared
            // progress view can render the counter, the middle-truncated title and the
            // "· N already matched" detail as separate, non-jittering lines (owner
            // 2026-09-20). `detail` keeps the combined string for any plain consumer.
            let detail = reusedCount > 0
                ? "\(title.name) · \(reusedCount) already matched" : title.name
            onProgress(ImportProgress(phase: .matching, completed: index, total: queryTitles.count,
                                      detail: detail, currentTitle: title.name,
                                      alreadyMatched: reusedCount))
            let row = rowsByExternalID[title.externalID]
            // A file importer matches a cleaned title (`matchTitle`) while `name` keeps
            // the noisy original for display (PLAN §5.5); GOG leaves `matchTitle` nil.
            let request = ImportMatchRequest(
                title: row?.matchTitle ?? title.name,
                platformSlug: title.platform, releaseYear: row?.releaseYear)
            let outcome = try await matcher.match(request)

            // 3b. Expand a bundle match (PLAN §5.1) right here, so the outcome and its member
            // list are persisted together — a resumed sync restores both without re-querying.
            var bundle: ImportBundleExpansion?
            if let bundleExpander, let best = outcome.best, best.isBundle {
                let result = (try? await bundleExpander.members(ofBundleIGDBID: best.igdbID)) ?? BundleMemberResult()
                bundle = ImportBundleExpansion(bundleIGDBID: best.igdbID, title: best.name,
                                               members: ImportBundleMapping.members(from: result.members),
                                               leftOut: result.leftOut)
            }
            let persisted = outcome.best != nil ? PersistedImportMatch(outcome: outcome, bundle: bundle) : nil
            try? await staging.recordMatchOutcome(
                source: importer.source, externalID: title.externalID, persisted, now: now)

            matches.append(ImportMatchResult(externalID: title.externalID, name: title.name, outcome: outcome))
            if let bundle { bundleExpansions[title.externalID] = bundle }
        }

        // 3c. Fold every port best-match onto its parent game (PLAN §5.1 D4 — "a port is
        // the same game"), in ONE batched `games(ids:)` for the whole sync. Applies to
        // reused and freshly-queried matches; each resolved port re-persists the parent so a
        // later sync reuses it and never re-resolves.
        if let bundleExpander {
            let indexed: [(Int, ScanMatch)] = matches.enumerated().compactMap { idx, m in
                (m.outcome.best?.gameType == .port) ? (idx, m.outcome.best!) : nil
            }
            if !indexed.isEmpty {
                let resolved = await bundleExpander.resolvingPortParents(indexed.map(\.1))
                for ((idx, _), newBest) in zip(indexed, resolved) where newBest.resolvedFromPortID != nil {
                    var outcome = matches[idx].outcome
                    outcome.best = newBest
                    matches[idx].outcome = outcome
                    let externalID = matches[idx].externalID
                    try? await staging.recordMatchOutcome(
                        source: importer.source, externalID: externalID,
                        PersistedImportMatch(outcome: outcome, bundle: bundleExpansions[externalID]), now: now)
                }
            }
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
            ownedGap: fetched.ownedGap,
            fromFile: fetched.fromFile)
        onProgress(ImportProgress(phase: .finished))
        return ImportSyncResult(summary: summary, matches: matches, rows: fetched.rows,
                                vaultEntries: fetched.vaultEntries,
                                vaultPresentIDs: fetched.vaultPresentIDs,
                                bundleExpansions: bundleExpansions)
    }

    /// The same sync as an `AsyncStream` of progress values; the final ``ImportSyncResult``
    /// (or the thrown error) is delivered through `completion`.
    func stream(for importer: any LibraryImporter,
                matcher: any ImportMatcher,
                bundleExpander: (any ImportBundleExpanding)? = nil,
                completion: @Sendable @escaping (Result<ImportSyncResult, Error>) -> Void) -> AsyncStream<ImportProgress> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let result = try await run(importer, matcher: matcher, bundleExpander: bundleExpander) { progress in
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

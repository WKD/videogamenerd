import Foundation

/// A coarse progress update for one system during a sync (PLAN §15 — "progress stream").
struct BatoceraSyncProgress: Sendable, Hashable {
    enum Phase: String, Sendable, Hashable {
        case scanning        // listing systems
        case reading         // reading + folding one system
        case finishing       // computing promotion candidates
    }
    var phase: Phase
    var system: String
    var completedSystems: Int
    var totalSystems: Int
}

/// The outcome of one sync (PLAN §15). Plain, `Sendable`, label-free — the UI renders the
/// banner ("3 games added from Batocera") from these numbers.
struct BatoceraSyncSummary: Sendable, Hashable {
    /// The NAS was not mounted — a quiet result, not an error (PLAN §15 "nothing complains").
    var shareUnavailable = false

    var systemsRead = 0
    var systemsSkipped = 0
    var systemsUnchanged = 0
    var systemsFailed = 0
    /// System folders with no VGN mapping and not on the skip list — reported for the owner.
    var unknownSystems: [String] = []
    /// System folders that were skipped (arcade / non-collection).
    var skippedSystems: [String] = []
    /// Per-system read failures, with a one-line reason.
    var failures: [Failure] = []

    var entriesAdded = 0
    var entriesUpdated = 0
    var entriesRemoved = 0
    /// Duplicate entries folded away across all systems this run.
    var foldedDuplicates = 0

    /// Catalogue rows that are promotion candidates and not yet promoted (whole catalogue).
    var candidateCount = 0
    var candidateCatalogIDs: [Int64] = []

    var durationSeconds: Double = 0
    /// The sync was cancelled before finishing.
    var cancelled = false

    struct Failure: Sendable, Hashable {
        var system: String
        var reason: String
    }
}

/// The change-detecting sync actor (PLAN §15). Serial (an actor), cancellable, read-only on
/// the share. For each non-skipped system whose `gamelist.xml` mtime/size changed since the
/// last read (or all on a `force`d / first run) it reads → folds duplicates → upserts the
/// catalogue → marks vanished ROMs removed → and finally computes promotion candidates. An
/// unmounted share yields a quiet `.shareUnavailable` result.
actor BatoceraSync {
    private let store: RomCatalogStore
    private let reader: BatoceraGamelistReader

    init(store: RomCatalogStore, reader: BatoceraGamelistReader = BatoceraGamelistReader()) {
        self.store = store
        self.reader = reader
    }

    /// Sync from a chosen share root (`/Volumes/share` or `/Volumes/share/roms`). `skip`,
    /// when non-nil, is the owner's editable skip list (PLAN §15 phase 2) used instead of the
    /// built-in constant skip sets; the arcade romset families (`mame*`/`cps*`) are always
    /// skipped on top of it.
    func sync(root: URL, force: Bool = false, skip: Set<String>? = nil,
              progress: (@Sendable (BatoceraSyncProgress) -> Void)? = nil) async -> BatoceraSyncSummary {
        let share: BatoceraShare
        do {
            share = try BatoceraShare(root: root)
        } catch {
            var summary = BatoceraSyncSummary()
            summary.shareUnavailable = true
            return summary
        }
        return await sync(share: share, force: force, skip: skip, progress: progress)
    }

    /// Sync a resolved share (used by tests with a temp folder).
    func sync(share: BatoceraShare, force: Bool = false, skip: Set<String>? = nil,
              progress: (@Sendable (BatoceraSyncProgress) -> Void)? = nil) async -> BatoceraSyncSummary {
        let start = Date()
        var summary = BatoceraSyncSummary()

        guard share.isReachable else {
            summary.shareUnavailable = true
            summary.durationSeconds = Date().timeIntervalSince(start)
            return summary
        }

        let files: [BatoceraSystemFile]
        do {
            files = try share.systemFiles()
        } catch {
            summary.shareUnavailable = true
            summary.durationSeconds = Date().timeIntervalSince(start)
            return summary
        }

        progress?(BatoceraSyncProgress(phase: .scanning, system: "", completedSystems: 0,
                                       totalSystems: files.count))

        for (i, file) in files.enumerated() {
            if Task.isCancelled { summary.cancelled = true; break }

            let classification = skip.map { BatoceraSystems.classify(file.system, skip: $0) }
                ?? BatoceraSystems.classify(file.system)
            switch classification {
            case .skipped:
                summary.systemsSkipped += 1
                summary.skippedSystems.append(file.system)
                continue
            case .unknown:
                summary.unknownSystems.append(file.system)
                continue
            case .mapped(let slug):
                await syncOneSystem(file: file, slug: slug, force: force,
                                    index: i, total: files.count, summary: &summary,
                                    progress: progress)
            }
        }

        // Promotion candidates across the whole catalogue.
        progress?(BatoceraSyncProgress(phase: .finishing, system: "",
                                       completedSystems: files.count, totalSystems: files.count))
        if let candidates = try? await store.promotionCandidates() {
            summary.candidateCount = candidates.count
            summary.candidateCatalogIDs = candidates.map(\.id)
        }

        summary.durationSeconds = Date().timeIntervalSince(start)
        return summary
    }

    private func syncOneSystem(file: BatoceraSystemFile, slug: String, force: Bool,
                               index: Int, total: Int,
                               summary: inout BatoceraSyncSummary,
                               progress: (@Sendable (BatoceraSyncProgress) -> Void)?) async {
        // Change detection: skip an unchanged system unless forced. The stored mtime is
        // truncated to millisecond text by GRDB, so compare with a 1 s tolerance (Batocera
        // rewrites the whole file, so the size changes on any real edit anyway).
        if !force, let state = try? await store.syncState(system: file.system),
           state.gamelistSize == file.fileSize,
           let stored = state.gamelistMtime, let current = file.modificationDate,
           abs(stored.timeIntervalSince1970 - current.timeIntervalSince1970) < 1.0 {
            summary.systemsUnchanged += 1
            return
        }

        progress?(BatoceraSyncProgress(phase: .reading, system: file.system,
                                       completedSystems: index, totalSystems: total))

        // Read off the actor (synchronous file I/O).
        let games: [BatoceraGame]
        do {
            let reader = self.reader
            let url = file.gamelistURL
            let system = file.system
            games = try await Task.detached(priority: .userInitiated) {
                try reader.read(system: system, url: url)
            }.value
        } catch let error as BatoceraError {
            summary.systemsFailed += 1
            summary.failures.append(.init(system: file.system, reason: error.message))
            return
        } catch {
            summary.systemsFailed += 1
            summary.failures.append(.init(system: file.system, reason: error.localizedDescription))
            return
        }

        // Fold duplicates, then upsert the representatives.
        let folded = BatoceraFolding.fold(games)
        summary.foldedDuplicates += folded.foldedCount
        let entries = folded.groups.map {
            RomCatalogEntry.make(from: $0.representative, platformID: slug, libretroKey: $0.libretroKey)
        }

        do {
            let counts = try await store.syncSystem(system: file.system, entries: entries)
            summary.entriesAdded += counts.added
            summary.entriesUpdated += counts.updated
            summary.entriesRemoved += counts.removed
            try await store.setSyncState(system: file.system, mtime: file.modificationDate,
                                         size: file.fileSize, entryCount: entries.count)
            summary.systemsRead += 1
        } catch {
            summary.systemsFailed += 1
            summary.failures.append(.init(system: file.system, reason: error.localizedDescription))
        }
    }
}

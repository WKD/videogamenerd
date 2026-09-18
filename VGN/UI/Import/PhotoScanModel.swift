import Foundation
import Observation

/// Which stage of the flow the scan window shows.
enum ScanPresentation: Equatable, Sendable {
    case input        // cost notice + drop zone / queued photos
    case running      // per-photo progress
    case review       // the review sheet
    case committed    // the summary
}

/// All photo-scan logic (PLAN §6.2), behind the `PhotoScanEnvironment` seams so the
/// views stay thin and the flow is unit-testable with fakes. `@MainActor @Observable`.
@MainActor
@Observable
final class PhotoScanModel {
    /// Shown before starting (PLAN §6.2 cost/usage notice).
    static let costNotice = "≈ 8 Claude calls per photo (~1–2 min, counts against your Claude subscription usage)."
    static let supportedExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    private let environment: PhotoScanEnvironment

    // Presentation
    private(set) var presentation: ScanPresentation = .input
    private(set) var jobs: [PhotoScanJob] = []
    private(set) var activeEngine: ActiveScanEngine?
    private(set) var fallbackNote: String?
    private(set) var preflightError: ClaudeCLIError?

    // Review
    private(set) var reviewRows: [ScanReviewRow] = []
    var selectedRowID: UUID?

    // Commit
    private(set) var isCommitting = false
    private(set) var summary: ScanCommitSummary?
    private(set) var commitError: String?

    @ObservationIgnored private var settings = PhotoScanSettings()
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var jobTasks: [UUID: Task<Result<PhotoScanResult, Error>, Never>] = [:]
    @ObservationIgnored private var commitTask: Task<Void, Never>?

    init(environment: PhotoScanEnvironment) {
        self.environment = environment
        self.settings = environment.preferences.load()
    }

    // MARK: - Input queue

    static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Add photos to the queue (drag-drop / file picker / Continuity Camera). Filters
    /// to supported image types and de-dupes by URL. No-op once scanning has begun.
    func enqueue(_ urls: [URL]) {
        guard presentation == .input else { return }
        for url in urls where Self.isSupportedImage(url) {
            if !jobs.contains(where: { $0.url == url }) {
                jobs.append(PhotoScanJob(url: url))
            }
        }
    }

    func removeJob(_ id: UUID) {
        guard presentation == .input else { return }
        jobs.removeAll { $0.id == id }
    }

    var canStart: Bool { presentation == .input && !jobs.isEmpty }

    // MARK: - Run

    /// Begin scanning the queue (after the user acknowledges the cost notice).
    func start() {
        guard canStart else { return }
        presentation = .running
        settings = environment.preferences.load()
        batchTask = Task { await self.runBatch() }
    }

    private func runBatch() async {
        let engine = await decideEngine(settings: settings)
        activeEngine = engine
        for id in jobs.map(\.id) {
            if Task.isCancelled { break }
            guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].phase.isTerminal else { continue }
            await runJob(id: id, engine: engine)
        }
        finishBatchIfDone()
    }

    private func decideEngine(settings: PhotoScanSettings) async -> ActiveScanEngine {
        preflightError = nil
        fallbackNote = nil
        if settings.enginePreference == .visionOnly { return .vision }
        do {
            _ = try await environment.scanner.preflight()
            return .claude
        } catch let error as ClaudeCLIError {
            preflightError = error
            fallbackNote = "\(error.shortDescription) Falling back to offline Vision OCR — results will be rougher."
            return .vision
        } catch {
            fallbackNote = "Claude Code is unavailable. Falling back to offline Vision OCR — results will be rougher."
            return .vision
        }
    }

    private func runJob(id: UUID, engine: ActiveScanEngine) async {
        guard let start = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[start].phase = .tiling
        jobs[start].startedAt = Date()
        let url = jobs[start].url
        let name = jobs[start].name
        let isInLibrary = environment.isInLibrary
        let scanner = environment.scanner   // Sendable; captured on the main actor

        let task = Task { () -> Result<PhotoScanResult, Error> in
            do {
                let result = try await scanner.scan(
                    photoAt: url, photoName: name, engine: engine,
                    isInLibrary: isInLibrary,
                    onEvent: { event in Task { @MainActor in self.handleEvent(event, jobID: id) } },
                    onMetrics: { _, metrics in Task { @MainActor in self.applyMetrics(metrics, jobID: id) } }
                )
                return .success(result)
            } catch {
                return .failure(error)
            }
        }
        jobTasks[id] = task
        let outcome = await task.value
        jobTasks[id] = nil

        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].phase == .cancelled { return }
        jobs[index].finishedAt = Date()
        switch outcome {
        case .success(let result):
            jobs[index].result = result
            jobs[index].tileTotal = max(jobs[index].tileTotal, result.tileCount)
            jobs[index].phase = .ready
        case .failure(let error):
            if error is CancellationError {
                jobs[index].phase = .cancelled
            } else if let cliError = error as? ClaudeCLIError {
                jobs[index].phase = .failed(cliError.shortDescription)
            } else {
                jobs[index].phase = .failed("\(error)")
            }
        }
    }

    // MARK: - Progress events

    private func handleEvent(_ event: ShelfRecognitionEvent, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].phase.isTerminal else { return }
        switch event {
        case .queued(let tileID, let total):
            jobs[index].tileTotal = max(jobs[index].tileTotal, total)
            upsertTile(jobIndex: index, tileID: tileID, state: .queued)
            advanceToRecognizing(index)
        case .running(let tileID):
            upsertTile(jobIndex: index, tileID: tileID, state: .running)
            advanceToRecognizing(index)
        case .done(let tileID, let items):
            upsertTile(jobIndex: index, tileID: tileID, state: .done(items: items))
        case .failed(let tileID, let reason):
            upsertTile(jobIndex: index, tileID: tileID, state: .failed(reason: reason))
        }
        // Once every known tile is terminal, the recogniser is done and IGDB matching
        // is under way.
        if jobs[index].phase == .recognizing, jobs[index].tileTotal > 0,
           jobs[index].tiles.count >= jobs[index].tileTotal,
           jobs[index].tiles.allSatisfy({ $0.state.rank == 2 }) {
            jobs[index].phase = .matching
        }
    }

    private func advanceToRecognizing(_ index: Int) {
        if jobs[index].phase == .queued || jobs[index].phase == .tiling {
            jobs[index].phase = .recognizing
        }
    }

    private func upsertTile(jobIndex: Int, tileID: Int, state: ScanTileProgress.State) {
        if let t = jobs[jobIndex].tiles.firstIndex(where: { $0.id == tileID }) {
            // Monotonic: never regress a tile if events arrive out of order.
            if state.rank >= jobs[jobIndex].tiles[t].state.rank {
                jobs[jobIndex].tiles[t].state = state
            }
        } else {
            jobs[jobIndex].tiles.append(ScanTileProgress(id: tileID, state: state))
            jobs[jobIndex].tiles.sort { $0.id < $1.id }
        }
    }

    private func applyMetrics(_ metrics: ClaudeRunMetrics, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let cost = metrics.costUSD { jobs[index].costUSD += cost }
    }

    // MARK: - Cancellation

    func cancel(jobID: UUID) {
        jobTasks[jobID]?.cancel()
        if let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].phase.isTerminal {
            jobs[index].phase = .cancelled
            jobs[index].finishedAt = Date()
        }
    }

    func cancelAll() {
        batchTask?.cancel()
        for task in jobTasks.values { task.cancel() }
        for index in jobs.indices where !jobs[index].phase.isTerminal {
            jobs[index].phase = .cancelled
            jobs[index].finishedAt = Date()
        }
        finishBatchIfDone()
    }

    private func finishBatchIfDone() {
        guard jobs.allSatisfy({ $0.phase.isTerminal }) else { return }
        reviewRows = PhotoScanReviewBuilder.rows(from: readyResults)
        selectedRowID = reviewRows.first?.id
        presentation = .review
    }

    var readyResults: [PhotoScanResult] { jobs.compactMap(\.result) }
    var totalCost: Double { jobs.reduce(0) { $0 + $1.costUSD } }

    // MARK: - Review edits

    var selectedRow: ScanReviewRow? { selectedRowID.flatMap { id in reviewRows.first { $0.id == id } } }
    var selectedIndex: Int? { selectedRowID.flatMap { id in reviewRows.firstIndex { $0.id == id } } }

    func selectRow(_ id: UUID) { selectedRowID = id }

    func setInclude(_ include: Bool, rowID: UUID) {
        mutate(rowID) { row in
            guard !row.alreadyInLibrary else { return }   // greyed rows never commit
            row.include = include
        }
    }

    func togglePlayed(rowID: UUID) { mutate(rowID) { $0.played.toggle() } }
    func setPlatform(_ slug: String?, rowID: UUID) {
        mutate(rowID) { row in
            row.platformSlug = slug
            row.alreadyInLibrary = row.selectedMatch.map { environment.isInLibrary($0.igdbID, slug) } ?? false
        }
    }
    func setFormat(_ format: ProductFormat, rowID: UUID) { mutate(rowID) { $0.format = format } }

    func ignoreRow(_ rowID: UUID) { mutate(rowID) { $0.ignored = true; $0.include = false } }
    func unignoreRow(_ rowID: UUID) { mutate(rowID) { $0.ignored = false } }

    /// Pick an alternative from the pipeline's list.
    func chooseMatch(_ match: ScanMatch, rowID: UUID) {
        mutate(rowID) { row in
            row.selectedMatch = match
            var bucket = ScanMatching.bucket(for: match.score)
            if bucket == .none { bucket = .plausible }   // an explicit pick is at least plausible
            row.bucket = bucket
            if row.platformSlug == nil { row.platformSlug = match.platformSlugs.first }
            row.alreadyInLibrary = environment.isInLibrary(match.igdbID, row.platformSlug)
            row.include = !row.alreadyInLibrary
        }
    }

    /// Pick a result from the inline "Search IGDB…" field (user-affirmed).
    func chooseSearchResult(_ result: IGDBSearchResult, rowID: UUID) {
        mutate(rowID) { row in
            let match = PhotoScanReviewBuilder.match(from: result, query: row.printedTitle)
            row.selectedMatch = match
            row.isCompilation = result.isBundle
            row.bucket = .confident
            if row.platformSlug == nil { row.platformSlug = result.platformSlugs.first }
            row.alreadyInLibrary = environment.isInLibrary(match.igdbID, row.platformSlug)
            row.include = !row.alreadyInLibrary
        }
    }

    /// Inline IGDB search for the change-match field.
    func searchIGDB(_ text: String, rowID: UUID) async -> [IGDBSearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let row = reviewRows.first(where: { $0.id == rowID }) else { return [] }
        return (try? await environment.searcher.search(trimmed, platformSlug: row.platformSlug)) ?? []
    }

    /// Hand a printed title to Quick Add for an unmatched row.
    func handToQuickAdd(rowID: UUID) {
        guard let row = reviewRows.first(where: { $0.id == rowID }) else { return }
        environment.onQuickAdd(row.printedTitle)
    }

    private func mutate(_ rowID: UUID, _ transform: (inout ScanReviewRow) -> Void) {
        guard let index = reviewRows.firstIndex(where: { $0.id == rowID }) else { return }
        transform(&reviewRows[index])
    }

    // MARK: - Keyboard intents

    func moveSelection(by delta: Int) {
        guard !reviewRows.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), reviewRows.count - 1)
        selectedRowID = reviewRows[next].id
    }

    func togglePlayedSelected() { if let id = selectedRowID { togglePlayed(rowID: id) } }

    func toggleIncludeSelected() {
        guard let id = selectedRowID, let row = reviewRows.first(where: { $0.id == id }), !row.alreadyInLibrary else { return }
        setInclude(!row.include, rowID: id)
    }

    /// ⌘A — include every non-greyed, non-ignored row.
    func selectAllIncludable() {
        for index in reviewRows.indices where !reviewRows[index].alreadyInLibrary && !reviewRows[index].ignored {
            reviewRows[index].include = true
        }
    }

    /// ⌥↑ / ⌥↓ — jump the selection to the adjacent confidence bucket.
    func jumpBucket(_ delta: Int) {
        guard let row = selectedRow else { moveSelection(by: delta); return }
        let buckets = Array(Set(reviewRows.map(\.bucket.order))).sorted()
        guard let pos = buckets.firstIndex(of: row.bucket.order) else { return }
        let target = min(max(pos + (delta < 0 ? -1 : 1), 0), buckets.count - 1)
        let targetOrder = buckets[target]
        if let first = reviewRows.first(where: { $0.bucket.order == targetOrder }) {
            selectedRowID = first.id
        }
    }

    // MARK: - Commit

    var committableCount: Int { reviewRows.filter(\.isCommittable).count }
    var commitButtonTitle: String { "Add \(committableCount) game\(committableCount == 1 ? "" : "s")" }
    var canCommit: Bool { presentation == .review && committableCount > 0 && !isCommitting }

    func commit() {
        guard canCommit else { return }
        isCommitting = true
        commitError = nil
        commitTask = Task { await self.performCommit() }
    }

    private func performCommit() async {
        let committable = reviewRows.filter(\.isCommittable)
        var singles: [GameDraft] = []
        var compilations: [ScanCompilationDraft] = []

        for row in committable {
            if row.isCompilation, let igdbID = row.selectedMatch?.igdbID, row.platformSlug != nil {
                let members = (try? await environment.searcher.bundleMembers(bundleIGDBID: igdbID)) ?? []
                if members.isEmpty {
                    singles.append(PhotoScanReviewBuilder.gameDraft(for: row))   // no member list → single
                } else {
                    compilations.append(ScanCompilationDraft(
                        product: PhotoScanReviewBuilder.productDraft(for: row),
                        members: PhotoScanReviewBuilder.memberDrafts(from: members, played: row.played)
                    ))
                }
            } else {
                singles.append(PhotoScanReviewBuilder.gameDraft(for: row))
            }
        }

        do {
            let outcomes = try await environment.committer.commit(singles: singles, compilations: compilations)
            summary = ScanCommitSummary.from(outcomes: outcomes)
            environment.onLibraryChanged()
            presentation = .committed
        } catch {
            commitError = "Couldn't add the games — nothing was changed."
        }
        isCommitting = false
    }

    func showInLibrary() {
        if let id = summary?.firstGameID { environment.onShowInLibrary(id) }
    }
}

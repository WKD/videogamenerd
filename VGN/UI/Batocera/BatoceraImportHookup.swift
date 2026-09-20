import SwiftUI

// App-level hookup for the Batocera ROM **promotion review** (PLAN §15 phase 2): a presenter
// the container builds once, entry points from the review banner / catalogue browser / Discover
// row, a view modifier hosting the progress + review sheets, and the "Import from Batocera…"
// command. Mirrors `DeliciousImportHookup` — a file/local source with no account — but the
// review's commit runs through `BatoceraPromoter` (ROM copies + the box's play data + the
// "adds play time only" duplicate rule), and the "file" is the local `rom_catalog` shelf, so
// the review never touches `/Volumes` (the sync does that, separately).

/// Owns the presentation state of the Batocera promotion review (catalogue → IGDB match →
/// review sheet → promote). One per window/container. The catalogue is a local table, so this
/// works in every mode; outside live the IGDB matcher is the no-match one (never any network).
@MainActor
@Observable
final class BatoceraImportPresenter {
    private let catalog: RomCatalogStore
    private let promoter: BatoceraPromoter
    private let staging: ImportStagingStore
    private let matcher: any ImportMatcher
    /// The **throwing** matcher for the background favourites pass (D4): an IGDB failure must
    /// surface so the run pauses cleanly, so it is not the resilient wrapper the review uses.
    private let autoAddMatcher: any ImportMatcher
    /// Expands a bundle match into member games during the review sync + the favourites pass
    /// (D2, PLAN §5.1). ``NoBundleExpander`` outside live / without IGDB.
    private let bundleExpander: any ImportBundleExpanding
    private let platformChoices: [String]
    private let onLibraryChanged: () -> Void
    /// Shared, observable favourites-matching progress the Settings pane reads (D4).
    let favouriteProgress = BatoceraFavouriteProgress()
    /// Surfaces an error to the window (wired to the library banner).
    @ObservationIgnored var onError: @MainActor (String) -> Void = { _ in }
    /// The window model that shows banners + owns the undo manager (nil in unit tests).
    @ObservationIgnored weak var library: LibraryViewModel?
    /// Whether favourites are auto-added after a sync — live + IGDB-configured + the setting on
    /// (PLAN §15). The container wires it; the default keeps auto-add off (tests / other modes).
    @ObservationIgnored var autoAddEnabled: () -> Bool = { false }

    var reviewModel: ImportReviewModel?
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// The entries the last auto-add batch promoted (for the banner's Undo + the undo manager).
    @ObservationIgnored private var pendingUndoEntries: [RomCatalogEntry] = []
    @ObservationIgnored private var autoAddTask: Task<Void, Never>?

    init(catalog: RomCatalogStore,
         promoter: BatoceraPromoter,
         staging: ImportStagingStore,
         matcher: any ImportMatcher,
         autoAddMatcher: (any ImportMatcher)? = nil,
         bundleExpander: any ImportBundleExpanding = NoBundleExpander(),
         platformChoices: [String],
         onLibraryChanged: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.promoter = promoter
        self.staging = staging
        self.matcher = matcher
        self.autoAddMatcher = autoAddMatcher ?? matcher
        self.bundleExpander = bundleExpander
        self.platformChoices = platformChoices
        self.onLibraryChanged = onLibraryChanged
        self.favouriteProgress.onStop = { [weak self] in self?.autoAddTask?.cancel() }
    }

    /// Open the review over the pending promotion candidates (played > 5 min or favourite),
    /// e.g. from the launch banner's "Review…".
    func reviewCandidates() { startSync(catalogIDs: nil) }

    // MARK: - Auto-add favourites (PLAN §15)

    /// Called after every sync (from the settings model's `onSyncFinished`). When auto-add is
    /// on, it runs the background matcher/promoter pass — now **to completion**, batch after
    /// batch, until no un-attempted favourite remains (D4) — and shows ONE final "N favourites
    /// added · N need your review" banner (Review… + Undo). Otherwise it falls back to the quiet
    /// "N ready to review" banner. Progress is published through ``favouriteProgress`` so the
    /// Settings status line can show "Matching favourites… 120 of 247 · Stop".
    func handleSyncFinished(_ summary: BatoceraSyncSummary) {
        guard autoAddEnabled() else { showReviewBanner(candidateCount: summary.candidateCount); return }
        autoAddTask?.cancel()
        let engine = BatoceraFavouriteAutoAdd(catalog: catalog, staging: staging,
                                              matcher: autoAddMatcher, promoter: promoter,
                                              expander: bundleExpander)
        let candidateCount = summary.candidateCount
        autoAddTask = Task { [weak self] in
            await self?.runFavouriteMatching(engine, fallbackCandidateCount: candidateCount)
        }
    }

    /// The back-to-back batch loop (D4): keep matching favourites (one IGDB request stream, the
    /// batch cap as the batch *size*, cancellable) until none is left, an IGDB error pauses it,
    /// or the owner stops it. Everything the whole run added is one Undo step.
    func runFavouriteMatching(_ engine: BatoceraFavouriteAutoAdd,
                              fallbackCandidateCount: Int,
                              batchLimit: Int = BatoceraFavouriteAutoAdd.batchCap) async {
        let total = (try? await catalog.favouritesNeedingMatchCount()) ?? 0
        guard total > 0 else {
            // Nothing to match — behave exactly as before (the quiet review banner, if any).
            showReviewBanner(candidateCount: fallbackCandidateCount)
            return
        }
        favouriteProgress.begin(total: total)
        defer { favouriteProgress.finish() }

        var promotedAll: [RomCatalogEntry] = []
        var matched = 0
        var paused = false

        while true {
            if Task.isCancelled { break }
            let result = await engine.run(limit: batchLimit)
            matched += result.processedCount
            promotedAll.append(contentsOf: result.promotedEntries)
            favouriteProgress.update(matched: matched, added: promotedAll.count)
            if result.addedCount > 0 { onLibraryChanged() }
            if result.cancelled { break }
            if result.pausedByError { paused = true; break }
            if result.processedCount == 0 { break }   // no un-attempted favourite left
        }

        pendingUndoEntries = promotedAll
        if !promotedAll.isEmpty { registerAutoAddUndo(entries: promotedAll) }
        let reviewCount = (try? await catalog.promotionCandidateCount()) ?? 0
        showFinalFavouritesBanner(added: promotedAll.count, reviewCount: reviewCount,
                                  paused: paused, fallbackCandidateCount: fallbackCandidateCount)
    }

    /// The single banner shown when the whole favourites run ends (D4): plain words, an obvious
    /// next step, never a bare "still to match".
    private func showFinalFavouritesBanner(added: Int, reviewCount: Int, paused: Bool,
                                           fallbackCandidateCount: Int) {
        guard let library else { return }
        // Nothing added: keep the quiet review banner (or nothing) — no misleading "0 added".
        guard added > 0 else { showReviewBanner(candidateCount: max(reviewCount, fallbackCandidateCount)); return }

        var message = "\(added) favourite\(added == 1 ? "" : "s") added from Batocera"
        if reviewCount > 0 {
            message += " · \(reviewCount) need\(reviewCount == 1 ? "s" : "") your review"
        }
        if paused { message += " · paused (couldn’t reach IGDB — the rest retry next sync)" }

        // Undo stays the primary action; Review… is the secondary next step (both on the banner
        // API), so the owner is never stranded behind an Undo-only banner (D4, PLAN §15).
        if reviewCount > 0 {
            library.showBanner(
                message, actionTitle: "Undo",
                action: { [weak self] in self?.undoAutoAdd() },
                secondaryActionTitle: "Review…",
                secondaryAction: { [weak self] in self?.reviewCandidates() })
        } else {
            library.showBanner(message, actionTitle: "Undo") { [weak self] in
                self?.undoAutoAdd()
            }
        }
    }

    private func showReviewBanner(candidateCount: Int) {
        guard let library, candidateCount > 0 else { return }
        let n = candidateCount
        library.showBanner("\(n) Batocera game\(n == 1 ? "" : "s") ready to review",
                           actionTitle: "Review…") { [weak self] in self?.reviewCandidates() }
    }

    private func registerAutoAddUndo(entries: [RomCatalogEntry]) {
        guard let undo = library?.undoManager, !entries.isEmpty else { return }
        undo.registerUndo(withTarget: self) { presenter in
            Task { @MainActor in await presenter.performAutoAddUndo(entries) }
        }
        undo.setActionName("Add Batocera Favourites")
    }

    /// The banner's Undo button.
    func undoAutoAdd() {
        let entries = pendingUndoEntries
        Task { await self.performAutoAddUndo(entries) }
    }

    /// Reverse the last auto-add batch (idempotent — safe to call from the banner *and* the
    /// undo manager). `internal` so a test can drive it directly (`UndoManager.undo()` hangs
    /// headless — assert registration, call the inverse here).
    func performAutoAddUndo(_ entries: [RomCatalogEntry]) async {
        guard !entries.isEmpty else { return }
        try? await promoter.undoAutoAdd(entries: entries)
        pendingUndoEntries = []
        onLibraryChanged()
        library?.dismissBanner()
    }

    /// Open the review over a hand-picked set of catalogue rows ("Add to Library…" in the
    /// browser / Discover). No-op if that set is empty.
    func addToLibrary(catalogIDs: [Int64]) {
        guard !catalogIDs.isEmpty else { return }
        startSync(catalogIDs: catalogIDs)
    }

    private func startSync(catalogIDs: [Int64]?) {
        guard reviewModel == nil, !isSyncing else { return }
        isSyncing = true
        progress = ImportProgress(phase: .fetching, detail: "Reading the Batocera catalogue")

        let importer = BatoceraImporter(store: catalog, catalogIDs: catalogIDs)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let matcher = self.matcher
        let bundleExpander = self.bundleExpander
        let staging = self.staging
        let catalog = self.catalog
        let promoter = self.promoter
        let platformChoices = self.platformChoices
        let onLibraryChanged = self.onLibraryChanged

        syncTask = Task {
            do {
                // The entries backing this review — for the play-line captions and the map the
                // committer resolves each row against.
                let entries: [RomCatalogEntry]
                if let catalogIDs { entries = try await catalog.entries(ids: catalogIDs) }
                else { entries = try await catalog.promotionCandidates() }
                let entryMap = Dictionary(entries.map { ($0.externalID, $0) },
                                          uniquingKeysWith: { a, _ in a })
                let details = Dictionary(entries.map { ($0.externalID, Self.playLine(for: $0)) },
                                         uniquingKeysWith: { a, _ in a })

                let result = try await coordinator.run(
                    importer, matcher: matcher, bundleExpander: bundleExpander
                ) { p in
                    Task { @MainActor in self.progress = p }
                }
                if Task.isCancelled { self.reset(); return }

                self.reviewModel = ImportReviewModel(
                    source: ImportSourceID.batocera, sourceLabel: "Batocera",
                    staging: staging, result: result,
                    productFormat: .rom, platformChoices: platformChoices,
                    romPromotion: true, rowDetailByID: details,
                    customCommit: Self.commitClosure(promoter: promoter, entryMap: entryMap),
                    onLibraryChanged: onLibraryChanged)
                self.progress = nil
                self.isSyncing = false
            } catch {
                self.reset()
                self.onError("The Batocera catalogue couldn't be read.")
            }
        }
    }

    func cancelSync() { syncTask?.cancel(); reset() }
    func dismissReview() { reviewModel = nil }
    private func reset() { progress = nil; isSyncing = false }

    // MARK: - Commit (ROM promotion through BatoceraPromoter)

    /// The committer: each ticked row → a ``BatoceraPromoter/Plan``. A row matched to an
    /// existing library game (directly, or by an IGDB id already in the library) promotes as
    /// `.existingGame`, adding play time only when that game already owns a ROM copy on the
    /// platform; otherwise a new game is created. Then the catalogue rows are linked.
    static func commitClosure(
        promoter: BatoceraPromoter, entryMap: [String: RomCatalogEntry]
    ) -> @Sendable ([ImportReviewCommitRow]) async throws -> ImportCommitResult {
        { rows in
            var plans: [BatoceraPromoter.Plan] = []
            for row in rows {
                guard var entry = entryMap[row.externalID] else { continue }
                if let chosen = row.platformID { entry.platformID = chosen }
                let platform = entry.platformID ?? ""

                // A bundle match promotes as a `rom` compilation with its members (D2, PLAN §5.1).
                if !row.bundleMembers.isEmpty {
                    plans.append(.compilation(
                        entry: entry,
                        bundle: BatoceraPromoter.BundlePromotion(
                            title: row.bundleTitle, members: row.bundleMembers)))
                    continue
                }

                // Resolve to an existing game (a staged match, or an IGDB id already present).
                var gameID = row.matchedGameID
                if gameID == nil, let igdb = row.igdbID {
                    gameID = try await promoter.existingGameID(igdbID: igdb)
                }
                if let gameID {
                    let hasCopy = try await promoter.gameHasROMCopy(gameID: gameID, platformID: platform)
                    plans.append(.init(entry: entry, target: .existingGame(gameID: gameID),
                                       alreadyHasROMCopy: hasCopy))
                } else {
                    let spec = ImportNewGameSpec(title: row.title, igdbID: row.igdbID,
                                                 releaseYear: row.releaseYear)
                    plans.append(.init(entry: entry, target: .newGame(spec), alreadyHasROMCopy: false))
                }
            }
            return try await promoter.promote(plans).commit
        }
    }

    /// The per-row caption: total play time, last played, and a ★ for a favourite.
    static func playLine(for e: RomCatalogEntry) -> String {
        var parts: [String] = []
        if e.gameTimeSeconds > 0 { parts.append(PlaytimeParser.format(seconds: e.gameTimeSeconds)) }
        if let last = e.lastPlayedAt {
            parts.append("last played \(Self.monthYear.string(from: last))")
        }
        if e.isFavorite { parts.append("★ favourite") }
        return parts.joined(separator: " · ")
    }

    private static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

// MARK: - Builder

/// Builds the Batocera promotion-review wiring for ``AppEnvironment`` (PLAN §15). The catalogue
/// is a local table, so this is built in every non-test mode; the IGDB matcher is real only in
/// live mode with IGDB configured (else the no-match matcher — no network).
enum BatoceraImportBuilder {
    @MainActor
    static func build(
        mode: LaunchMode,
        database: AppDatabase,
        secrets: any SecretStoring,
        graph: ServicesFactory.Graph?,
        platformCatalog: PlatformCatalog?,
        onError: @escaping @MainActor (String) -> Void,
        onLibraryChanged: @escaping () -> Void
    ) -> BatoceraImportPresenter {
        let catalog = RomCatalogStore(database)
        let promoter = BatoceraPromoter(database)
        let staging = ImportStagingStore(database)

        let matcher: any ImportMatcher              // resilient — for the review sync
        let autoAddMatcher: any ImportMatcher       // throwing base — for the favourites pass (D4)
        let bundleExpander: any ImportBundleExpanding
        let canMatch: Bool
        if mode == .live, let graph, let platformCatalog,
           secrets.hasValue(for: .igdbClientID), secrets.hasValue(for: .igdbClientSecret) {
            let base = IGDBImportMatcher(
                client: graph.igdbClient,
                platformIGDBIDs: { slug in platformCatalog.entry(forSlug: slug)?.igdbIDs ?? [] })
            matcher = ResilientImportMatcher(base: base)
            autoAddMatcher = base
            bundleExpander = IGDBImportBundleExpander(client: graph.igdbClient)
            canMatch = true
        } else {
            matcher = NoMatchImportMatcher()
            autoAddMatcher = NoMatchImportMatcher()
            bundleExpander = NoBundleExpander()
            canMatch = false
        }

        let platformChoices = platformCatalog?.entries.map(\.id) ?? PlatformLabels.all.map(\.id)

        let presenter = BatoceraImportPresenter(
            catalog: catalog, promoter: promoter, staging: staging,
            matcher: matcher, autoAddMatcher: autoAddMatcher, bundleExpander: bundleExpander,
            platformChoices: platformChoices,
            onLibraryChanged: onLibraryChanged)
        presenter.onError = onError
        // Auto-add runs only when a real IGDB match is possible and the owner left the setting
        // on (PLAN §15) — never in sample / seeded / test, never with the no-match matcher.
        presenter.autoAddEnabled = { canMatch && BatoceraPreferences.addFavouritesAutomatically }
        return presenter
    }
}

// MARK: - View hookup

private struct BatoceraImportPresentation: ViewModifier {
    let presenter: BatoceraImportPresenter?

    func body(content: Content) -> some View {
        if let presenter {
            content
                .sheet(isPresented: Binding(
                    get: { presenter.reviewModel != nil },
                    set: { if !$0 { presenter.dismissReview() } }
                )) {
                    if let model = presenter.reviewModel {
                        ImportReviewSheet(model: model) { presenter.dismissReview() }
                    }
                }
                .sheet(isPresented: Binding(
                    get: { presenter.progress != nil && presenter.reviewModel == nil },
                    set: { _ in }
                )) {
                    BatoceraReviewProgressSheet(progress: presenter.progress) { presenter.cancelSync() }
                }
                .focusedSceneValue(\.batoceraImportPresenter, presenter)
        } else {
            content
        }
    }
}

extension View {
    /// Hosts the Batocera promotion-review progress + review sheets.
    func batoceraImportPresentation(_ presenter: BatoceraImportPresenter?) -> some View {
        modifier(BatoceraImportPresentation(presenter: presenter))
    }
}

/// A small progress sheet with Cancel, shown while candidates are matched to IGDB.
struct BatoceraReviewProgressSheet: View {
    let progress: ImportProgress?
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: fraction).controlSize(.large)
                .frame(width: 220)
            Text(phaseLabel).font(.headline)
            if let progress, progress.phase == .matching, let total = progress.total, total > 0 {
                Text("\(progress.completed) of \(total)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320)
    }

    private var fraction: Double? {
        guard let progress, let total = progress.total, total > 0 else { return nil }
        return Double(progress.completed) / Double(total)
    }

    private var phaseLabel: String {
        switch progress?.phase {
        case .fetching: return "Reading the Batocera catalogue…"
        case .staging: return "Saving candidates…"
        case .matching: return "Matching to IGDB…"
        default: return "Finishing…"
        }
    }
}

// MARK: - Command

struct BatoceraImportPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = BatoceraImportPresenter
}

extension FocusedValues {
    var batoceraImportPresenter: BatoceraImportPresenter? {
        get { self[BatoceraImportPresenterFocusedValueKey.self] }
        set { self[BatoceraImportPresenterFocusedValueKey.self] = newValue }
    }
}

/// File ▸ Import from Batocera… (next to Import from Delicious Library…). Reviews the pending
/// promotion candidates.
struct BatoceraImportCommands: Commands {
    @FocusedValue(\.batoceraImportPresenter) private var presenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from Batocera…") { presenter?.reviewCandidates() }
                .disabled(presenter == nil)
                .help("Review the ROMs you have played or favourited and add them to your library.")
        }
    }
}

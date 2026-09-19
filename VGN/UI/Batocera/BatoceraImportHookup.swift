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
    private let platformChoices: [String]
    private let onLibraryChanged: () -> Void
    /// Surfaces an error to the window (wired to the library banner).
    @ObservationIgnored var onError: @MainActor (String) -> Void = { _ in }

    var reviewModel: ImportReviewModel?
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(catalog: RomCatalogStore,
         promoter: BatoceraPromoter,
         staging: ImportStagingStore,
         matcher: any ImportMatcher,
         platformChoices: [String],
         onLibraryChanged: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.promoter = promoter
        self.staging = staging
        self.matcher = matcher
        self.platformChoices = platformChoices
        self.onLibraryChanged = onLibraryChanged
    }

    /// Open the review over the pending promotion candidates (played > 5 min or favourite),
    /// e.g. from the launch banner's "Review…".
    func reviewCandidates() { startSync(catalogIDs: nil) }

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

                let result = try await coordinator.run(importer, matcher: matcher) { p in
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

        let matcher: any ImportMatcher
        if mode == .live, let graph, let platformCatalog,
           secrets.hasValue(for: .igdbClientID), secrets.hasValue(for: .igdbClientSecret) {
            matcher = ResilientImportMatcher(base: IGDBImportMatcher(
                client: graph.igdbClient,
                platformIGDBIDs: { slug in platformCatalog.entry(forSlug: slug)?.igdbIDs ?? [] }))
        } else {
            matcher = NoMatchImportMatcher()
        }

        let platformChoices = platformCatalog?.entries.map(\.id) ?? PlatformLabels.all.map(\.id)

        let presenter = BatoceraImportPresenter(
            catalog: catalog, promoter: promoter, staging: staging,
            matcher: matcher, platformChoices: platformChoices,
            onLibraryChanged: onLibraryChanged)
        presenter.onError = onError
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

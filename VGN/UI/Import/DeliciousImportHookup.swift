import AppKit
import SwiftUI
import UniformTypeIdentifiers

// App-level hookup for the Delicious Library import flow (PLAN §5.5): a presenter the
// container builds once, an open-panel entry point, a view modifier hosting the progress
// + review sheets, and the "Import from Delicious Library…" command. Mirrors
// `GOGImportHookup` so the hot root/container files change by one line each.

/// Owns the presentation state of the Delicious import flow (open panel → progress →
/// review sheet). One per window/container. Works in live AND sample mode (it needs no
/// account and no network except IGDB matching — the fake/no-match matcher is used
/// outside live, exactly as for GOG).
@MainActor
@Observable
final class DeliciousImportPresenter {
    private let staging: ImportStagingStore
    private let matcher: any ImportMatcher
    private let platformChoices: [String]
    /// Live cover fallback context (store + cover actor); nil ⇒ no source covers offered.
    @ObservationIgnored private let coverContext: (store: LibraryStore, coverStore: CoverStore)?
    private let onLibraryChanged: () -> Void
    /// Surfaces a picker / read error to the window (wired to the library banner).
    @ObservationIgnored var onError: @MainActor (String) -> Void = { _ in }

    var reviewModel: ImportReviewModel?
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(staging: ImportStagingStore,
         matcher: any ImportMatcher,
         platformChoices: [String],
         coverContext: (store: LibraryStore, coverStore: CoverStore)? = nil,
         onLibraryChanged: @escaping () -> Void = {}) {
        self.staging = staging
        self.matcher = matcher
        self.platformChoices = platformChoices
        self.coverContext = coverContext
        self.onLibraryChanged = onLibraryChanged
    }

    /// File ▸ Import from Delicious Library…: choose a file, then sync.
    func importFromFile() {
        guard reviewModel == nil, !isSyncing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose your Delicious Library file or the “Delicious Library 2” folder."
        if let type = UTType(filenameExtension: DeliciousFilePicker.fileExtension) {
            panel.allowedContentTypes = [type, .folder]
        }
        if let last = AppPreferences.defaults.string(forKey: DeliciousFilePicker.lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        AppPreferences.defaults.set(picked.deletingLastPathComponent().path,
                                    forKey: DeliciousFilePicker.lastFolderKey)
        guard let file = DeliciousFilePicker.resolve(picked) else {
            onError("That doesn't look like a Delicious Library file.")
            return
        }
        startSync(url: file)
    }

    /// Run one sync against `url` and open the review sheet on success.
    func startSync(url: URL) {
        guard reviewModel == nil, !isSyncing else { return }
        isSyncing = true
        progress = ImportProgress(phase: .fetching)
        let importer = DeliciousImporter(reader: DeliciousLibraryReader(url: url))
        let coordinator = ImportSyncCoordinator(staging: staging)
        let matcher = self.matcher
        let staging = self.staging
        let platformChoices = self.platformChoices
        let onLibraryChanged = self.onLibraryChanged
        let afterCommit = coverApplier(for: url)
        syncTask = Task {
            do {
                let result = try await coordinator.run(importer, matcher: matcher) { p in
                    Task { @MainActor in self.progress = p }
                }
                if Task.isCancelled { self.reset(); return }
                self.reviewModel = ImportReviewModel(
                    source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
                    staging: staging, result: result,
                    productFormat: .physical, platformChoices: platformChoices,
                    detectShelfDuplicates: true, showsSourceCoverToggle: afterCommit != nil,
                    showsPlatformPolicy: true,
                    afterCommit: afterCommit, onLibraryChanged: onLibraryChanged)
                self.progress = nil
                self.isSyncing = false
            } catch {
                self.reset()
                self.onError(Self.message(for: error))
            }
        }
    }

    /// The after-commit cover fallback, or nil when no cover context (no source covers).
    private func coverApplier(for url: URL) -> (@Sendable (ImportCommitResult, Bool) async -> Void)? {
        guard let context = coverContext else { return nil }
        let reader = DeliciousLibraryReader(url: url)
        let store = context.store
        let coverStore = context.coverStore
        return { result, useCovers in
            guard useCovers else { return }
            await DeliciousCoverApplier(reader: reader, store: store, coverStore: coverStore)
                .apply(affectedGameIDs: result.affectedGameIDs)
        }
    }

    func cancelSync() { syncTask?.cancel(); reset() }
    func dismissReview() { reviewModel = nil }
    private func reset() { progress = nil; isSyncing = false }

    static func message(for error: Error) -> String {
        (error as? DeliciousImportError)?.message
            ?? "The Delicious Library file couldn't be read."
    }
}

// MARK: - Builder

/// Builds the Delicious import wiring for ``AppEnvironment`` (PLAN §5.5). Available in
/// every non-test mode (a file needs no account); the IGDB matcher is real only in live
/// mode with IGDB configured, and the source-cover fallback only when a cover store exists.
enum DeliciousImportBuilder {
    @MainActor
    static func build(
        mode: LaunchMode,
        database: AppDatabase,
        secrets: any SecretStoring,
        graph: ServicesFactory.Graph?,
        platformCatalog: PlatformCatalog?,
        store: LibraryStore,
        onError: @escaping @MainActor (String) -> Void,
        onLibraryChanged: @escaping () -> Void
    ) -> DeliciousImportPresenter {
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

        // Every VGN platform is offered per-row (Delicious spans consoles + hybrid discs).
        let platformChoices = platformCatalog?.entries.map(\.id)
            ?? PlatformLabels.all.map(\.id)

        // Source-cover fallback only when a cover store is available.
        let coverContext: (store: LibraryStore, coverStore: CoverStore)? =
            graph.map { (store, $0.coverStore) }

        let presenter = DeliciousImportPresenter(
            staging: staging, matcher: matcher, platformChoices: platformChoices,
            coverContext: coverContext, onLibraryChanged: onLibraryChanged)
        presenter.onError = onError
        return presenter
    }
}

// MARK: - View hookup

private struct DeliciousImportPresentation: ViewModifier {
    let presenter: DeliciousImportPresenter?

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
                    DeliciousSyncProgressSheet(progress: presenter.progress) { presenter.cancelSync() }
                }
                .focusedSceneValue(\.deliciousImportPresenter, presenter)
        } else {
            content
        }
    }
}

extension View {
    /// Hosts the Delicious import progress + review sheets.
    func deliciousImportPresentation(_ presenter: DeliciousImportPresenter?) -> some View {
        modifier(DeliciousImportPresentation(presenter: presenter))
    }
}

/// A small progress sheet with Cancel, shown while the file is read + matched.
struct DeliciousSyncProgressSheet: View {
    let progress: ImportProgress?
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(phaseLabel).font(.headline)
            if let detail = progress?.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320)
    }

    private var phaseLabel: String {
        switch progress?.phase {
        case .fetching: return "Reading your Delicious Library…"
        case .staging: return "Saving titles…"
        case .matching: return "Matching to IGDB…"
        default: return "Finishing…"
        }
    }
}

// MARK: - Command

struct DeliciousImportPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = DeliciousImportPresenter
}

extension FocusedValues {
    var deliciousImportPresenter: DeliciousImportPresenter? {
        get { self[DeliciousImportPresenterFocusedValueKey.self] }
        set { self[DeliciousImportPresenterFocusedValueKey.self] = newValue }
    }
}

/// File ▸ Import from Delicious Library… (next to Import from GOG…).
struct DeliciousImportCommands: Commands {
    @FocusedValue(\.deliciousImportPresenter) private var presenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from Delicious Library…") { presenter?.importFromFile() }
                .disabled(presenter == nil)
                .help("Import an old Delicious Library 2 catalogue file.")
        }
    }
}

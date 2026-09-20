import Foundation

// MARK: - Seams (small protocols so the model is unit-testable with fakes)

/// Runs the photo-scan pipeline for one photo, choosing the engine, and can preflight
/// the CLI so the model decides Claude-vs-Vision up front (PLAN §6.2).
protocol ShelfScanning: Sendable {
    /// Resolve + version-check the `claude` binary (Settings "Check", and the model's
    /// fallback decision). Throws a `ClaudeCLIError`.
    func preflight() async throws -> URL

    /// Scan one photo with `engine`, streaming per-tile events and per-tile metrics.
    func scan(
        photoAt url: URL,
        photoName: String,
        engine: ActiveScanEngine,
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool,
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void,
        onMetrics: @escaping @Sendable (Int, ClaudeRunMetrics) -> Void
    ) async throws -> PhotoScanResult
}

/// A compilation to commit: its product plus ordered members.
struct ScanCompilationDraft: Sendable, Equatable {
    var product: ProductDraft
    var members: [CompilationMemberDraft]
}

/// The atomic commit seam (PLAN §6.2 step 5: "nothing is added blindly … one DB
/// transaction … if anything fails, nothing is half-added").
protocol PhotoScanCommitting: Sendable {
    func commit(
        singles: [GameDraft],
        compilations: [ScanCompilationDraft]
    ) async throws -> [AddOutcome]
}

/// IGDB change-match for the review sheet's alternatives / inline "Search IGDB…".
protocol PhotoScanSearching: Sendable {
    func search(_ text: String, platformSlug: String?) async throws -> [IGDBSearchResult]
    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult
}

/// Persistence for the Settings → Photo Scan tab.
protocol PhotoScanPreferenceStoring: Sendable {
    func load() -> PhotoScanSettings
    func save(_ settings: PhotoScanSettings)
}

// MARK: - Environment

/// The dependency bundle the photo-scan UI needs, constructed by the orchestrator from
/// `AppEnvironment` (this lane never edits the app container). Mirrors
/// `RankingEnvironment`.
///
/// Orchestrator hookup (at merge time):
/// ```swift
/// let scanEnv = PhotoScanEnvironment(
///     services: services.graph,
///     platformCatalog: services.platformCatalog,
///     store: store,
///     onQuickAdd: { title in vm.requestQuickAdd(prefill: title) },
///     onShowInLibrary: { id in vm.selectOnly(id); vm.showInspector() })
/// ```
@MainActor
final class PhotoScanEnvironment {
    let scanner: any ShelfScanning
    let committer: any PhotoScanCommitting
    let searcher: any PhotoScanSearching
    let preferences: any PhotoScanPreferenceStoring
    /// Sync duplicate check passed to the pipeline (igdbID, platformSlug) → already
    /// owned. Defaults to "never" until the orchestrator wires a live check.
    let isInLibrary: @Sendable (Int64, String?) -> Bool
    /// Kick enrichment after a commit (`coordinator.notifyLibraryChanged()`).
    var onLibraryChanged: () -> Void
    /// Hand a printed title to Quick Add for an unmatched row.
    var onQuickAdd: (String) -> Void
    /// Reveal a freshly-added game in the library.
    var onShowInLibrary: (Int64) -> Void

    init(
        scanner: any ShelfScanning,
        committer: any PhotoScanCommitting,
        searcher: any PhotoScanSearching,
        preferences: any PhotoScanPreferenceStoring = UserDefaultsPhotoScanPreferences(),
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool = { _, _ in false },
        onLibraryChanged: @escaping () -> Void = {},
        onQuickAdd: @escaping (String) -> Void = { _ in },
        onShowInLibrary: @escaping (Int64) -> Void = { _ in }
    ) {
        self.scanner = scanner
        self.committer = committer
        self.searcher = searcher
        self.preferences = preferences
        self.isInLibrary = isInLibrary
        self.onLibraryChanged = onLibraryChanged
        self.onQuickAdd = onQuickAdd
        self.onShowInLibrary = onShowInLibrary
    }

    /// Convenience wiring from the services graph + a `LibraryStore`.
    convenience init(
        services: ServicesFactory.Graph,
        platformCatalog: PlatformCatalog,
        store: LibraryStore,
        preferences: any PhotoScanPreferenceStoring = UserDefaultsPhotoScanPreferences(),
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool = { _, _ in false },
        onQuickAdd: @escaping (String) -> Void = { _ in },
        onShowInLibrary: @escaping (Int64) -> Void = { _ in }
    ) {
        let scanner = LiveShelfScanner(
            searcher: services.igdbClient,
            catalog: platformCatalog,
            preferences: preferences
        )
        let searcher = LiveScanSearcher(client: services.igdbClient, catalog: platformCatalog)
        let coordinator = services.coordinator
        self.init(
            scanner: scanner,
            committer: LiveScanCommitter(store: store),
            searcher: searcher,
            preferences: preferences,
            isInLibrary: isInLibrary,
            onLibraryChanged: { Task { await coordinator.notifyLibraryChanged() } },
            onQuickAdd: onQuickAdd,
            onShowInLibrary: onShowInLibrary
        )
    }

    func makeModel() -> PhotoScanModel { PhotoScanModel(environment: self) }
}

// MARK: - Live wiring

/// Live scanner: builds the chosen engine's recogniser (Claude via the CLI, or Apple
/// Vision), wires per-tile metrics, and drives `ScanPipeline`.
struct LiveShelfScanner: ShelfScanning {
    let searcher: any IGDBGameSearching
    let catalog: PlatformCatalog
    let preferences: any PhotoScanPreferenceStoring

    func preflight() async throws -> URL {
        let settings = preferences.load()
        let override = settings.binaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let runner = ClaudeProcessRunner(binaryOverride: override.isEmpty ? nil : override)
        return try await runner.preflight()
    }

    func scan(
        photoAt url: URL,
        photoName: String,
        engine: ActiveScanEngine,
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool,
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void,
        onMetrics: @escaping @Sendable (Int, ClaudeRunMetrics) -> Void
    ) async throws -> PhotoScanResult {
        let settings = preferences.load()
        let recognizer: any ShelfRecognizer
        switch engine {
        case .claude:
            let override = settings.binaryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            recognizer = ClaudeShelfRecognizer(
                runner: ClaudeProcessRunner(binaryOverride: override.isEmpty ? nil : override),
                model: model.isEmpty ? nil : model,
                maxConcurrent: settings.clampedConcurrency,
                onMetrics: onMetrics
            )
        case .vision:
            recognizer = VisionShelfRecognizer()
        }
        let pipeline = ScanPipeline(recognizer: recognizer, searcher: searcher, catalog: catalog)
        return try await pipeline.scan(
            photoAt: url, photoName: photoName, isInLibrary: isInLibrary, onEvent: onEvent
        )
    }
}

/// Atomic library commit (PLAN §6.2 step 5).
///
/// **Atomicity** — how it's achieved within the existing `LibraryStore` API: the common
/// case (no compilations) is a single `addGames` transaction, which is genuinely
/// all-or-nothing. When compilations are present (rare on a shelf), each needs its own
/// `addCompilation` transaction, so they run **first**; the single games follow in one
/// `addGames` transaction. If any step throws, every compilation product already
/// written this commit is rolled back with `removeProduct(confirmOrphanDelete:)` and the
/// error is rethrown, so the user never sees a partial import.
struct LiveScanCommitter: PhotoScanCommitting {
    let store: LibraryStore

    func commit(singles: [GameDraft], compilations: [ScanCompilationDraft]) async throws -> [AddOutcome] {
        // Fast path: no compilations ⇒ literally one transaction.
        if compilations.isEmpty {
            return singles.isEmpty ? [] : try await store.addGames(singles)
        }

        var committedProducts: [Int64] = []
        do {
            var outcomes: [AddOutcome] = []
            for compilation in compilations {
                let (productID, members) = try await store.addCompilation(
                    product: compilation.product, members: compilation.members
                )
                committedProducts.append(productID)
                outcomes.append(contentsOf: members)
            }
            if !singles.isEmpty {
                outcomes.append(contentsOf: try await store.addGames(singles))
            }
            return outcomes
        } catch {
            for productID in committedProducts.reversed() {
                _ = try? await store.removeProduct(productID, confirmOrphanDelete: true)
            }
            throw error
        }
    }
}

/// Live IGDB change-match.
struct LiveScanSearcher: PhotoScanSearching {
    let client: IGDBClient
    let catalog: PlatformCatalog

    func search(_ text: String, platformSlug: String?) async throws -> [IGDBSearchResult] {
        let platformIDs = platformSlug.flatMap { catalog.entry(forSlug: $0)?.igdbIDs }
        return try await client.searchGames(text, platformIGDBIDs: platformIDs, limit: 12)
    }

    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult {
        try await client.bundleMembers(ofBundleID: bundleIGDBID)
    }
}

// MARK: - Preferences (UserDefaults)

/// `UserDefaults`-backed photo-scan settings.
struct UserDefaultsPhotoScanPreferences: PhotoScanPreferenceStoring {
    nonisolated(unsafe) let defaults: UserDefaults
    private let binaryKey = "VGNPhotoScan.binaryOverride"
    private let modelKey = "VGNPhotoScan.model"
    private let concurrencyKey = "VGNPhotoScan.maxConcurrent"
    private let engineKey = "VGNPhotoScan.enginePreference"

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    func load() -> PhotoScanSettings {
        var settings = PhotoScanSettings()
        settings.binaryOverride = defaults.string(forKey: binaryKey) ?? ""
        settings.model = defaults.string(forKey: modelKey) ?? ""
        if defaults.object(forKey: concurrencyKey) != nil {
            settings.maxConcurrent = defaults.integer(forKey: concurrencyKey)
        }
        if let raw = defaults.string(forKey: engineKey),
           let pref = ScanEnginePreference(rawValue: raw) {
            settings.enginePreference = pref
        }
        settings.maxConcurrent = settings.clampedConcurrency
        return settings
    }

    func save(_ settings: PhotoScanSettings) {
        defaults.set(settings.binaryOverride, forKey: binaryKey)
        defaults.set(settings.model, forKey: modelKey)
        defaults.set(settings.clampedConcurrency, forKey: concurrencyKey)
        defaults.set(settings.enginePreference.rawValue, forKey: engineKey)
    }
}

/// An in-memory preferences store (tests, previews).
final class InMemoryPhotoScanPreferences: PhotoScanPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: PhotoScanSettings
    init(_ settings: PhotoScanSettings = PhotoScanSettings()) { self.settings = settings }
    func load() -> PhotoScanSettings { lock.withLock { settings } }
    func save(_ settings: PhotoScanSettings) { lock.withLock { self.settings = settings } }
}

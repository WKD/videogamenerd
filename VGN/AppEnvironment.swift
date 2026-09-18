import Foundation
import SwiftUI

/// The app's composition root (PLAN §8/§9). Built once in ``VGNApp``:
///
/// - opens ``AppDatabase`` (the live on-disk DB, or an in-memory one seeded with
///   the sample library when launched with `-VGNSampleData YES`),
/// - builds the merged services graph (``ServicesFactory``): IGDB client, cover
///   store, catalogue cache, the persisted enrichment queue + coordinator, and the
///   Settings connection tester,
/// - injects `graph.coverStore` as the grid's `CoverLoading`, starts the enrichment
///   coordinator, and wires every library write back to `notifyLibraryChanged()`,
/// - builds the Quick Add palette (``QuickAddModel`` + ``QuickAddPanelController``)
///   and the enrichment-status indicator.
///
/// **Modes.** *Live* uses the real Application Support directories and starts the
/// coordinator. *Sample* (`-VGNSampleData YES`) uses a throwaway in-memory DB, temp
/// directories, and **never touches the network**: the coordinator is not started,
/// writes are not forwarded to it, and Quick Add's catalogue searcher is the offline
/// one (local + manual only). The *XCTest host* builds nothing.
@MainActor
final class AppEnvironment {
    let settings: SettingsModel
    let library: LibraryViewModel?
    let actions: LibraryActions?
    let failure: DatabaseOpenFailure?
    let services: ServicesFactory.Graph?
    let quickAdd: QuickAddModel?
    let quickAddController: QuickAddPanelController?
    let enrichment: EnrichmentStatusModel?
    /// Stores + cover loader for the ranking destinations (Duel, Triage, Tier Board, The Top).
    let ranking: RankingEnvironment?
    /// Presents the photo-scan sheet (PLAN §6.2); nil without services (tests).
    let photoScan: PhotoScanPresenter?

    struct DatabaseOpenFailure: Sendable {
        var message: String
        var path: String
    }

    private init(
        settings: SettingsModel,
        library: LibraryViewModel?,
        actions: LibraryActions?,
        failure: DatabaseOpenFailure?,
        services: ServicesFactory.Graph? = nil,
        quickAdd: QuickAddModel? = nil,
        quickAddController: QuickAddPanelController? = nil,
        enrichment: EnrichmentStatusModel? = nil,
        ranking: RankingEnvironment? = nil,
        photoScan: PhotoScanPresenter? = nil
    ) {
        self.settings = settings
        self.library = library
        self.actions = actions
        self.failure = failure
        self.services = services
        self.quickAdd = quickAdd
        self.quickAddController = quickAddController
        self.enrichment = enrichment
        self.ranking = ranking
        self.photoScan = photoScan
    }

    /// Build the environment. Never throws — a DB failure becomes `failure`.
    static func launch() -> AppEnvironment {
        let settings = SettingsModel(secretStore: KeychainStore())

        // Never open the real database from the unit-test host.
        if VGNApp.isRunningUnitTests {
            return AppEnvironment(settings: settings, library: nil, actions: nil, failure: nil)
        }

        let mode = LaunchMode.current
        do {
            let database = try mode.usesInMemoryDB
                ? AppDatabase.inMemory()
                : AppDatabase.live()
            let store = LibraryStore(database)

            // Merged services (nil ⇒ degrade gracefully to no covers / offline).
            let built = buildServices(mode: mode, database: database, secrets: settings.secretStore)
            let coverLoader: any CoverLoading = built?.graph.coverStore ?? NoopCoverLoader()

            let dataSource = GRDBLibraryDataSource(store: store)
            let vm = LibraryViewModel(dataSource: dataSource, coverLoader: coverLoader)
            let actions = LibraryActions(store: store, vm: vm)
            actions.install()

            let wiring = wireServices(
                mode: mode, built: built, store: store, vm: vm, actions: actions,
                settings: settings, coverLoader: coverLoader
            )

            bootstrap(store: store, database: database, mode: mode)

            // Live: start the enrichment coordinator once the app is up.
            if mode == .live, let graph = built?.graph {
                Task { await graph.coordinator.startup() }
            }

            return AppEnvironment(
                settings: settings, library: vm, actions: actions, failure: nil,
                services: built?.graph, quickAdd: wiring.quickAdd,
                quickAddController: wiring.controller, enrichment: wiring.enrichment,
                ranking: RankingEnvironment(
                    ranking: RankingStore(database), library: store, coverLoader: coverLoader
                ),
                photoScan: built.map {
                    PhotoScanPresenter(services: $0.graph, platformCatalog: $0.platformCatalog,
                                       store: store, library: vm)
                }
            )
        } catch {
            let path = (try? AppPaths.databaseURL().path) ?? "~/Library/Application Support/VGN/vgn.sqlite"
            NSLog("VGN: could not open the database: \(error)")
            return AppEnvironment(
                settings: settings, library: nil, actions: nil,
                failure: DatabaseOpenFailure(
                    message: (error as NSError).localizedDescription,
                    path: path
                )
            )
        }
    }

    // MARK: - Services build (testable)

    /// The built services plus the platform catalogue the Quick Add autocomplete
    /// needs. Nil when the graph could not be built (missing bundle resources).
    struct ServicesBundle {
        var graph: ServicesFactory.Graph
        var platformCatalog: PlatformCatalog
    }

    /// Build the services graph for `mode`. Live uses the real Application Support
    /// directories; sample uses throwaway temp directories so it never writes to the
    /// real library. Returns nil (logged) rather than failing the launch.
    static func buildServices(
        mode: LaunchMode, database: AppDatabase, secrets: any SecretStoring
    ) -> ServicesBundle? {
        do {
            let dirs = serviceDirectories(for: mode)
            let graph = try ServicesFactory.make(
                database: database, secrets: secrets,
                coversDirectory: dirs.covers,
                thumbsDirectory: dirs.thumbs,
                libretroIndexDirectory: dirs.libretro
            )
            let catalog = try PlatformCatalog.loadFromBundle()
            return ServicesBundle(graph: graph, platformCatalog: catalog)
        } catch {
            NSLog("VGN: services unavailable, continuing without them: \(error)")
            return nil
        }
    }

    /// Cover/thumb/libretro directories. Live ⇒ the real app-support dirs (nil lets
    /// `ServicesFactory` resolve them). Sample ⇒ a fresh temp tree — never the real
    /// library.
    static func serviceDirectories(
        for mode: LaunchMode
    ) -> (covers: URL?, thumbs: URL?, libretro: URL?) {
        switch mode {
        case .live:
            return (nil, nil, nil)
        default:
            // Sample / seeded perf → a fresh temp tree, never the real library.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("VGN-scratch-\(UUID().uuidString)", isDirectory: true)
            return (
                base.appendingPathComponent("covers", isDirectory: true),
                base.appendingPathComponent("thumbs", isDirectory: true),
                base.appendingPathComponent("libretro", isDirectory: true)
            )
        }
    }

    private struct Wiring {
        var quickAdd: QuickAddModel
        var controller: QuickAddPanelController
        var enrichment: EnrichmentStatusModel?
    }

    private static func wireServices(
        mode: LaunchMode, built: ServicesBundle?, store: LibraryStore,
        vm: LibraryViewModel, actions: LibraryActions, settings: SettingsModel,
        coverLoader: any CoverLoading
    ) -> Wiring {
        // Quick Add catalogue searcher: live IGDB only in live mode with a graph.
        let searcher: any CatalogSearching
        if mode == .live, let bundle = built {
            searcher = LiveCatalogSearcher(
                client: bundle.graph.igdbClient,
                credentials: bundle.graph.credentials
            )
        } else {
            searcher = OfflineCatalogSearcher()
        }

        let quickAdd = QuickAddModel(
            catalog: searcher,
            catalogCache: built?.graph.catalogCache,   // instant/offline cached rows
            library: LiveLibraryAdder(store: store),
            platforms: PlatformLabels.all
        )
        quickAdd.onOpenInspector = { [weak vm] id in
            vm?.selectOnly(id)
            vm?.showInspector()
        }
        let controller = QuickAddPanelController(model: quickAdd, coverLoader: coverLoader)
        controller.onClose = { [weak vm] in vm?.quickAddPresented = false }

        // Live enrichment wiring (sample mode leaves these as no-ops → no network).
        var enrichment: EnrichmentStatusModel?
        if mode == .live, let graph = built?.graph {
            let coordinator = graph.coordinator
            actions.onLibraryChanged = { Task { await coordinator.notifyLibraryChanged() } }
            quickAdd.onLibraryChanged = { Task { await coordinator.notifyLibraryChanged() } }
            vm.onRefreshMetadata = { id in Task { await coordinator.refresh(gameID: id) } }
            settings.onCredentialsChanged = { Task { await coordinator.credentialsDidChange() } }
            enrichment = EnrichmentStatusModel(coordinator: coordinator, jobStore: graph.jobStore)
        }

        // Test connection is available whenever a graph exists (user-initiated).
        settings.connectionTester = built?.graph.connectionTester

        // Manual cover from a dropped image (both modes; sample writes to temp).
        // A hand-picked cover is sacred: `setUserCover` marks the `cover` field
        // user-edited so background enrichment (even an explicit refresh) never
        // clobbers it (PLAN §5.2 point 4 / §7b).
        if let graph = built?.graph {
            let coverStore = graph.coverStore
            vm.onImportCover = { [weak vm] gameID, url in
                Task {
                    do {
                        let stored = try await coverStore.importCover(from: url, gameID: gameID)
                        try await store.setUserCover(gameID: gameID, coverFile: stored.coverFile)
                    } catch {
                        vm?.showBanner("Couldn't set the cover.", kind: .error)
                    }
                }
            }
            // "Remove custom cover": clear the file + marker, then let enrichment
            // fetch one again (live mode only — sample never touches the network).
            let coordinator = built?.graph.coordinator
            vm.onRemoveCover = { [weak vm] gameID in
                Task {
                    do {
                        try await store.clearUserCover(gameID: gameID)
                        if mode == .live { await coordinator?.refresh(gameID: gameID) }
                    } catch {
                        vm?.showBanner("Couldn't remove the cover.", kind: .error)
                    }
                }
            }
        }

        return Wiring(quickAdd: quickAdd, controller: controller, enrichment: enrichment)
    }

    /// Off-launch-path work: seed platforms, (sample mode) seed the sample
    /// library through the store, and (live mode) write a rotating launch
    /// snapshot off the main actor. All failures are logged, never fatal.
    private static func bootstrap(store: LibraryStore, database: AppDatabase, mode: LaunchMode) {
        Task {
            do { _ = try await database.seedPlatformsFromBundle() }
            catch { NSLog("VGN: platform seed failed: \(error)") }
            if mode == .sampleData {
                await SampleLibrarySeeder.seed(into: store)
            }
            #if DEBUG
            if case .seededPerf(let n) = mode {
                let clock = ContinuousClock()
                let start = clock.now
                await PerfSeeder.seed(into: store, count: n)
                NSLog("VGN perf: seeded \(n) games in \(start.duration(to: clock.now))")
            }
            #endif
        }
        if mode == .live {
            Task.detached(priority: .utility) {
                do { _ = try database.makeLaunchSnapshot() }
                catch { NSLog("VGN: launch snapshot failed: \(error)") }
            }
        }
    }
}

/// How the app was launched.
///
/// - `-VGNSampleData YES` → a throwaway in-memory DB seeded with the sample
///   library (demos / UI checks), never touching the real file or the network.
/// - `-VGNSeedGames <n>` (DEBUG only) → a throwaway in-memory DB filled with `n`
///   synthetic games for performance measurement, no network (PLAN §9/§10).
/// - default → the live on-disk database.
enum LaunchMode: Sendable, Equatable {
    case live
    case sampleData
    #if DEBUG
    case seededPerf(Int)
    #endif

    static var current: LaunchMode {
        #if DEBUG
        let seed = UserDefaults.standard.integer(forKey: "VGNSeedGames")
        if seed > 0 { return .seededPerf(seed) }
        #endif
        return UserDefaults.standard.bool(forKey: "VGNSampleData") ? .sampleData : .live
    }

    /// Non-live modes run against a throwaway in-memory database.
    var usesInMemoryDB: Bool { self != .live }
}

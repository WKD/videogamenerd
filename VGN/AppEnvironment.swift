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
        enrichment: EnrichmentStatusModel? = nil
    ) {
        self.settings = settings
        self.library = library
        self.actions = actions
        self.failure = failure
        self.services = services
        self.quickAdd = quickAdd
        self.quickAddController = quickAddController
        self.enrichment = enrichment
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
            let database = try mode == .sampleData
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
                quickAddController: wiring.controller, enrichment: wiring.enrichment
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
        case .sampleData:
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("VGN-sample-\(UUID().uuidString)", isDirectory: true)
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
            let autocomplete = IGDBAutocomplete(
                credentials: bundle.graph.credentials,
                catalog: bundle.platformCatalog,
                cache: bundle.graph.catalogCache
            )
            searcher = LiveCatalogSearcher(
                autocomplete: autocomplete,
                client: bundle.graph.igdbClient,
                credentials: bundle.graph.credentials
            )
        } else {
            searcher = OfflineCatalogSearcher()
        }

        let quickAdd = QuickAddModel(
            catalog: searcher,
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
        if let graph = built?.graph {
            let coverStore = graph.coverStore
            vm.onImportCover = { [weak vm] gameID, url in
                Task {
                    do {
                        let stored = try await coverStore.importCover(from: url, gameID: gameID)
                        // TODO(merge): once the data lane ships a `user_edited` flag,
                        // set it here so a later "Refresh metadata" won't clobber a
                        // hand-picked cover. Today the coordinator only fills an empty
                        // cover_file, so a manual cover already survives normal enrichment.
                        try await store.updateMetadata(gameID: gameID, MetadataPatch(coverFile: stored.coverFile))
                    } catch {
                        vm?.showBanner("Couldn't set the cover.", kind: .error)
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
        }
        if mode == .live {
            Task.detached(priority: .utility) {
                do { _ = try database.makeLaunchSnapshot() }
                catch { NSLog("VGN: launch snapshot failed: \(error)") }
            }
        }
    }
}

/// How the app was launched. `-VGNSampleData YES` (a process launch argument that
/// `UserDefaults` exposes as the `VGNSampleData` bool) runs against a throwaway
/// in-memory database seeded with the sample library — for demos and UI checks,
/// never touching the real file. Default is the live on-disk database.
enum LaunchMode: Sendable {
    case live
    case sampleData

    static var current: LaunchMode {
        UserDefaults.standard.bool(forKey: "VGNSampleData") ? .sampleData : .live
    }
}

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
    /// Stores for the Play Next destination (PLAN §7b).
    let playNext: PlayNextEnvironment?
    /// Presents the GOG import flow (progress + review sheets, PLAN §14); nil in tests.
    let gogImport: GOGImportPresenter?
    /// Presents the PSN import flow (progress + review sheets, PLAN §13); nil in tests.
    let psnImport: PSNImportPresenter?
    /// Presents the Delicious Library file-import flow (PLAN §5.5); nil in tests.
    let deliciousImport: DeliciousImportPresenter?
    /// The Batocera catalogue browser + Discover dependencies (PLAN §15); nil in tests.
    let batocera: BatoceraEnvironment?
    /// Presents the Batocera promotion-review flow (PLAN §15); nil in tests.
    let batoceraImport: BatoceraImportPresenter?
    /// Presents the HLTB time-estimate fallback (bulk sheet + single-game picker,
    /// PLAN §5.3); nil in tests.
    let hltb: HLTBFetchPresenter?
    /// Presents the IGDB link / change-match + merge sheets (PLAN §5.1); nil in tests.
    let igdbLink: IGDBLinkPresenter?
    /// The shared IGDB catalogue searcher, injected into the environment so the import
    /// review sheet's inline "Find…" can search (PLAN §5.1 item 6); nil offline / tests.
    let catalogSearcher: (any CatalogSearching)?

    struct DatabaseOpenFailure: Sendable {
        var message: String
        var path: String
    }

    /// The open database (live / sample / seeded), or nil in the XCTest host or on a
    /// launch failure. Additive accessor for the Library Stats window (lane w7-d),
    /// which builds its read-only ``LibraryStatsStore`` from it.
    var database: AppDatabase? { ranking?.library.database }

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
        photoScan: PhotoScanPresenter? = nil,
        playNext: PlayNextEnvironment? = nil,
        gogImport: GOGImportPresenter? = nil,
        psnImport: PSNImportPresenter? = nil,
        deliciousImport: DeliciousImportPresenter? = nil,
        batocera: BatoceraEnvironment? = nil,
        batoceraImport: BatoceraImportPresenter? = nil,
        hltb: HLTBFetchPresenter? = nil,
        igdbLink: IGDBLinkPresenter? = nil,
        catalogSearcher: (any CatalogSearching)? = nil
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
        self.playNext = playNext
        self.gogImport = gogImport
        self.psnImport = psnImport
        self.deliciousImport = deliciousImport
        self.batocera = batocera
        self.batoceraImport = batoceraImport
        self.hltb = hltb
        self.igdbLink = igdbLink
        self.catalogSearcher = catalogSearcher
    }

    /// Build the environment. Never throws — a DB failure becomes `failure`.
    static func launch() -> AppEnvironment {
        let settings = SettingsModel(secretStore: AppEnvironment.makeSecretStore())

        // Never open the real database from the unit-test host.
        if VGNApp.isRunningUnitTests {
            return AppEnvironment(settings: settings, library: nil, actions: nil, failure: nil)
        }

        let mode = LaunchMode.current
        if mode == .live { PendingRestore.live.applyIfScheduled() }
        do {
            let database = try mode.usesInMemoryDB
                ? AppDatabase.inMemory()
                : AppDatabase.live()
            let store = LibraryStore(database)

            // Merged services (nil ⇒ degrade gracefully to no covers / offline).
            // The cover loader is wrapped so the inspector's "Choose Cover…" sheet
            // (PLAN §5.2 step 4) reaches candidate listing / choosing through the same
            // `vm.coverLoader`. Candidate listing is offline outside live mode.
            let built = buildServices(mode: mode, database: database, secrets: settings.secretStore)
            let coverLoader: any CoverLoading = built.map {
                ChooseCoverService(coverStore: $0.graph.coverStore, library: store,
                                   allowsNetwork: mode == .live,
                                   // Live only: the IGDB artwork fetch for the sheet (D1).
                                   igdbClient: mode == .live ? $0.graph.igdbClient : nil)
            } ?? NoopCoverLoader()

            let rankingStore = RankingStore(database)
            let dataSource = GRDBLibraryDataSource(store: store, ranking: rankingStore)
            // Sample / seeded runs never touch the owner's real preferences.
            let vm = mode == .live
                ? LibraryViewModel(dataSource: dataSource, coverLoader: coverLoader,
                                   selection: initialSelection())
                : LibraryViewModel(dataSource: dataSource, coverLoader: coverLoader,
                                   selection: initialSelection(),
                                   playedMarkPreferences: InMemoryLastPlayedMarkPreferences(),
                                   playPacePreferences: InMemoryPlayPacePreferences())
            let actions = LibraryActions(store: store, vm: vm)
            actions.install()

            let wiring = wireServices(
                mode: mode, built: built, store: store, vm: vm, actions: actions,
                settings: settings, coverLoader: coverLoader
            )

            bootstrap(store: store, database: database, mode: mode)
            if mode == .live, let outcome = PendingRestore.live.consumeResult() {
                vm.showBanner(outcome.message, kind: outcome.failed ? .error : .info)
            }

            // Live: start the enrichment coordinator once the app is up.
            if mode == .live, let graph = built?.graph {
                Task { await graph.coordinator.startup() }
            }

            // GOG import (PLAN §14): live builds the real GOG objects; other modes get an
            // inert backend that never touches the network or the Keychain. A committed
            // import notifies the enrichment coordinator just like the photo-scan commit.
            let coordinator = built?.graph.coordinator
            let gogWiring = GOGImportBuilder.build(
                mode: mode, database: database, secrets: settings.secretStore,
                graph: built?.graph, platformCatalog: built?.platformCatalog,
                onLibraryChanged: {
                    if mode == .live { Task { await coordinator?.notifyLibraryChanged() } }
                })
            settings.gogAccount = gogWiring.account
            // "Show in the Vault" from the GOG review sheet selects the GOG Vault row (PLAN §16).
            gogWiring.presenter.onShowInVault = { [weak vm] in vm?.select(.vault(.gog)) }

            // PSN import (PLAN §13): live builds the real PSN objects (DEBUG also passes the
            // dev cache + account label); other modes get an inert backend that never
            // touches the network or the Keychain. A committed import notifies enrichment.
            let psnWiring = PSNImportBuilder.build(
                mode: mode, database: database, secrets: settings.secretStore,
                graph: built?.graph, platformCatalog: built?.platformCatalog,
                onLibraryChanged: {
                    if mode == .live { Task { await coordinator?.notifyLibraryChanged() } }
                })
            settings.psnAccount = psnWiring.account
            // "Show in the Vault" from the PSN review sheet selects the PS Plus Vault row (PLAN §16).
            psnWiring.presenter.onShowInVault = { [weak vm] in vm?.select(.vault(.psn)) }

            // Delicious Library file import (PLAN §5.5): available in live AND sample mode
            // (a file needs no account). A committed import notifies enrichment like GOG.
            let deliciousImport = DeliciousImportBuilder.build(
                mode: mode, database: database, secrets: settings.secretStore,
                graph: built?.graph, platformCatalog: built?.platformCatalog, store: store,
                onError: { [weak vm] message in vm?.showBanner(message, kind: .error) },
                onLibraryChanged: {
                    if mode == .live { Task { await coordinator?.notifyLibraryChanged() } }
                })
            // "Show in the Vault" from the Delicious review sheet selects the Delicious Vault row.
            deliciousImport.onShowInVault = { [weak vm] in vm?.select(.vault(.delicious)) }

            // Batocera ROM collection (PLAN §15): live builds the real sync + share access;
            // other modes get an inert backend that never touches `/Volumes`. The Settings
            // pane, catalogue browser, promotion review and Discover row all hang off this.
            let batoceraWiring = BatoceraBuilder.build(
                mode: mode, database: database, secrets: settings.secretStore,
                graph: built?.graph, platformCatalog: built?.platformCatalog,
                library: store, recommendation: RecommendationStore(database), vm: vm,
                onError: { [weak vm] message in vm?.showBanner(message, kind: .error) },
                onLibraryChanged: {
                    if mode == .live { Task { await coordinator?.notifyLibraryChanged() } }
                })
            settings.batoceraAccount = batoceraWiring.settings

            // Auto-sync at launch (live only, after the UI is up — never delays launch). The
            // sync runs in an actor (off the main actor); when it finds new candidates the
            // settings model's `onSyncFinished` shows the quiet "Review…" banner. NEVER an
            // auto-commit — every promotion goes through the review sheet.
            if batoceraWiring.shouldAutoSync {
                let batoceraSettings = batoceraWiring.settings
                Task { @MainActor in batoceraSettings.syncNow() }
            }

            // HLTB time-estimate fallback (PLAN §5.3): live builds the real search
            // client; other modes get the inert, no-network search. Reuses the shared
            // importer cache (source = "hltb").
            let hltb = HLTBFetchBuilder.build(mode: mode, database: database, library: vm)

            return AppEnvironment(
                settings: settings, library: vm, actions: actions, failure: nil,
                services: built?.graph, quickAdd: wiring.quickAdd,
                quickAddController: wiring.controller, enrichment: wiring.enrichment,
                ranking: RankingEnvironment(
                    ranking: rankingStore, library: store, coverLoader: coverLoader
                ),
                photoScan: built.map {
                    PhotoScanPresenter(services: $0.graph, platformCatalog: $0.platformCatalog,
                                       store: store, library: vm)
                },
                playNext: .live(database: database, library: store,
                                coverLoader: coverLoader, viewModel: vm),
                gogImport: gogWiring.presenter,
                psnImport: psnWiring.presenter,
                deliciousImport: deliciousImport,
                batocera: batoceraWiring.environment,
                batoceraImport: batoceraWiring.presenter,
                hltb: hltb,
                igdbLink: wiring.igdbLink,
                catalogSearcher: wiring.catalogSearcher
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

    /// The sidebar selection the window should open on. Honours the `-VGNOpen`
    /// launch hook used by the on-demand UI smoke suite (e.g. `-VGNOpen duel`,
    /// `-VGNOpen tierBoard`, `-VGNOpen platform:ps4`) so a flow can deep-link to a
    /// screen instead of clicking through the sidebar. Defaults to `.all`.
    static func initialSelection() -> SidebarSelection {
        guard let token = UserDefaults.standard.string(forKey: "VGNOpen")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return .all }
        if token.hasPrefix("platform:") {
            let slug = String(token.dropFirst("platform:".count))
            return slug.isEmpty ? .all : .platform(slug)
        }
        switch token.lowercased() {
        case "all": return .all
        case "owned": return .owned
        case "played": return .played
        case "backlog": return .backlog
        case "unranked": return .unranked
        case "playnext": return .playNext
        case "tierboard": return .tierBoard
        case "thetop": return .theTop
        case "duel": return .duel
        case "triage": return .duel   // Duel destination, opened on its Triage tab.
        default: return .all
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
        var igdbLink: IGDBLinkPresenter
        var catalogSearcher: any CatalogSearching
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
            // Sample / seeded modes must not touch the owner's real UserDefaults:
            // the sticky owned/played/format flags stay in-memory there (a UI smoke
            // run would otherwise flip the owner's real Quick Add stickiness).
            preferences: mode == .live
                ? UserDefaultsQuickAddPreferences()
                : InMemoryQuickAddPreferences(),
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

        // Compilation editor (PLAN §5.1): built with the store + the same catalogue
        // searcher Quick Add uses, so its member picker searches library then IGDB.
        wireCompilations(vm: vm, store: store, searcher: searcher)

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
            let coverStoreForRefetch = built?.graph.coverStore
            vm.onRemoveCover = { [weak vm] gameID in
                Task {
                    do {
                        try await store.clearUserCover(gameID: gameID)
                        await coverStoreForRefetch?.clearNegativeCache(gameID: gameID)
                        if mode == .live { await coordinator?.refresh(gameID: gameID) }
                    } catch {
                        vm?.showBanner("Couldn't remove the cover.", kind: .error)
                    }
                }
            }
        }

        // Reconcile (PLAN §5.1): the link / change-match sheet + merge. Uses the same
        // catalogue searcher Quick Add uses. After a link/re-link it clears the cover
        // negative cache and (live) forces a refresh (change-match) or a fill-only pass
        // (link, like a fresh IGDB game); a no-op offline.
        let platformCatalog = built?.platformCatalog
        let enrichCoordinator = built?.graph.coordinator
        let enrichCoverStore = built?.graph.coverStore
        let igdbLink = IGDBLinkPresenter(
            store: store, vm: vm, searcher: searcher,
            platformIGDBIDs: { slug in platformCatalog?.entry(forSlug: slug)?.igdbIDs ?? [] },
            onEnrich: { gameID, force in
                guard mode == .live else { return }
                Task {
                    await enrichCoverStore?.clearNegativeCache(gameID: gameID)
                    if force { await enrichCoordinator?.refresh(gameID: gameID) }
                    else { await enrichCoordinator?.notifyLibraryChanged() }
                }
            })
        vm.onLinkToIGDB = { [weak igdbLink] id in igdbLink?.present(for: id) }
        vm.onExpandBundle = { [weak igdbLink] id in igdbLink?.presentBundleExpansion(for: id) }
        vm.onMergePortIntoOriginal = { [weak igdbLink] id in igdbLink?.presentMergeIntoOriginal(for: id) }
        vm.onExpandAllUnplayedBundles = { [weak igdbLink] in igdbLink?.expandAllUnplayedBundles() }
        vm.loadUnplayedBundleCount = { [store] in
            (try? await store.unplayedBundleExpansionCandidates().count) ?? 0
        }

        return Wiring(quickAdd: quickAdd, controller: controller, enrichment: enrichment,
                      igdbLink: igdbLink, catalogSearcher: searcher)
    }

    /// Wire the compilation editor + "Group as compilation…" hooks (PLAN §5.1/§8).
    private static func wireCompilations(
        vm: LibraryViewModel, store: LibraryStore, searcher: any CatalogSearching
    ) {
        vm.onEditCompilation = { [weak vm] productID in
            guard let vm else { return }
            let editor = CompilationEditorModel(
                productID: productID, writer: store, catalog: searcher,
                localSearch: { text in
                    let rows = (try? await store.gamesOnce(
                        filter: LibraryFilter(searchText: text, scope: .all))) ?? []
                    return rows.map(QuickAddLibraryMatch.init(from:))
                },
                platforms: PlatformLabels.all)
            editor.onSelectGame = { [weak vm] id in vm?.selectOnly(id) }
            editor.onClose = { [weak vm] in vm?.compilationEditor = nil }
            vm.compilationEditor = editor
        }

        vm.onGroupAsCompilation = { [weak vm] ids in
            guard let vm, !ids.isEmpty else { return }
            let games = vm.games.filter { ids.contains($0.id) }.map { (id: $0.id, title: $0.title) }
            guard !games.isEmpty else { return }
            Task { [weak vm] in
                guard let vm else { return }
                let all = (try? await store.allPlatforms()) ?? PlatformLabels.all
                let slugs = Set(vm.games.filter { ids.contains($0.id) }.flatMap(\.platformIDs))
                let choices = all.filter { slugs.contains($0.id) }
                vm.groupCompilationRequest = GroupCompilationRequest(
                    games: games,
                    platforms: choices.isEmpty ? all : choices,
                    perform: { [weak vm] title, platformID, format, merge in
                        Task { [weak vm] in
                            do {
                                let productID = try await store.groupAsCompilation(
                                    gameIDs: games.map(\.id), title: title.isEmpty ? nil : title,
                                    platformID: platformID, format: format, mergeExistingSingles: merge)
                                vm?.editCompilation(productID: productID)
                            } catch {
                                vm?.showBanner("Couldn't group the games.", kind: .error)
                            }
                        }
                    })
            }
        }
    }

    /// Off-launch-path work: seed platforms, (sample mode) seed the sample
    /// library through the store, and (live mode) write a rotating launch
    /// snapshot off the main actor. All failures are logged, never fatal.
    /// The Keychain for the current profile: the default service normally; a profile gets
    /// its own service, reading the shared IGDB credentials from the default one.
    static func makeSecretStore() -> any SecretStoring {
        let base = KeychainStore()
        guard let profile = AppProfile.name else { return base }
        return ProfileSecretStore(
            profile: KeychainStore(service: AppProfile.keychainService(base: base.service, profile: profile)),
            fallback: base)
    }

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
            // NOTE (owner decision 2026-09-20, PLAN §4 inv. 5): launch performs **no**
            // clean-up of library data. Stale platform rows are surfaced as the
            // "Platform Without a Copy" review list and removed only by an explicit,
            // undoable owner action — never automatically here.
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

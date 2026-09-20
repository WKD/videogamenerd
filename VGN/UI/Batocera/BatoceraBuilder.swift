import AppKit

/// Builds the whole Batocera feature wiring for ``AppEnvironment`` (PLAN §15 phase 2): the
/// Settings model, the catalogue-browser + Discover environment, and the promotion-review
/// presenter. **Live vs everything else differs deliberately**: live builds the real sync
/// (`BatoceraSync` over the share) and reads box art from the share; sample / seeded / test
/// get an inert backend and a nil-root thumbnail loader, so they **never touch `/Volumes`**.
enum BatoceraBuilder {
    struct Wiring {
        var settings: BatoceraSettingsModel
        var environment: BatoceraEnvironment
        var presenter: BatoceraImportPresenter
        /// Whether an auto-sync should run at launch (live + configured + the toggle on).
        var shouldAutoSync: Bool
    }

    @MainActor
    static func build(
        mode: LaunchMode,
        database: AppDatabase,
        secrets: any SecretStoring,
        graph: ServicesFactory.Graph?,
        platformCatalog: PlatformCatalog?,
        library: LibraryStore,
        recommendation: RecommendationStore,
        vm: LibraryViewModel,
        onError: @escaping @MainActor (String) -> Void,
        onLibraryChanged: @escaping () -> Void
    ) -> Wiring {
        let isLive = mode == .live
        let catalog = RomCatalogStore(database)

        // The sync + status backend: real only in live mode.
        let backend: any BatoceraBackend = isLive
            ? LiveBatoceraBackend(sync: BatoceraSync(store: catalog), catalog: catalog)
            : InertBatoceraBackend()

        // The share roms root + thumbnail loader read the share (live only). Resolving the
        // roms folder does file I/O, so it is only attempted in live mode.
        let romsRoot: URL? = isLive
            ? (BatoceraPreferences.shareFolderURL.flatMap { try? BatoceraShare.romsFolder(under: $0) })
            : nil
        let thumbnails = BatoceraThumbnailLoader(romsRoot: romsRoot)

        // The promotion-review presenter (the catalogue is a local table — built in every mode,
        // matcher real only in live). It also owns the after-sync auto-add of favourites.
        let presenter = BatoceraImportBuilder.build(
            mode: mode, database: database, secrets: secrets,
            graph: graph, platformCatalog: platformCatalog,
            onError: onError, onLibraryChanged: onLibraryChanged)
        presenter.library = vm

        // The Discover backend.
        let discover: any DiscoverBackend = isLive
            ? LiveDiscoverBackend(recommendation: recommendation, catalog: catalog, library: library)
            : InertDiscoverBackend()

        // The Vault's PS Plus manual "Find match…" seam — IGDB search + apply — only when IGDB
        // is configured in live mode (PLAN §16).
        var findMatch: VaultFindMatchSeam?
        if isLive, let graph, let platformCatalog,
           secrets.hasValue(for: .igdbClientID), secrets.hasValue(for: .igdbClientSecret) {
            let searcher = LiveCatalogSearcher(client: graph.igdbClient, credentials: graph.credentials)
            let metadata = IGDBVaultMetadataFetcher(client: graph.igdbClient)
            findMatch = VaultFindMatchSeam(
                searcher: searcher,
                platformIGDBIDs: { slug in slug.flatMap { platformCatalog.entry(forSlug: $0)?.igdbIDs } ?? [] },
                apply: { catalogID, igdbID in
                    let info = (try? await metadata.info(igdbIDs: [igdbID]))?[igdbID]
                    try? await catalog.setVaultMatch(
                        id: catalogID, igdbID: info?.igdbID ?? igdbID, traits: info?.traits ?? [],
                        lengthMainSeconds: info?.lengthMainSeconds,
                        lengthCompleteSeconds: info?.lengthCompleteSeconds, igdbRating: info?.igdbRating)
                })
        }

        let environment = BatoceraEnvironment(
            catalog: catalog,
            thumbnails: thumbnails,
            discover: discover,
            isLive: isLive,
            romsRoot: romsRoot,
            addToLibrary: { [weak presenter] ids in presenter?.addToLibrary(catalogIDs: ids) },
            inspectGame: { [weak vm] id in vm?.selectOnly(id); vm?.showInspector() },
            showCatalogue: { [weak vm] in vm?.select(.vault(.batocera)) },
            findMatch: findMatch)

        let settings = BatoceraSettingsModel(backend: backend)
        // The Settings pane reads the presenter's favourites-matching progress (D4) — same
        // instance both objects share, no polling.
        settings.favouriteProgress = presenter.favouriteProgress
        // After a sync the presenter auto-adds favourites with a confident match (with an Undo
        // banner) when the setting is on, and otherwise shows the quiet "N ready to review"
        // banner — never an auto-commit of anything but a confident favourite (PLAN §15).
        settings.onSyncFinished = { [weak presenter] summary in
            presenter?.handleSyncFinished(summary)
        }
        // The Settings "Review…" button opens the same review as File ▸ Import from Batocera…
        // The review sheet is hosted on the main window, so bring it forward (Settings is key
        // when the button is clicked) before opening it (D6, PLAN §15).
        settings.onReviewRequested = { [weak presenter] in
            NSApp.activate(ignoringOtherApps: true)
            if let main = NSApp.windows.first(where: {
                $0.isVisible && $0.canBecomeMain && $0 !== NSApp.keyWindow
            }) {
                main.makeKeyAndOrderFront(nil)
            }
            presenter?.reviewCandidates()
        }

        let shouldAutoSync = isLive && settings.autoSyncEnabled && settings.isConfigured
        return Wiring(settings: settings, environment: environment,
                      presenter: presenter, shouldAutoSync: shouldAutoSync)
    }
}

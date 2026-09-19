import Foundation

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
        // matcher real only in live).
        let presenter = BatoceraImportBuilder.build(
            mode: mode, database: database, secrets: secrets,
            graph: graph, platformCatalog: platformCatalog,
            onError: onError, onLibraryChanged: onLibraryChanged)

        // The Discover backend.
        let discover: any DiscoverBackend = isLive
            ? LiveDiscoverBackend(recommendation: recommendation, catalog: catalog, library: library)
            : InertDiscoverBackend()

        let environment = BatoceraEnvironment(
            catalog: catalog,
            thumbnails: thumbnails,
            discover: discover,
            isLive: isLive,
            romsRoot: romsRoot,
            addToLibrary: { [weak presenter] ids in presenter?.addToLibrary(catalogIDs: ids) },
            inspectGame: { [weak vm] id in vm?.selectOnly(id); vm?.showInspector() },
            showCatalogue: { [weak vm] in vm?.select(.romCatalogue) })

        let settings = BatoceraSettingsModel(backend: backend)
        // A finished sync that turns up candidates shows the quiet "Review…" banner — never an
        // auto-commit (PLAN §15: every promotion goes through the review sheet).
        settings.onSyncFinished = { [weak vm, weak presenter] summary in
            guard let vm, summary.candidateCount > 0 else { return }
            let n = summary.candidateCount
            vm.showBanner("\(n) Batocera game\(n == 1 ? "" : "s") ready to review",
                          actionTitle: "Review…") { presenter?.reviewCandidates() }
        }

        let shouldAutoSync = isLive && settings.autoSyncEnabled && settings.isConfigured
        return Wiring(settings: settings, environment: environment,
                      presenter: presenter, shouldAutoSync: shouldAutoSync)
    }
}

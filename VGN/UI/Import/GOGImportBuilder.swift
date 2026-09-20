import Foundation

/// Builds the GOG import wiring for ``AppEnvironment`` (PLAN §14.4), keeping the hot
/// composition root down to one call. **Live mode** builds the real `GOGAuth(.galaxy,
/// KeychainGOGTokenStore)` + `GOGImporter` + `ImportSyncCoordinator` + `IGDBImportMatcher`
/// (or `NoMatchImportMatcher` when IGDB is not configured) and enables sign-in; every
/// other mode uses an inert backend that never touches the network or the Keychain and
/// has no sign-in.
enum GOGImportBuilder {
    struct Wiring {
        let account: GOGAccountModel
        let presenter: GOGImportPresenter
    }

    @MainActor
    static func build(
        mode: LaunchMode,
        database: AppDatabase,
        secrets: any SecretStoring,
        graph: ServicesFactory.Graph?,
        platformCatalog: PlatformCatalog?,
        onLibraryChanged: @escaping () -> Void
    ) -> Wiring {
        let staging = ImportStagingStore(database)
        let cache = ImportResponseCacheStore(database)

        let backend: any ImportBackend
        var login: GOGLoginConfig?

        if mode == .live, let graph, let platformCatalog {
            let transport = URLSessionTransport()
            let auth = GOGAuth(
                transport: transport,
                configuration: .galaxy,
                tokenStore: KeychainGOGTokenStore(secrets: secrets))
            let importer = GOGImporter(auth: auth, transport: transport, cache: cache)
            let coordinator = ImportSyncCoordinator(staging: staging)

            // IGDB matcher only when IGDB is configured; otherwise stage every title for
            // manual review (PLAN §14.3). Wrapped so a flaky lookup never sinks a sync.
            let configured = secrets.hasValue(for: .igdbClientID)
                && secrets.hasValue(for: .igdbClientSecret)
            let matcher: any ImportMatcher = configured
                ? ResilientImportMatcher(base: IGDBImportMatcher(
                    client: graph.igdbClient,
                    platformIGDBIDs: { slug in platformCatalog.entry(forSlug: slug)?.igdbIDs ?? [] }))
                : NoMatchImportMatcher()

            // Bundle expansion reuses the shared IGDB client (PLAN §5.1); only when configured.
            let bundleExpander: (any ImportBundleExpanding)? = configured
                ? IGDBImportBundleExpander(client: graph.igdbClient) : nil

            backend = LiveGOGImportBackend(
                auth: auth, importer: importer, coordinator: coordinator,
                matcher: matcher, cache: cache, staging: staging, bundleExpander: bundleExpander)
            login = GOGLoginConfig(
                authorizationURL: auth.authorizationURL,
                policy: GOGLoginNavigationPolicy(
                    parser: auth.redirectParser, allowedHosts: auth.allowedNavigationHosts))
        } else {
            backend = InertImportBackend(staging: staging)
        }

        let account = GOGAccountModel(backend: backend, login: login)
        let presenter = GOGImportPresenter(backend: backend, onLibraryChanged: onLibraryChanged)
        presenter.account = account
        account.onSyncRequested = { [weak presenter] in presenter?.syncNow() }
        // Keep the menu's signed-in check fresh before the user opens Settings.
        Task { await account.refresh() }

        return Wiring(account: account, presenter: presenter)
    }
}

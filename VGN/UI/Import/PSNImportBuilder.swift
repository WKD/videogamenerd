import Foundation

/// Builds the PSN import wiring for ``AppEnvironment`` (PLAN §13), mirroring
/// ``GOGImportBuilder``. **Live mode** builds the real `PSNAuth(.mobileApp,
/// KeychainPSNTokenStore)` + `PSNImporter` + `ImportSyncCoordinator` + `IGDBImportMatcher`
/// (or `NoMatchImportMatcher` when IGDB is not configured) and enables sign-in; every other
/// mode uses the shared inert backend that never touches the network or the Keychain and
/// has no sign-in.
///
/// In **DEBUG live** the importer is given the development response cache and the owner's
/// chosen account label (`test` / `real`, persisted) so a re-run costs zero requests and
/// the probe markers/dev-cache are scoped per account (PLAN §13.5). A Release build passes
/// neither — no dev cache and no build-steps panel exist there.
enum PSNImportBuilder {
    struct Wiring {
        let account: PSNAccountModel
        let presenter: PSNImportPresenter
    }

    /// Preference key of the live-PSN safety latch (default false = inert everywhere).
    static let liveEnabledKey = "psn.liveEnabled"

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
        var login: PSNLoginConfig?
        var expiryProvider: @Sendable () async -> Date? = { nil }
        var vaultMatch: VaultTraitMatchModel?
        #if DEBUG
        var buildSteps: PSNBuildStepsModel?
        #endif

        // SAFETY LATCH (orchestrator, 2026-09-19): the live PSN objects exist only once the
        // owner has explicitly armed them (`defaults write com.pomatelier.VideoGameNerd
        // psn.liveEnabled -bool YES`). Until the DEBUG build-steps panel (PLAN §13.5) lands,
        // a stray click on Sign In / Sync Now must not be able to talk to Sony: the plan is
        // one tiny probe at a time, with the orchestrator present.
        let armed = AppPreferences.defaults.bool(forKey: PSNImportBuilder.liveEnabledKey)
        if mode == .live, armed, let graph, let platformCatalog {
            // Ephemeral sessions: nothing from Sony lands in the app's shared cookie jar or
            // URL cache. The authorize step gets a session that does NOT follow redirects.
            let transport = URLSessionTransport.ephemeral()
            let auth = PSNAuth(
                transport: transport,
                authorizeTransport: URLSessionTransport.ephemeral(followRedirects: false),
                configuration: .mobileApp,
                tokenStore: KeychainPSNTokenStore(secrets: secrets))

            let accountLabel = AppPreferences.defaults.string(forKey: PSNAccountModel.accountLabelKey) ?? "test"
            let importer = Self.makeImporter(
                auth: auth, transport: transport, cache: cache, accountLabel: accountLabel)
            let coordinator = ImportSyncCoordinator(staging: staging)

            let configured = secrets.hasValue(for: .igdbClientID)
                && secrets.hasValue(for: .igdbClientSecret)
            let matcher: any ImportMatcher = configured
                ? ResilientImportMatcher(base: IGDBImportMatcher(
                    client: graph.igdbClient,
                    platformIGDBIDs: { slug in platformCatalog.entry(forSlug: slug)?.igdbIDs ?? [] }))
                : NoMatchImportMatcher()

            // PSN bundles expand too (PLAN §13.3): an IGDB bundle match fetches its members
            // during matching, on the shared IGDB client / rate limiter — nil when IGDB is not
            // configured, so a bundle simply commits as a single.
            let bundleExpander: (any ImportBundleExpanding)? = configured
                ? IGDBImportBundleExpander(client: graph.igdbClient) : nil

            backend = LivePSNImportBackend(
                auth: auth, importer: importer, coordinator: coordinator,
                matcher: matcher, cache: cache, staging: staging, bundleExpander: bundleExpander)

            // The Vault IGDB trait-matching pass (PLAN §16) exists only when IGDB can match —
            // it fills PS Plus entries with traits / rating / time-to-beat so they can be
            // suggested in "From the vault". Built here, attached to the account model below.
            if configured {
                let traitMatcher = VaultTraitMatcher(
                    catalog: RomCatalogStore(database), matcher: matcher,
                    metadata: IGDBVaultMetadataFetcher(client: graph.igdbClient))
                vaultMatch = VaultTraitMatchModel(catalog: RomCatalogStore(database), matcher: traitMatcher)
            }
            login = PSNLoginConfig(
                loginURL: auth.loginURL,
                policy: auth.navigationPolicy,
                npssoCookieName: auth.npssoCookieName,
                npssoCookieDomain: auth.npssoCookieDomain)
            expiryProvider = { await auth.sessionExpiry() }

            #if DEBUG
            // The gated live-steps panel (PLAN §13.5): a live runner over the same auth /
            // cache / dev cache the importer uses, driven one request per click.
            let devCache = try? DevImportResponseCache(root: DevImportResponseCache.defaultRoot())
            let runner = LivePSNBuildRunner(
                auth: auth, transport: transport, cache: cache, devCache: devCache)
            buildSteps = PSNBuildStepsModel(runner: runner)
            #endif
        } else {
            backend = InertImportBackend(
                source: ImportSourceID.psn, sourceLabel: "PlayStation", staging: staging)
        }

        let liveBuilt = backend is LivePSNImportBackend
        let account = PSNAccountModel(backend: backend, login: login)
        account.sessionExpiryProvider = expiryProvider
        account.vaultMatch = vaultMatch
        // Fill any PS Plus entries left from an earlier sync once at launch (PLAN §16).
        vaultMatch?.refreshAndRun()
        #if DEBUG
        account.buildSteps = buildSteps
        #endif
        let presenter = PSNImportPresenter(
            backend: backend, liveEnabled: liveBuilt, onLibraryChanged: onLibraryChanged)
        presenter.account = account
        account.onSyncRequested = { [weak presenter] in presenter?.syncNow() }
        // Keep the menu's signed-in check fresh before the user opens Settings.
        Task { await account.refresh() }

        return Wiring(account: account, presenter: presenter)
    }

    /// Build the importer, passing the dev cache + account label only in DEBUG.
    private static func makeImporter(
        auth: PSNAuth, transport: HTTPTransport, cache: ImportResponseCacheStore, accountLabel: String
    ) -> PSNImporter {
        #if DEBUG
        let devCache = try? DevImportResponseCache(root: DevImportResponseCache.defaultRoot())
        return PSNImporter(auth: auth, transport: transport, cache: cache,
                           accountLabel: accountLabel, devCache: devCache)
        #else
        return PSNImporter(auth: auth, transport: transport, cache: cache)
        #endif
    }
}

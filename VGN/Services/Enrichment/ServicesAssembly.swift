import Foundation

/// The one entry point the app container (the UI lane's `AppEnvironment`) uses to
/// build the whole services graph from an ``AppDatabase`` and a ``SecretStoring``.
///
/// It wires: an ``IGDBClient`` (credentials closure over
/// ``SecretsCredentialsProvider``, DB-backed catalogue cache, bundled
/// ``PlatformCatalog``), a ``CoverStore`` over the real Application Support
/// directories, the ``EnrichmentJobStore`` + ``EnrichmentCoordinator``, and the
/// Settings ``IGDBConnectionTester``. The UI injects `graph.coverStore` wherever a
/// `CoverLoading` is needed (the conformance ships in this lane).
enum ServicesFactory {

    /// The wired, ready-to-use services graph.
    struct Graph: Sendable {
        let igdbClient: IGDBClient
        let coverStore: CoverStore
        let catalogCache: CatalogCacheStore
        let jobStore: EnrichmentJobStore
        let coordinator: EnrichmentCoordinator
        let connectionTester: IGDBConnectionTester
        /// Reusable credentials probe (`nil` until the user enters credentials).
        let credentials: @Sendable () async -> IGDBCredentials?
    }

    /// Build the production graph. `transport` is injectable for a live smoke test;
    /// production uses `URLSessionTransport`.
    static func make(
        database: AppDatabase,
        secrets: any SecretStoring,
        bundle: Bundle = .main,
        transport: HTTPTransport = URLSessionTransport(),
        coversDirectory: URL? = nil,
        thumbsDirectory: URL? = nil,
        libretroIndexDirectory: URL? = nil
    ) throws -> Graph {
        let catalog = try PlatformCatalog.loadFromBundle(bundle)
        let provider = SecretsCredentialsProvider(store: secrets)
        let credentials: @Sendable () async -> IGDBCredentials? = {
            guard let pair = await provider.igdbCredentials() else { return nil }
            return IGDBCredentials(clientID: pair.clientID, secret: pair.secret)
        }

        let catalogCache = CatalogCacheStore(database)
        let igdbClient = IGDBClient(
            transport: transport,
            credentials: credentials,
            catalog: catalog,
            cache: catalogCache
        )

        let coversDir = try coversDirectory ?? VGNAppSupport.coversDirectory()
        let thumbsDir = try thumbsDirectory ?? VGNAppSupport.thumbsDirectory()
        let listingDir = try libretroIndexDirectory ?? VGNAppSupport.libretroIndexDirectory()
        let listing = LibretroRepoListing(transport: transport, cacheDirectory: listingDir)
        let chain = CoverProviderChain(catalog: catalog, listing: listing)
        let coverStore = CoverStore(
            chain: chain,
            transport: transport,
            coversDirectory: coversDir,
            thumbsDirectory: thumbsDir
        )

        let jobStore = EnrichmentJobStore(database)
        let coordinator = EnrichmentCoordinator(
            jobStore: jobStore,
            libraryStore: LibraryStore(database),
            catalogCache: catalogCache,
            igdbClient: igdbClient,
            coverStore: coverStore,
            credentials: credentials
        )
        let connectionTester = IGDBConnectionTester(transport: transport, catalog: catalog)

        return Graph(
            igdbClient: igdbClient,
            coverStore: coverStore,
            catalogCache: catalogCache,
            jobStore: jobStore,
            coordinator: coordinator,
            connectionTester: connectionTester,
            credentials: credentials
        )
    }
}

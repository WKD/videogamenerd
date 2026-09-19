import Foundation

/// GOG as a ``LibraryImporter`` (PLAN §14). Authenticates, fetches the three data sets
/// cache-first through a fresh ``GOGClient`` (one per sync), runs the per-page + cross-
/// page validation of §14.2, maps products to staging rows with ``GOGMapping``, and
/// reports coarse progress. Owned-only, PC/Mac; no play time (PLAN §14 non-goals).
struct GOGImporter: LibraryImporter, Sendable {
    let auth: GOGAuth
    let transport: HTTPTransport
    let cache: ImportResponseCacheStore
    var platformPolicy: ImportPlatformPolicy
    var pacing: ImportPolicy.Pacing
    var clock: ServiceClock
    var wallClock: @Sendable () -> Date
    var cacheTTL: TimeInterval

    init(auth: GOGAuth,
         transport: HTTPTransport,
         cache: ImportResponseCacheStore,
         platformPolicy: ImportPlatformPolicy = .macWhenAvailable,
         pacing: ImportPolicy.Pacing = ImportPolicy.gog,
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL) {
        self.auth = auth
        self.transport = transport
        self.cache = cache
        self.platformPolicy = platformPolicy
        self.pacing = pacing
        self.clock = clock
        self.wallClock = wallClock
        self.cacheTTL = cacheTTL
    }

    let source = ImportSourceID.gog

    /// GOG data sets and their cold-fetch request cost (PLAN §14.2 Force-refresh).
    /// The library estimate is nominal until page 1 reveals `totalPages`.
    var dataSets: [ImportDataSet] {
        [
            ImportDataSet(id: GOGEndpoint.userData, title: "Account", estimatedRequests: 1),
            ImportDataSet(id: GOGEndpoint.ownedGames, title: "Owned games", estimatedRequests: 1),
            ImportDataSet(id: GOGEndpoint.filteredProducts, title: "Library", estimatedRequests: 5),
        ]
    }

    /// Ensure a valid token (refreshing if needed); throws `.notAuthenticated` if the
    /// user must sign in.
    func authenticate() async throws {
        _ = try await auth.validAccessToken()
    }

    func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
        progress(ImportProgress(phase: .authenticating))
        try await authenticate()

        let client = GOGClient(
            transport: transport, auth: auth, cache: cache, pacing: pacing,
            clock: clock, wallClock: wallClock, cacheTTL: cacheTTL)

        // Account (username is scrubbed from any later reject).
        progress(ImportProgress(phase: .fetching, detail: "Account"))
        let user = try await client.userData()
        if let username = user.username { await client.addRedactionLiteral(username) }

        // Owned ids (cross-check baseline).
        progress(ImportProgress(phase: .fetching, detail: "Owned games"))
        let owned = Set(try await client.ownedIDs())

        // Library pages, validated per page + across pages (PLAN §14.2).
        var products: [GOGProduct] = []
        var seenIDs = Set<String>()
        var totalPages: Int?
        var totalProducts: Int?
        var pageKeys: [String] = []
        var page = 1
        while true {
            let context = ImportValidationContext(
                endpoint: GOGEndpoint.filteredProducts, expectedPage: page,
                expectedTotalPages: totalPages, expectedTotalProducts: totalProducts,
                seenIDs: seenIDs)
            let pageDTO = try await client.productsPage(page, context: context)
            if totalPages == nil { totalPages = pageDTO.totalPages }
            if totalProducts == nil { totalProducts = pageDTO.totalProducts }
            products.append(contentsOf: pageDTO.products)
            for product in pageDTO.products { seenIDs.insert(String(product.id)) }
            pageKeys.append(GOGClient.productsKey(page: page))
            progress(ImportProgress(phase: .fetching, completed: page, total: totalPages,
                                    detail: "Library page \(page)"))

            if await client.reachedRateLimitEnd { break }        // 429: the sync ends
            guard let pages = totalPages, page < pages else { break }
            page += 1
        }

        let endedEarly = await client.reachedRateLimitEnd

        // Σ products == totalProducts, unless we stopped early on a rate limit.
        if !endedEarly, let total = totalProducts,
           !GOGResponseValidator.sumMatchesTotal(seenCount: products.count, totalProducts: total) {
            try await recordSumReject(seen: products.count, total: total)
        }

        // Owned-ids ↔ pages gap: reported, not fatal (PLAN §14.2). Surfaced in the sync
        // summary's header note; a gap never stops the sync.
        let ownedGap = GOGResponseValidator.ownedGap(pageIDs: products.map(\.id), ownedIDs: owned).count

        // Manifest for resume + Settings (PLAN §14.2).
        if let pages = totalPages, let total = totalProducts, !endedEarly {
            try await cache.storeManifest(
                source: source, key: Self.productsManifestKey,
                ImportPageManifest(totalItems: total, totalPages: pages, pageKeys: pageKeys),
                fetchedAt: wallClock(), expiresAt: wallClock().addingTimeInterval(cacheTTL))
        }

        progress(ImportProgress(phase: .staging))
        let rows = GOGMapping.stagingRows(for: products, policy: platformPolicy)
        return ImportFetchResult(
            rows: rows, fromCache: await client.fromCache,
            fromNetwork: await client.fromNetwork, budgetUsed: await client.budgetUsed,
            ownedGap: ownedGap)
    }

    static let productsManifestKey = "account/getFilteredProducts:manifest"

    private func recordSumReject(seen: Int, total: Int) async throws -> Void {
        let redactor = ImportRedactor(literals: await auth.redactionLiterals())
        let reject = ImportReject(
            source: source, endpoint: GOGEndpoint.filteredProducts, status: 200,
            reason: .incoherentPaging,
            redactedExcerpt: "sum(products)=\(seen) != totalProducts=\(total)",
            receivedAt: wallClock())
        try? await cache.recordReject(reject, redact: redactor.closure)
        throw ImportError.rejected(reject)
    }
}

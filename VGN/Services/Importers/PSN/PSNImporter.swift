import Foundation

/// PSN as a ``LibraryImporter`` (PLAN §13). Authenticates, then for each data set **probes
/// first** (one tiny cached-or-network request — "small first, cached always", PLAN §13.5)
/// and only then pages the full list, all cache-first through a fresh ``PSNClient`` (one per
/// sync). Trophy titles are the launch history (the only PS3/Vita source); the game list
/// adds play time; purchases add owned-digital + PS Plus. Maps everything to staging rows
/// with ``PSNMapping``. On any bogus response it throws ``ImportError/rejected(_:)`` and the
/// sync stops (PLAN §13.5) — it never retries a variant.
struct PSNImporter: LibraryImporter, Sendable {
    let auth: PSNAuth
    let transport: HTTPTransport
    let cache: ImportResponseCacheStore
    /// Include the (fragile) GraphQL purchases data set. The wiring lane sets this false to
    /// ship owned-digital later without blocking the milestone if S6 has not passed (PLAN §13.5).
    var includePurchases: Bool
    var pacing: ImportPolicy.Pacing
    var clock: ServiceClock
    var wallClock: @Sendable () -> Date
    var cacheTTL: TimeInterval
    /// `test` / `real` — scopes the probe marker + the DEBUG dev-cache folder (PLAN §13.3).
    var accountLabel: String

    #if DEBUG
    /// The development response cache (build only, DEBUG). nil in normal use.
    var devCache: DevImportResponseCache?
    #endif

    let source = ImportSourceID.psn

    /// The full-fetch page sizes (PLAN §13.3 — trophy 800, game list 200) and the purchases
    /// page size (kept modest; the GraphQL op is the fragile one).
    static let trophyPageSize = 800
    static let gameListPageSize = 200
    static let purchasesPageSize = 100

    #if DEBUG
    init(auth: PSNAuth, transport: HTTPTransport, cache: ImportResponseCacheStore,
         includePurchases: Bool = true,
         pacing: ImportPolicy.Pacing = ImportPolicy.psn,
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL,
         accountLabel: String = "real",
         devCache: DevImportResponseCache? = nil) {
        self.auth = auth
        self.transport = transport
        self.cache = cache
        self.includePurchases = includePurchases
        self.pacing = pacing
        self.clock = clock
        self.wallClock = wallClock
        self.cacheTTL = cacheTTL
        self.accountLabel = accountLabel
        self.devCache = devCache
    }
    #else
    init(auth: PSNAuth, transport: HTTPTransport, cache: ImportResponseCacheStore,
         includePurchases: Bool = true,
         pacing: ImportPolicy.Pacing = ImportPolicy.psn,
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL,
         accountLabel: String = "real") {
        self.auth = auth
        self.transport = transport
        self.cache = cache
        self.includePurchases = includePurchases
        self.pacing = pacing
        self.clock = clock
        self.wallClock = wallClock
        self.cacheTTL = cacheTTL
        self.accountLabel = accountLabel
    }
    #endif

    var dataSets: [ImportDataSet] {
        // Estimates reflect the live probes (2026-09-20): trophy titles 265 → 1 page at 800;
        // game list 231 → 2 pages at 200; purchases 581 → ceil(581/100) = 6 pages at 100.
        var sets = [
            ImportDataSet(id: PSNEndpoint.profile, title: "Profile", estimatedRequests: 1),
            ImportDataSet(id: PSNEndpoint.trophyTitles, title: "Trophy titles", estimatedRequests: 1),
            ImportDataSet(id: PSNEndpoint.gameList, title: "Game list", estimatedRequests: 2),
        ]
        if includePurchases {
            sets.append(ImportDataSet(id: PSNEndpoint.purchases, title: "Purchases", estimatedRequests: 6))
        }
        return sets
    }

    func authenticate() async throws {
        _ = try await auth.validAccessToken()
    }

    func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
        progress(ImportProgress(phase: .authenticating))
        try await authenticate()

        let client = makeClient()

        // Profile — the token-is-mine sanity check; ids scrubbed from any later reject.
        progress(ImportProgress(phase: .fetching, detail: "Profile"))
        let profile = try await client.profile()
        if let onlineId = profile.onlineId { await client.addRedactionLiteral(onlineId) }
        if let accountId = profile.accountId { await client.addRedactionLiteral(accountId) }

        // Trophy titles (probe → full). ONE list — the endpoint returns every title of the
        // account whatever the (unsent) `npServiceName`; each title carries its own
        // `npServiceName` (live, 2026-09-20). `seen` also guards against the same
        // `npCommunicationId` ever appearing twice.
        var trophyTitles: [PSNTrophyTitle] = []
        progress(ImportProgress(phase: .fetching, detail: "Trophy titles"))
        try await client.probe(.trophyTitles)
        var trophyOffset = 0
        var trophySeen = Set<String>()
        while true {
            let page = try await client.trophyTitlesPage(
                limit: Self.trophyPageSize, offset: trophyOffset, seenIDs: trophySeen)
            for t in page.trophyTitles where trophySeen.insert(t.npCommunicationId).inserted {
                trophyTitles.append(t)
            }
            if await client.reachedRateLimitEnd { break }
            guard let next = page.nextOffset, next > trophyOffset, !page.trophyTitles.isEmpty,
                  trophySeen.count < page.totalItemCount else { break }
            trophyOffset = next
        }

        // Game list (probe → full).
        var gameList: [PSNGameListTitle] = []
        if !(await client.reachedRateLimitEnd) {
            progress(ImportProgress(phase: .fetching, detail: "Game list"))
            try await client.probe(.gameList)
            var offset = 0
            var seen = Set<String>()
            while true {
                let page = try await client.gameListPage(
                    limit: Self.gameListPageSize, offset: offset, seenIDs: seen)
                gameList.append(contentsOf: page.titles)
                for t in page.titles { seen.insert(t.titleId) }
                if await client.reachedRateLimitEnd { break }
                guard let next = page.nextOffset, next > offset, !page.titles.isEmpty,
                      seen.count < page.totalItemCount else { break }
                offset = next
            }
        }

        // Purchases (probe → full) — the fragile GraphQL op; optional (PLAN §13.5 S6).
        var purchases: [PSNPurchasedGame] = []
        if includePurchases, !(await client.reachedRateLimitEnd) {
            progress(ImportProgress(phase: .fetching, detail: "Purchases"))
            try await client.probe(.purchases)
            var start = 0
            while true {
                let page = try await client.purchasesPage(size: Self.purchasesPageSize, start: start)
                let games = page.data?.purchasedTitlesRetrieve?.games ?? []
                purchases.append(contentsOf: games)
                if await client.reachedRateLimitEnd { break }
                // Sony tells us when to stop (`pageInfo.isLast` / `totalCount`, seen live);
                // the short-page rule stays as the fallback when `pageInfo` is absent.
                let info = page.data?.purchasedTitlesRetrieve?.pageInfo
                if info?.isLast == true { break }
                if let total = info?.totalCount, purchases.count >= total { break }
                guard !games.isEmpty, games.count == Self.purchasesPageSize else { break }
                start += Self.purchasesPageSize
            }
        }

        progress(ImportProgress(phase: .staging))
        let rows = PSNMapping.stagingRows(trophyTitles: trophyTitles, gameList: gameList, purchases: purchases)
        return ImportFetchResult(
            rows: rows, fromCache: await client.fromCache,
            fromNetwork: await client.fromNetwork, budgetUsed: await client.budgetUsed)
    }

    private func makeClient() -> PSNClient {
        #if DEBUG
        return PSNClient(transport: transport, auth: auth, cache: cache, pacing: pacing,
                         clock: clock, wallClock: wallClock, cacheTTL: cacheTTL,
                         accountLabel: accountLabel, devCache: devCache)
        #else
        return PSNClient(transport: transport, auth: auth, cache: cache, pacing: pacing,
                         clock: clock, wallClock: wallClock, cacheTTL: cacheTTL,
                         accountLabel: accountLabel)
        #endif
    }
}

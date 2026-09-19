import Foundation

/// The PSN account-API client (PLAN §13.4). An **actor**, so requests are serial by
/// construction; every request is allow-listed, paced (≥ 1.5 s jittered), budgeted
/// (hard 40/sync), validated, and read **cache-first** through ``ImportResponseCacheStore``
/// (and, in DEBUG only, the development cache — a re-run costs zero requests). On any bogus
/// response it records a redacted reject and throws ``ImportError/rejected(_:)`` — it never
/// retries a variant, another parameter, endpoint or host (PLAN §13.5). The only retries
/// the data-encoded ``ImportRetryPolicy`` permits: one token refresh on 401, one
/// `Retry-After` wait on 429 (after which the sync ends).
///
/// **Probe support is first-class** (PLAN §13.5 "Small first, cached always"): every list
/// call takes `limit`/`offset`; ``probe(_:)`` is exactly ONE request with the smallest
/// sensible limit (10); and a **full fetch refuses** to run for a data set that has no
/// successful probe recorded for the current account — so "full run before a probe" is
/// impossible by construction.
///
/// One client instance is a **single sync**: it owns that sync's budget, retry flags and
/// tallies. Everything (transport, clock, wall clock, dev cache) is injected, so tests run
/// entirely offline with a `ManualClock`.
actor PSNClient {
    /// The three PSN data sets a probe / full fetch operates on.
    enum DataSet: Sendable, Hashable {
        case trophyTitles(service: String)   // `trophy` (PS3/Vita) or `trophy2` (PS4/PS5)
        case gameList
        case purchases

        var probeMarkerKey: String {
            switch self {
            case .trophyTitles(let s): return "probe:trophyTitles:\(s)"
            case .gameList: return "probe:gameList"
            case .purchases: return "probe:purchases"
            }
        }
    }

    /// A full fetch attempted before its probe (PLAN §13.5 — impossible by construction).
    enum ClientError: Error, Sendable, Equatable { case probeRequired(String) }

    private let transport: HTTPTransport
    private let auth: PSNAuth
    private let cache: ImportResponseCacheStore
    private let validator: PSNResponseValidator
    private let allowList: ImportAllowList
    private let pacer: ImportRequestPacer
    private let retryPolicy: ImportRetryPolicy
    private let pacing: ImportPolicy.Pacing
    private let clock: ServiceClock
    private let wallClock: @Sendable () -> Date
    private let cacheTTL: TimeInterval
    /// `test` / `real` — scopes the probe marker + the DEBUG dev-cache folder (PLAN §13.3).
    private let accountLabel: String
    #if DEBUG
    private let devCache: DevImportResponseCache?
    #endif

    private var budget: ImportRequestBudget
    private var extraRedactionLiterals: [String] = []

    private(set) var fromCache = 0
    private(set) var fromNetwork = 0
    private(set) var reachedRateLimitEnd = false
    private var hasRefreshedToken = false
    private var hasWaited429 = false

    private static let profileURL = URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles")!
    private static let trophyBase = "https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles"
    private static let gameListBase = "https://m.np.playstation.com/api/gamelist/v2/users/me/titles"
    private static let graphQLBase = "https://web.np.playstation.com/api/graphql/v1/op"
    /// The `getPurchasedGameList` persisted-query hash (psn-api, commit 1e9d9a8…).
    /// ASSUMPTION(S0): the hash is current — **most likely to fail** at S6 (PLAN §13.3).
    static let purchasedGamesHash = "827a423f6a8ddca4107ac01395af2ec0eafd8396fc7fa204aaf9b7ed2eefa168"
    static let purchasedGamesOperation = "getPurchasedGameList"

    #if DEBUG
    init(transport: HTTPTransport, auth: PSNAuth, cache: ImportResponseCacheStore,
         validator: PSNResponseValidator = PSNResponseValidator(),
         allowList: ImportAllowList = .psn,
         pacing: ImportPolicy.Pacing = ImportPolicy.psn,
         retryPolicy: ImportRetryPolicy = ImportRetryPolicy(),
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL,
         accountLabel: String = "real",
         devCache: DevImportResponseCache? = nil,
         pacer: ImportRequestPacer? = nil) {
        self.transport = transport
        self.auth = auth
        self.cache = cache
        self.validator = validator
        self.allowList = allowList
        self.pacing = pacing
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.wallClock = wallClock
        self.cacheTTL = cacheTTL
        self.accountLabel = accountLabel
        self.devCache = devCache
        self.budget = ImportRequestBudget(limit: pacing.budget)
        self.pacer = pacer ?? ImportRequestPacer(pacing: pacing, clock: clock)
    }
    #else
    init(transport: HTTPTransport, auth: PSNAuth, cache: ImportResponseCacheStore,
         validator: PSNResponseValidator = PSNResponseValidator(),
         allowList: ImportAllowList = .psn,
         pacing: ImportPolicy.Pacing = ImportPolicy.psn,
         retryPolicy: ImportRetryPolicy = ImportRetryPolicy(),
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL,
         accountLabel: String = "real",
         pacer: ImportRequestPacer? = nil) {
        self.transport = transport
        self.auth = auth
        self.cache = cache
        self.validator = validator
        self.allowList = allowList
        self.pacing = pacing
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.wallClock = wallClock
        self.cacheTTL = cacheTTL
        self.accountLabel = accountLabel
        self.budget = ImportRequestBudget(limit: pacing.budget)
        self.pacer = pacer ?? ImportRequestPacer(pacing: pacing, clock: clock)
    }
    #endif

    var budgetUsed: Int { budget.used }

    func addRedactionLiteral(_ literal: String) { extraRedactionLiterals.append(literal) }

    // MARK: - Probe (exactly one request, smallest limit)

    static let probeLimit = 10

    /// Exactly ONE request with the smallest sensible limit (10), used by the live steps
    /// (S3a etc.) to prove auth, headers, DTO and validator before any full fetch. On
    /// success the probe marker for `(dataSet, account)` is recorded, which unlocks the
    /// full fetch. Returns the item count seen.
    @discardableResult
    func probe(_ dataSet: DataSet) async throws -> Int {
        let count: Int
        switch dataSet {
        case .trophyTitles(let service):
            count = try await trophyTitlesPage(service: service, limit: Self.probeLimit,
                                               offset: 0, requireProbe: false).trophyTitles.count
        case .gameList:
            count = try await gameListPage(limit: Self.probeLimit, offset: 0,
                                           requireProbe: false).titles.count
        case .purchases:
            count = try await purchasesPage(size: Self.probeLimit, start: 0,
                                            requireProbe: false).data?.purchasedTitlesRetrieve?.games?.count ?? 0
        }
        try await recordProbe(dataSet)
        return count
    }

    /// Whether a successful probe is on record for `(dataSet, account)` — the full-fetch
    /// unlock (PLAN §13.5).
    func hasProbe(for dataSet: DataSet) async throws -> Bool {
        try await cache.manifest(source: ImportSourceID.psn,
                                 key: markerKey(dataSet)) != nil
    }

    private func recordProbe(_ dataSet: DataSet) async throws {
        try await cache.storeManifest(
            source: ImportSourceID.psn, key: markerKey(dataSet),
            ImportPageManifest(totalItems: 1, totalPages: 1),
            fetchedAt: wallClock(), expiresAt: wallClock().addingTimeInterval(cacheTTL))
    }

    private func markerKey(_ dataSet: DataSet) -> String { "\(dataSet.probeMarkerKey):\(accountLabel)" }

    private func requireProbe(_ dataSet: DataSet) async throws {
        guard try await hasProbe(for: dataSet) else {
            throw ClientError.probeRequired(markerKey(dataSet))
        }
    }

    // MARK: - Endpoints

    func profile() async throws -> PSNProfile {
        let data = try await fetchValidated(
            key: PSNEndpoint.profile, endpoint: PSNEndpoint.profile, devEndpoint: "profile",
            spec: PSNRequestSpec(url: Self.profileURL),
            context: ImportValidationContext(endpoint: PSNEndpoint.profile))
        guard let dto = try? PSNJSON.decoder.decode(PSNProfile.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: PSNEndpoint.profile, status: 200, body: data)
        }
        return dto
    }

    /// One trophy-titles page. `service` = `trophy` (PS3/Vita) or `trophy2` (PS4/PS5).
    /// A full page (`limit` 800) refuses to run unless a probe is on record.
    func trophyTitlesPage(service: String, limit: Int, offset: Int,
                          requireProbe requiresProbe: Bool = true,
                          seenIDs: Set<String> = []) async throws -> PSNTrophyTitlesPage {
        if requiresProbe { try await requireProbe(.trophyTitles(service: service)) }
        let key = "trophyTitles?npServiceName=\(service)&limit=\(limit)&offset=\(offset)"
        var comps = URLComponents(string: Self.trophyBase)!
        comps.queryItems = [.init(name: "npServiceName", value: service),
                            .init(name: "limit", value: String(limit)),
                            .init(name: "offset", value: String(offset))]
        let data = try await fetchValidated(
            key: key, endpoint: PSNEndpoint.trophyTitles, devEndpoint: "trophyTitles-\(service)",
            spec: PSNRequestSpec(url: comps.url!),
            context: ImportValidationContext(endpoint: PSNEndpoint.trophyTitles, seenIDs: seenIDs))
        guard let dto = try? PSNJSON.decoder.decode(PSNTrophyTitlesPage.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: PSNEndpoint.trophyTitles, status: 200, body: data)
        }
        return dto
    }

    func gameListPage(limit: Int, offset: Int, requireProbe requiresProbe: Bool = true,
                      seenIDs: Set<String> = []) async throws -> PSNGameListPage {
        if requiresProbe { try await requireProbe(.gameList) }
        let key = "gameList?limit=\(limit)&offset=\(offset)"
        var comps = URLComponents(string: Self.gameListBase)!
        comps.queryItems = [.init(name: "limit", value: String(limit)),
                            .init(name: "offset", value: String(offset))]
        let data = try await fetchValidated(
            key: key, endpoint: PSNEndpoint.gameList, devEndpoint: "gameList",
            spec: PSNRequestSpec(url: comps.url!),
            context: ImportValidationContext(endpoint: PSNEndpoint.gameList, seenIDs: seenIDs))
        guard let dto = try? PSNJSON.decoder.decode(PSNGameListPage.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: PSNEndpoint.gameList, status: 200, body: data)
        }
        return dto
    }

    func purchasesPage(size: Int, start: Int, requireProbe requiresProbe: Bool = true,
                       seenIDs: Set<String> = []) async throws -> PSNPurchasedGamesEnvelope {
        if requiresProbe { try await requireProbe(.purchases) }
        let key = "purchases?size=\(size)&start=\(start)"
        let data = try await fetchValidated(
            key: key, endpoint: PSNEndpoint.purchases, devEndpoint: "purchases",
            spec: PSNRequestSpec(url: Self.purchasesURL(size: size, start: start)),
            context: ImportValidationContext(endpoint: PSNEndpoint.purchases, seenIDs: seenIDs))
        guard let dto = try? PSNJSON.decoder.decode(PSNPurchasedGamesEnvelope.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: PSNEndpoint.purchases, status: 200, body: data)
        }
        return dto
    }

    /// The GraphQL persisted-query URL for `getPurchasedGameList` (PLAN §13.3).
    static func purchasesURL(size: Int, start: Int) -> URL {
        let variables: [String: Any] = [
            "isActive": true, "platform": ["ps4", "ps5"],
            "size": size, "start": start,
            "sortBy": "ACTIVE_DATE", "sortDirection": "desc",
        ]
        let extensions: [String: Any] = [
            "persistedQuery": ["version": 1, "sha256Hash": purchasedGamesHash],
        ]
        func json(_ obj: Any) -> String {
            (try? String(decoding: JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)) ?? "{}"
        }
        var comps = URLComponents(string: graphQLBase)!
        comps.queryItems = [
            .init(name: "operationName", value: purchasedGamesOperation),
            .init(name: "variables", value: json(variables)),
            .init(name: "extensions", value: json(extensions)),
        ]
        return comps.url!
    }

    // MARK: - Core cache-first fetch

    /// A prepared request (minus the Bearer token, which is injected inside the retry
    /// loop so a 401 refresh uses the fresh token). PSN reads are all GET + Bearer.
    struct PSNRequestSpec: Sendable {
        var url: URL
        var method: String = "GET"
        var extraHeaders: [String: String] = [:]
    }

    private func fetchValidated(key: String, endpoint: String, devEndpoint: String,
                                spec: PSNRequestSpec,
                                context baseContext: ImportValidationContext) async throws -> Data {
        try allowList.check(spec.url)

        // Cache first: inside the 30-day window a sync makes zero requests (PLAN §13.2).
        if let fresh = try await cache.freshEntry(source: ImportSourceID.psn, key: key, now: wallClock()) {
            fromCache += 1
            return fresh.body
        }

        var context = baseContext
        if context.previousItemCount == nil {
            context.previousItemCount = try await cache.lastItemCount(source: ImportSourceID.psn, key: key)
        }

        #if DEBUG
        // Dev cache (build only): a recorded valid body means zero requests on a re-run.
        if let devCache,
           let body = devCache.read(source: ImportSourceID.psn, account: devAccount,
                                    endpoint: devEndpoint, paramsHash: DevImportResponseCache.paramsHash(key)) {
            let raw = ImportRawResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
            if case .valid(let count) = validator.validate(raw, context: context) {
                try await storeRuntimeCache(key: key, endpoint: endpoint, body: body, count: count)
                fromCache += 1
                return body
            }
        }
        #endif

        while true {
            try budget.consume()
            try await pacer.waitBeforeNextRequest()
            let token = try await auth.validAccessToken()
            let (data, response) = try await transport.data(for: Self.request(spec, token: token))
            let raw = ImportRawResponse(status: response.statusCode,
                                        headers: Self.headerDict(response), body: data)
            let decision = retryPolicy.decide(
                status: response.statusCode, retryAfter: response.retryAfterSeconds,
                hasRefreshedToken: hasRefreshedToken, hasWaited429: hasWaited429)
            switch decision {
            case .refreshTokenOnce:
                hasRefreshedToken = true
                _ = try await auth.forceRefresh()
                continue
            case .waitRetryAfterThenEnd(let after):
                hasWaited429 = true
                reachedRateLimitEnd = true
                try await clock.sleep(for: after ?? pacing.minDelay)
                continue
            case .stop:
                let reason = validator.validate(raw, context: context).reason ?? .unknown
                try await recordAndThrow(reason: reason, endpoint: endpoint,
                                         status: response.statusCode, body: data)
            case .proceed:
                switch validator.validate(raw, context: context) {
                case .rejected(let reason):
                    try await recordAndThrow(reason: reason, endpoint: endpoint,
                                             status: response.statusCode, body: data)
                case .valid(let count):
                    // Write-before-use: the dev cache is written before the runtime cache
                    // and before the body is returned (PLAN §13.5).
                    #if DEBUG
                    devCache?.write(source: ImportSourceID.psn, account: devAccount,
                                    endpoint: devEndpoint, paramsHash: DevImportResponseCache.paramsHash(key),
                                    requestURL: spec.url, status: 200, body: data, itemCount: count)
                    #endif
                    try await storeRuntimeCache(key: key, endpoint: endpoint, body: data, count: count)
                    fromNetwork += 1
                    return data
                }
            }
        }
    }

    private func storeRuntimeCache(key: String, endpoint: String, body: Data, count: Int) async throws {
        let fetchedAt = wallClock()
        let record = ImportCacheRecord(
            source: ImportSourceID.psn, key: key, endpoint: endpoint, paramsJSON: "{}",
            fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(cacheTTL),
            status: 200, body: body, itemCount: count, schemaVersion: 1)
        try await cache.store(record)
    }

    #if DEBUG
    private var devAccount: DevImportResponseCache.Account {
        accountLabel == "test" ? .test : .real
    }
    #endif

    /// Record a redacted reject (leaving the last good cache untouched) and stop.
    private func recordAndThrow(reason: ImportRejectReason, endpoint: String,
                                status: Int?, body: Data) async throws -> Never {
        let literals = await auth.redactionLiterals() + extraRedactionLiterals
        let redactor = ImportRedactor(literals: literals)
        let excerpt = redactor.redact(String(decoding: body.prefix(4096), as: UTF8.self))
        let reject = ImportReject(source: ImportSourceID.psn, endpoint: endpoint, status: status,
                                  reason: reason, redactedExcerpt: excerpt, receivedAt: wallClock())
        try? await cache.recordReject(reject, redact: redactor.closure)
        throw ImportError.rejected(reject)
    }

    // MARK: - Request helpers

    private static func request(_ spec: PSNRequestSpec, token: String) -> URLRequest {
        var request = URLRequest(url: spec.url)
        request.httpMethod = spec.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in spec.extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    private static func headerDict(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { out[k] = v }
        }
        return out
    }
}

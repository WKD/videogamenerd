import Foundation

/// The GOG account-API client (PLAN §14.4). An **actor**, so requests are serial by
/// construction; every request is allow-listed, paced, budgeted, validated and read
/// cache-first through ``ImportResponseCacheStore``. On any bogus response it records a
/// redacted reject and throws ``ImportError/rejected(_:)`` — it never retries a variant,
/// another parameter, endpoint or host (PLAN §14.5). The only retries are the ones the
/// data-encoded ``ImportRetryPolicy`` permits: one token refresh on 401, one
/// `Retry-After` wait on 429 (after which the sync ends).
///
/// One client instance is a **single sync**: it owns that sync's budget, retry flags and
/// cache/network tallies. The transport, clock and wall clock are injected, so tests run
/// entirely offline with a `ManualClock` and a controllable `Date` provider.
actor GOGClient {
    private let transport: HTTPTransport
    private let auth: GOGAuth
    private let cache: ImportResponseCacheStore
    private let validator: GOGResponseValidator
    private let allowList: ImportAllowList
    private let pacer: ImportRequestPacer
    private let retryPolicy: ImportRetryPolicy
    private let pacing: ImportPolicy.Pacing
    private let clock: ServiceClock
    private let wallClock: @Sendable () -> Date
    private let cacheTTL: TimeInterval

    private var budget: ImportRequestBudget
    private var extraRedactionLiterals: [String] = []

    // Per-sync tallies + one-shot retry flags.
    private(set) var fromCache = 0
    private(set) var fromNetwork = 0
    /// Set once the single 429 wait is spent — the sync must stop paging (PLAN §14.1).
    private(set) var reachedRateLimitEnd = false
    private var hasRefreshedToken = false
    private var hasWaited429 = false

    private static let embedBase = URL(string: "https://embed.gog.com/")!

    init(transport: HTTPTransport,
         auth: GOGAuth,
         cache: ImportResponseCacheStore,
         validator: GOGResponseValidator = GOGResponseValidator(),
         allowList: ImportAllowList = .gog,
         pacing: ImportPolicy.Pacing = ImportPolicy.gog,
         retryPolicy: ImportRetryPolicy = ImportRetryPolicy(),
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         cacheTTL: TimeInterval = ImportPolicy.cacheTTL,
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
        self.budget = ImportRequestBudget(limit: pacing.budget)
        self.pacer = pacer ?? ImportRequestPacer(pacing: pacing, clock: clock)
    }

    var budgetUsed: Int { budget.used }

    /// Add a literal (e.g. the username) to scrub from any recorded reject.
    func addRedactionLiteral(_ literal: String) { extraRedactionLiterals.append(literal) }

    // MARK: - Endpoints

    func userData() async throws -> GOGUserData {
        let data = try await fetchValidated(
            key: GOGEndpoint.userData, url: Self.embedBase.appendingPathComponent("userData.json"),
            endpoint: GOGEndpoint.userData,
            context: ImportValidationContext(endpoint: GOGEndpoint.userData))
        guard let dto = try? JSONDecoder().decode(GOGUserData.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: GOGEndpoint.userData, status: 200, body: data)
        }
        return dto
    }

    func ownedIDs() async throws -> [Int64] {
        let data = try await fetchValidated(
            key: GOGEndpoint.ownedGames, url: Self.embedBase.appendingPathComponent("user/data/games"),
            endpoint: GOGEndpoint.ownedGames,
            context: ImportValidationContext(endpoint: GOGEndpoint.ownedGames))
        guard let dto = try? JSONDecoder().decode(GOGOwnedGames.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: GOGEndpoint.ownedGames, status: 200, body: data)
        }
        return dto.owned
    }

    /// Fetch one library page. `context` carries the expected page + totals + already-seen
    /// ids so the validator can check paging coherence (PLAN §14.2).
    func productsPage(_ page: Int, context: ImportValidationContext) async throws -> GOGProductsPage {
        let data = try await fetchValidated(
            key: Self.productsKey(page: page), url: Self.productsURL(page: page),
            endpoint: GOGEndpoint.filteredProducts, context: context)
        guard let dto = try? JSONDecoder().decode(GOGProductsPage.self, from: data) else {
            try await recordAndThrow(reason: .schemaMismatch,
                                     endpoint: GOGEndpoint.filteredProducts, status: 200, body: data)
        }
        return dto
    }

    static func productsKey(page: Int) -> String { "account/getFilteredProducts?mediaType=1&page=\(page)" }

    static func productsURL(page: Int) -> URL {
        URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=\(page)")!
    }

    // MARK: - Core cache-first fetch

    private func fetchValidated(key: String, url: URL, endpoint: String,
                                context baseContext: ImportValidationContext) async throws -> Data {
        try allowList.check(url)

        // Cache first: inside the 30-day window a sync makes zero requests (PLAN §14.2).
        if let fresh = try await cache.freshEntry(source: ImportSourceID.gog, key: key, now: wallClock()) {
            fromCache += 1
            return fresh.body
        }

        var context = baseContext
        if context.previousItemCount == nil {
            context.previousItemCount = try await cache.lastItemCount(source: ImportSourceID.gog, key: key)
        }

        while true {
            try budget.consume()
            try await pacer.waitBeforeNextRequest()
            let token = try await auth.validAccessToken()
            let (data, response) = try await transport.data(for: Self.authorizedRequest(url: url, token: token))
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
                    let fetchedAt = wallClock()
                    let record = ImportCacheRecord(
                        source: ImportSourceID.gog, key: key, endpoint: endpoint, paramsJSON: "{}",
                        fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(cacheTTL),
                        status: 200, body: data, itemCount: count, schemaVersion: 1)
                    try await cache.store(record)
                    fromNetwork += 1
                    return data
                }
            }
        }
    }

    /// Record a redacted reject (leaving the last good cache untouched) and stop.
    private func recordAndThrow(reason: ImportRejectReason, endpoint: String,
                                status: Int?, body: Data) async throws -> Never {
        let literals = await auth.redactionLiterals() + extraRedactionLiterals
        let redactor = ImportRedactor(literals: literals)
        let excerpt = redactor.redact(String(decoding: body.prefix(4096), as: UTF8.self))
        let reject = ImportReject(source: ImportSourceID.gog, endpoint: endpoint, status: status,
                                  reason: reason, redactedExcerpt: excerpt, receivedAt: wallClock())
        try? await cache.recordReject(reject, redact: redactor.closure)
        throw ImportError.rejected(reject)
    }

    // MARK: - Request helpers

    private static func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

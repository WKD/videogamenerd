import Foundation

/// The live HowLongToBeat search client (PLAN §5.3). An **actor**, so requests are
/// serial by construction; every request is allow-listed (`howlongtobeat.com` only),
/// paced (≥ 1.5 s, jittered), budgeted, and — for the search response — validated.
/// On the first unexpected response it records a redacted reject and throws
/// ``ImportError/rejected(_:)``; there are **no retries and no variants** (PLAN §5.3).
///
/// Results are read cache-first through ``ImportResponseCacheStore`` with
/// `source = "hltb"`: a found match is cached 180 days, a "no result" 30 days, and a
/// cached answer (hit or miss) costs **zero** requests. The endpoint discovery and the
/// per-session `/init` auth token are resolved once per run and reused.
///
/// One instance is a single run: it owns that run's budget and cache/network tallies.
/// The transport, clock and wall clock are injected, so tests run entirely offline.
actor HLTBClient: HLTBSearching {
    private let transport: HTTPTransport
    private let cache: ImportResponseCacheStore
    private let validator: HLTBResponseValidator
    private let allowList: ImportAllowList
    private let pacing: ImportPolicy.Pacing
    private let pacer: ImportRequestPacer
    private let clock: ServiceClock
    private let wallClock: @Sendable () -> Date
    private let hitTTL: TimeInterval
    private let missTTL: TimeInterval
    /// A pre-resolved endpoint (tests inject a fixed one; live discovery finds it).
    private let injectedDiscovery: HLTBEndpoint.Discovery?
    /// Pre-resolved per-session auth (tests inject it to skip the `/init` round-trip).
    private let injectedAuth: HLTBEndpoint.Auth?
    private let maxDiscoveryScripts: Int

    private var budget: ImportRequestBudget
    private var discovery: HLTBEndpoint.Discovery?
    private var auth: HLTBEndpoint.Auth?

    private(set) var fromCache = 0
    private(set) var fromNetwork = 0

    /// Only `howlongtobeat.com` — every request (homepage, app chunk, search) matches.
    static let allowList = ImportAllowList(["https://howlongtobeat.com/"])

    init(transport: HTTPTransport,
         cache: ImportResponseCacheStore,
         validator: HLTBResponseValidator = HLTBResponseValidator(),
         allowList: ImportAllowList = HLTBClient.allowList,
         pacing: ImportPolicy.Pacing = ImportPolicy.hltb,
         clock: ServiceClock = SystemClock(),
         wallClock: @Sendable @escaping () -> Date = { Date() },
         hitTTL: TimeInterval = ImportPolicy.hltbHitTTL,
         missTTL: TimeInterval = ImportPolicy.hltbMissTTL,
         discovery: HLTBEndpoint.Discovery? = nil,
         auth: HLTBEndpoint.Auth? = nil,
         maxDiscoveryScripts: Int = 12,
         pacer: ImportRequestPacer? = nil) {
        self.transport = transport
        self.cache = cache
        self.validator = validator
        self.allowList = allowList
        self.pacing = pacing
        self.clock = clock
        self.wallClock = wallClock
        self.hitTTL = hitTTL
        self.missTTL = missTTL
        self.injectedDiscovery = discovery
        self.injectedAuth = auth
        self.maxDiscoveryScripts = maxDiscoveryScripts
        self.budget = ImportRequestBudget(limit: pacing.budget)
        self.pacer = pacer ?? ImportRequestPacer(pacing: pacing, clock: clock)
    }

    var budgetUsed: Int { budget.used }

    // MARK: - Search

    func search(title: String) async throws -> [HLTBCandidate] {
        try await search(title: title, policy: .cacheFirst)
    }

    /// Search with an explicit freshness policy (PLAN §5.3). `.cacheFirst` — every Fetch
    /// **and every Refresh** (wave 21, D3) — serves any entry inside its TTL (found 180 d /
    /// no-result 30 d) at **zero** requests; `.bypassOne` ("Ask HowLongToBeat Again")
    /// ignores the cache for this one lookup and stores the new reply.
    func search(title: String, policy: HLTBFreshnessPolicy) async throws -> [HLTBCandidate] {
        let key = Self.cacheKey(title: title)
        if policy == .cacheFirst,
           let fresh = try await cache.freshEntry(source: HLTBSource.id, key: key, now: wallClock()) {
            fromCache += 1
            return (try? HLTBEndpoint.parseCandidates(fresh.body)) ?? []
        }
        return try await fetchAndStore(title: title, key: key)
    }

    /// A valid cached reply for `title`, or nil — zero requests (the fill service's cache
    /// pass, wave 21 D3). A served entry counts as "from cache".
    func cachedCandidates(title: String) async -> [HLTBCandidate]? {
        guard let fresh = try? await cache.freshEntry(
            source: HLTBSource.id, key: Self.cacheKey(title: title), now: wallClock()) else { return nil }
        fromCache += 1
        return (try? HLTBEndpoint.parseCandidates(fresh.body)) ?? []
    }

    /// This run's "from cache · from network" tallies (bulk summary / single caption).
    func requestTally() async -> HLTBRequestTally {
        HLTBRequestTally(fromCache: fromCache, fromNetwork: fromNetwork)
    }

    /// The one network path: session setup, allow-list, budget, pacing, validation, and —
    /// on a valid reply only — a cache write. A reject records a redacted stop and throws.
    private func fetchAndStore(title: String, key: String) async throws -> [HLTBCandidate] {
        let (discovery, auth) = try await ensureSession()
        let request = HLTBEndpoint.searchRequest(title: title, discovery: discovery, auth: auth)
        try allowList.check(request.url!)
        try budget.consume()
        try await pacer.waitBeforeNextRequest()

        let (data, response) = try await transport.data(for: request)
        let raw = ImportRawResponse(status: response.statusCode,
                                    headers: Self.headerDict(response), body: data)
        switch validator.validate(raw, context: ImportValidationContext(endpoint: Self.searchEndpoint)) {
        case .rejected(let reason):
            try await recordAndThrow(reason: reason, endpoint: Self.searchEndpoint,
                                     status: response.statusCode, body: data)
        case .valid(let count):
            let fetchedAt = wallClock()
            let ttl = count > 0 ? hitTTL : missTTL   // "no result" retried sooner
            let record = ImportCacheRecord(
                source: HLTBSource.id, key: key, endpoint: Self.searchEndpoint, paramsJSON: "{}",
                fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ttl),
                status: 200, body: data, itemCount: count, schemaVersion: 1)
            try await cache.store(record)
            fromNetwork += 1
            return (try? HLTBEndpoint.parseCandidates(data)) ?? []
        }
    }

    // MARK: - id-keyed cache (D1/D4)

    /// Persist a chosen / linked candidate under its id-key so an exact refresh-by-id is one
    /// cached lookup (D1). Stores the candidate's own JSON (incl. its canonical HLTB name)
    /// at the 180-day hit TTL. Never issues a request.
    func rememberChosen(_ candidate: HLTBCandidate) async {
        guard let body = try? JSONEncoder().encode(candidate) else { return }
        let fetchedAt = wallClock()
        let record = ImportCacheRecord(
            source: HLTBSource.id, key: Self.idKey(candidate.id), endpoint: Self.searchEndpoint,
            paramsJSON: "{}", fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(hitTTL),
            status: 200, body: body, itemCount: 1, schemaVersion: 1)
        try? await cache.store(record)
    }

    /// The candidate remembered for `hltbID`, if still fresh (D4). Zero requests.
    func linkedCandidate(hltbID: Int64) async -> HLTBCandidate? {
        guard let entry = try? await cache.freshEntry(
            source: HLTBSource.id, key: Self.idKey(hltbID), now: wallClock()) else { return nil }
        return try? JSONDecoder().decode(HLTBCandidate.self, from: entry.body)
    }

    /// The age of the cached search reply for `title` (fresh or stale), or nil when uncached.
    func cacheAge(title: String, now: Date) async -> TimeInterval? {
        guard let entry = try? await cache.entry(source: HLTBSource.id, key: Self.cacheKey(title: title))
        else { return nil }
        return now.timeIntervalSince(entry.fetchedAt)
    }

    /// Cache key for a search — the normalised query, so the same title (any case /
    /// spacing) hits the same entry.
    static func cacheKey(title: String) -> String {
        "search:" + TitleNormalizer.normalize(title, level: .canonical)
    }

    /// Cache key for a chosen candidate, keyed by its HLTB id (D1/D4).
    static func idKey(_ hltbID: Int64) -> String { "id:\(hltbID)" }

    static let searchEndpoint = "hltb/search"
    static let discoveryEndpoint = "hltb/discovery"
    static let authEndpoint = "hltb/auth"

    // MARK: - Session (endpoint discovery + per-session auth token, once per run)

    /// Resolve — once per run — the search endpoint and the `/init` auth token, and
    /// cache both in memory. Done lazily on the first search that misses the cache, so a
    /// fully-cached run makes zero requests. The auth token embeds the caller IP + UA
    /// and expires; a lapse later surfaces as a 403 reject on the search (we stop, the
    /// owner re-runs) — no in-run refresh (PLAN §5.3: no retries, no variants).
    /// A token-only `/init` (the site's shape since 2026-09-24) is a valid session; a reply
    /// without a string `token` is a schemaMismatch reject on `hltb/auth`.
    private func ensureSession() async throws -> (HLTBEndpoint.Discovery, HLTBEndpoint.Auth) {
        let discovery = try await ensureDiscovery()
        if let a = auth { return (discovery, a) }
        if let injected = injectedAuth { auth = injected; return (discovery, injected) }

        let data = try await getData(request: HLTBEndpoint.authInitRequest(discovery: discovery),
                                     endpoint: Self.authEndpoint)
        guard let resolved = HLTBEndpoint.parseAuth(data) else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: Self.authEndpoint,
                                     status: 200, body: data)
        }
        auth = resolved
        return (discovery, resolved)
    }

    private func ensureDiscovery() async throws -> HLTBEndpoint.Discovery {
        if let d = discovery { return d }
        if let injected = injectedDiscovery { discovery = injected; return injected }

        // Homepage → app chunks → resolve the search path.
        let homeHTML = try await getText(request: HLTBEndpoint.homepageRequest())
        let scripts = HLTBEndpoint.scriptPaths(inHTML: homeHTML)
        for path in scripts.prefix(maxDiscoveryScripts) {
            let js = try await getText(request: HLTBEndpoint.scriptRequest(path: path))
            if let resolved = HLTBEndpoint.resolveDiscovery(fromScript: js) {
                discovery = resolved
                return resolved
            }
        }
        // Nothing found — fall back to the historical constant path; a stale endpoint
        // then surfaces as a wrong-status / HTML reject on the search itself.
        let fb = HLTBEndpoint.Discovery.fallback
        discovery = fb
        return fb
    }

    /// GET a discovery / auth document (homepage, app chunk, or `/init`). Any non-200 or
    /// empty body is a failure → a `schemaMismatch` reject (a clean stop).
    private func getData(request: URLRequest, endpoint: String) async throws -> Data {
        try allowList.check(request.url!)
        try budget.consume()
        try await pacer.waitBeforeNextRequest()
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200, !data.isEmpty else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: endpoint,
                                     status: response.statusCode, body: data)
        }
        return data
    }

    private func getText(request: URLRequest) async throws -> String {
        String(decoding: try await getData(request: request, endpoint: Self.discoveryEndpoint), as: UTF8.self)
    }

    // MARK: - Reject

    /// Record a reject and stop. Never logs a full body (the excerpt is capped at 4 KB),
    /// and the excerpt goes through ``ImportRedactor`` first: HowLongToBeat's `/init`
    /// token embeds the caller's **public IP** and User-Agent (base64), so a stored
    /// `{"token":"…"}` excerpt keeps its shape but not the value (wave 21 E).
    private func recordAndThrow(reason: ImportRejectReason, endpoint: String,
                                status: Int?, body: Data) async throws -> Never {
        let excerpt = ImportRedactor.structural.redact(
            String(String(decoding: body.prefix(4096), as: UTF8.self)))
        let reject = ImportReject(source: HLTBSource.id, endpoint: endpoint, status: status,
                                  reason: reason, redactedExcerpt: excerpt, receivedAt: wallClock())
        try? await cache.recordReject(reject, redact: ImportRedactor.structural.closure)
        throw ImportError.rejected(reject)
    }

    private static func headerDict(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { out[k] = v }
        }
        return out
    }
}

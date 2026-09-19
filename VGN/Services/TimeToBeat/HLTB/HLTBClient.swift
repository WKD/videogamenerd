import Foundation

/// The live HowLongToBeat search client (PLAN §5.3). An **actor**, so requests are
/// serial by construction; every request is allow-listed (`howlongtobeat.com` only),
/// paced (≥ 1.5 s, jittered), budgeted, and — for the search response — validated.
/// On the first unexpected response it records a redacted reject and throws
/// ``ImportError/rejected(_:)``; there are **no retries and no variants** (PLAN §5.3).
///
/// Results are read cache-first through ``ImportResponseCacheStore`` with
/// `source = "hltb"`: a found match is cached 180 days, a "no result" 30 days, and a
/// cached answer (hit or miss) costs **zero** requests. The endpoint discovery is done
/// once per run and reused.
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
    private let maxDiscoveryScripts: Int

    private var budget: ImportRequestBudget
    private var discovery: HLTBEndpoint.Discovery?

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
         maxDiscoveryScripts: Int = 4,
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
        self.maxDiscoveryScripts = maxDiscoveryScripts
        self.budget = ImportRequestBudget(limit: pacing.budget)
        self.pacer = pacer ?? ImportRequestPacer(pacing: pacing, clock: clock)
    }

    var budgetUsed: Int { budget.used }

    // MARK: - Search

    func search(title: String) async throws -> [HLTBCandidate] {
        let key = Self.cacheKey(title: title)

        // Cache first: inside the window a search makes zero requests (PLAN §5.3).
        if let fresh = try await cache.freshEntry(source: HLTBSource.id, key: key, now: wallClock()) {
            fromCache += 1
            return (try? HLTBEndpoint.parseCandidates(fresh.body)) ?? []
        }

        let discovery = try await ensureDiscovery()
        let request = HLTBEndpoint.searchRequest(title: title, discovery: discovery)
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

    /// Cache key for a search — the normalised query, so the same title (any case /
    /// spacing) hits the same entry.
    static func cacheKey(title: String) -> String {
        "search:" + TitleNormalizer.normalize(title, level: .canonical)
    }

    static let searchEndpoint = "hltb/search"
    static let discoveryEndpoint = "hltb/discovery"

    // MARK: - Endpoint discovery (once per run)

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

    /// GET a discovery document (homepage or app chunk). Any non-200 or empty body is
    /// a discovery failure → a `schemaMismatch` reject ("discovery failed"), stop.
    private func getText(request: URLRequest) async throws -> String {
        try allowList.check(request.url!)
        try budget.consume()
        try await pacer.waitBeforeNextRequest()
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200, !data.isEmpty else {
            try await recordAndThrow(reason: .schemaMismatch, endpoint: Self.discoveryEndpoint,
                                     status: response.statusCode, body: data)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reject

    /// Record a reject (never any credentials exist for HLTB, but never log a full
    /// body — cap the excerpt at 4 KB) and stop.
    private func recordAndThrow(reason: ImportRejectReason, endpoint: String,
                                status: Int?, body: Data) async throws -> Never {
        let excerpt = String(String(decoding: body.prefix(4096), as: UTF8.self))
        let reject = ImportReject(source: HLTBSource.id, endpoint: endpoint, status: status,
                                  reason: reason, redactedExcerpt: excerpt, receivedAt: wallClock())
        try? await cache.recordReject(reject)
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

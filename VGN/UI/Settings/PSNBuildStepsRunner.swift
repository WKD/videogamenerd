#if DEBUG
import Foundation

/// The DEBUG-only "PSN build steps" seam (PLAN §13.5). Everything in this file — the runner
/// protocol, the live adapter and the scripted fake — exists **only in DEBUG**, so a Release
/// build contains none of it (a test asserts the symbol is absent). The panel drives the
/// gated live steps one at a time, WITH the owner; this file is the instrument, so its
/// correctness is a safety matter: nothing here ever talks to Sony on its own — the live
/// adapter only makes the exact request of the step the owner clicked, through the same
/// boring ``PSNClient`` (allow-list, ≥ 1.5 s pacing, 40-request budget, validate-or-stop,
/// cache-first, dev-cache write-before-use).

// MARK: - Steps

/// One button on the build-steps panel, in §13.5 order. A *probe* is exactly one small
/// request; a *full fetch* pages a whole data set and asks "up to N — continue?" first
/// (and, on the real account, a second confirmation). Every step's prerequisites must have
/// succeeded for the current account label before it is enabled.
enum PSNBuildStepKind: String, CaseIterable, Sendable, Identifiable, Hashable {
    case probeProfile       // S2
    case probeTrophy2       // S3a
    case probeTrophy        // S3a′
    case probeGameList      // S5 probe
    case probePurchases     // S6 probe
    case fetchTrophyTitles  // S3b/S4
    case fetchGameList      // S5 full
    case fetchPurchases     // S6 full

    var id: String { rawValue }

    var isFullFetch: Bool {
        switch self {
        case .fetchTrophyTitles, .fetchGameList, .fetchPurchases: return true
        default: return false
        }
    }

    /// The panel row's title (PLAN §13.5 S-labels).
    var title: String {
        switch self {
        case .probeProfile:      return "S2 · Probe profile"
        case .probeTrophy2:      return "S3a · Probe trophy titles — limit 10"
        case .probeTrophy:       return "S3a′ · Probe trophy titles PS3/Vita — limit 10"
        case .probeGameList:     return "S5 · Probe game list — limit 10"
        case .probePurchases:    return "S6 · Probe purchases — size 10"
        case .fetchTrophyTitles: return "S3b/S4 · Fetch all trophy titles"
        case .fetchGameList:     return "S5 · Fetch game list"
        case .fetchPurchases:    return "S6 · Fetch purchases"
        }
    }

    /// The request-cost hint shown after the title ("(1)" or "(≈ n)").
    var costHint: String { isFullFetch ? "(≈ \(estimatedRequests))" : "(1)" }

    /// A best-effort request count for the confirmation ("up to N requests — continue?").
    var estimatedRequests: Int {
        switch self {
        case .fetchTrophyTitles: return 4   // PS4/PS5 + PS3/Vita, a page each way + paging
        case .fetchGameList:     return 3
        case .fetchPurchases:    return 4
        default:                 return 1
        }
    }

    /// The steps that must have passed (for the current label) before this one is enabled.
    /// A full fetch requires ITS probe(s); every probe requires the profile probe (S2).
    var prerequisites: [PSNBuildStepKind] {
        switch self {
        case .probeProfile:      return []
        case .probeTrophy2, .probeTrophy, .probeGameList, .probePurchases:
            return [.probeProfile]
        case .fetchTrophyTitles: return [.probeTrophy2, .probeTrophy]
        case .fetchGameList:     return [.probeGameList]
        case .fetchPurchases:    return [.probePurchases]
        }
    }
}

/// The redacted outcome of one step (PLAN §13.5). Everything here is safe to show and to
/// copy into the report: no header, no token, no account id.
struct PSNBuildStepOutcome: Sendable, Equatable {
    var httpStatus: Int?
    var itemCount: Int
    var totalItemCount: Int?
    var fromCache: Bool
    var bytes: Int
    /// The dev-cache file the body was written to (click → reveal in Finder), or nil.
    var devCachePath: String?
    /// The client's total budget used after this step (for "requests this session: k / 40").
    var requestsUsedTotal: Int

    init(httpStatus: Int? = 200, itemCount: Int = 0, totalItemCount: Int? = nil,
         fromCache: Bool = false, bytes: Int = 0, devCachePath: String? = nil,
         requestsUsedTotal: Int = 0) {
        self.httpStatus = httpStatus
        self.itemCount = itemCount
        self.totalItemCount = totalItemCount
        self.fromCache = fromCache
        self.bytes = bytes
        self.devCachePath = devCachePath
        self.requestsUsedTotal = requestsUsedTotal
    }
}

// MARK: - Runner seam

/// Exactly what the panel needs from ``PSNClient`` / ``PSNAuth`` — a live adapter and a
/// scripted fake conform. `Sendable`; every method is `async` and hops to the actors it
/// wraps. The panel never touches ``PSNClient`` directly, so the model is fully testable
/// offline with ``ScriptedPSNBuildRunner``.
protocol PSNBuildRunner: Sendable {
    /// The per-sync request budget (40) — the denominator of "requests this session".
    var budgetLimit: Int { get }
    /// Is a session (a stored token) present? Nothing is enabled before sign-in.
    func hasSession() async -> Bool
    /// The signed-in **online id** (never the account id) — shown so a step can never run
    /// against the wrong account.
    func onlineID() async -> String?
    /// The budget used so far for `label` (the running "k / 40").
    func requestsUsed(label: String) async -> Int
    /// Run exactly the requests of one step for `label`, cache-first. Throws on any reject.
    func run(_ step: PSNBuildStepKind, label: String) async throws -> PSNBuildStepOutcome
    /// Delete this account label's dev-cache bodies (the panel's "Wipe dev cache").
    func wipeDevCache(label: String) async
}

// MARK: - Persisted per-label gate (also the DEBUG normal-Sync gate, §13.5 D10)

/// Which build steps have passed, per account label, persisted so the state survives a
/// relaunch and so the normal Sync can refuse until they all have (PLAN §13.5 D10). Backed
/// by ``AppPreferences/defaults`` (a throw-away suite under the test host).
enum PSNBuildStepsGate {
    static func key(label: String, kind: PSNBuildStepKind) -> String {
        "psn.buildSteps.\(label).\(kind.rawValue).passed"
    }
    static func hasPassed(label: String, kind: PSNBuildStepKind) -> Bool {
        AppPreferences.defaults.bool(forKey: key(label: label, kind: kind))
    }
    static func setPassed(label: String, kind: PSNBuildStepKind, _ passed: Bool) {
        AppPreferences.defaults.set(passed, forKey: key(label: label, kind: kind))
    }
    /// Every step has passed once for `label` — the D10 gate on the normal Sync.
    static func hasPassedAll(label: String) -> Bool {
        PSNBuildStepKind.allCases.allSatisfy { hasPassed(label: label, kind: $0) }
    }
}

// MARK: - Live adapter (DEBUG live only)

/// The live ``PSNBuildRunner``: one ``PSNClient`` per account label (so the 40-budget and
/// the probe markers accumulate within a label across steps), the shared ``PSNAuth``, and
/// the dev cache. Built only by ``PSNImportBuilder`` in DEBUG live mode. Correct by
/// construction: a full fetch goes through the client's own probe-before-full guard, and a
/// reject throws and stops (the panel then locks).
actor LivePSNBuildRunner: PSNBuildRunner {
    private let auth: PSNAuth
    private let transport: HTTPTransport
    private let cache: ImportResponseCacheStore
    private let devCache: DevImportResponseCache?
    private let pacing: ImportPolicy.Pacing
    private var clients: [String: PSNClient] = [:]

    let budgetLimit: Int

    init(auth: PSNAuth, transport: HTTPTransport, cache: ImportResponseCacheStore,
         devCache: DevImportResponseCache?, pacing: ImportPolicy.Pacing = ImportPolicy.psn) {
        self.auth = auth
        self.transport = transport
        self.cache = cache
        self.devCache = devCache
        self.pacing = pacing
        self.budgetLimit = pacing.budget
    }

    private func client(for label: String) -> PSNClient {
        if let existing = clients[label] { return existing }
        let client = PSNClient(transport: transport, auth: auth, cache: cache, pacing: pacing,
                               accountLabel: label, devCache: devCache)
        clients[label] = client
        return client
    }

    private static func account(_ label: String) -> DevImportResponseCache.Account {
        label == "real" ? .real : .test
    }

    func hasSession() async -> Bool { await auth.hasSession() }

    func onlineID() async -> String? {
        guard let record = try? await cache.entry(source: ImportSourceID.psn, key: PSNEndpoint.profile),
              let profile = try? PSNJSON.decoder.decode(PSNProfile.self, from: record.body) else { return nil }
        return profile.onlineId
    }

    func requestsUsed(label: String) async -> Int { await client(for: label).budgetUsed }

    func run(_ step: PSNBuildStepKind, label: String) async throws -> PSNBuildStepOutcome {
        let client = client(for: label)
        let before = await client.budgetUsed

        var count = 0
        var total: Int? = nil
        switch step {
        case .probeProfile:
            _ = try await client.profile()
            count = 1
        case .probeTrophy2:
            count = try await client.probe(.trophyTitles(service: "trophy2"))
        case .probeTrophy:
            count = try await client.probe(.trophyTitles(service: "trophy"))
        case .probeGameList:
            count = try await client.probe(.gameList)
        case .probePurchases:
            count = try await client.probe(.purchases)
        case .fetchTrophyTitles:
            (count, total) = try await fetchTrophyTitles(client)
        case .fetchGameList:
            (count, total) = try await fetchGameList(client)
        case .fetchPurchases:
            count = try await fetchPurchases(client)
        }

        let after = await client.budgetUsed
        let devInfo = devCacheInfo(step: step, label: label)
        return PSNBuildStepOutcome(
            httpStatus: 200, itemCount: count, totalItemCount: total,
            fromCache: after == before, bytes: devInfo.bytes,
            devCachePath: devInfo.path, requestsUsedTotal: after)
    }

    func wipeDevCache(label: String) async {
        devCache?.wipe(account: Self.account(label))
    }

    // MARK: Full-fetch paging (bounded, respects the single-429 end)

    private func fetchTrophyTitles(_ client: PSNClient) async throws -> (Int, Int?) {
        var seenTotal = 0
        var grand: Int? = nil
        for service in PSNImporter.trophyServices {
            var offset = 0
            var seen = Set<String>()
            while true {
                let page = try await client.trophyTitlesPage(
                    service: service, limit: PSNImporter.trophyPageSize, offset: offset, seenIDs: seen)
                for t in page.trophyTitles { seen.insert(t.npCommunicationId) }
                grand = (grand ?? 0) + (offset == 0 ? page.totalItemCount : 0)
                if await client.reachedRateLimitEnd { break }
                guard let next = page.nextOffset, next > offset, !page.trophyTitles.isEmpty,
                      seen.count < page.totalItemCount else { break }
                offset = next
            }
            seenTotal += seen.count
            if await client.reachedRateLimitEnd { break }
        }
        return (seenTotal, grand)
    }

    private func fetchGameList(_ client: PSNClient) async throws -> (Int, Int?) {
        var offset = 0
        var seen = Set<String>()
        var total: Int? = nil
        while true {
            let page = try await client.gameListPage(
                limit: PSNImporter.gameListPageSize, offset: offset, seenIDs: seen)
            for t in page.titles { seen.insert(t.titleId) }
            if total == nil { total = page.totalItemCount }
            if await client.reachedRateLimitEnd { break }
            guard let next = page.nextOffset, next > offset, !page.titles.isEmpty,
                  seen.count < page.totalItemCount else { break }
            offset = next
        }
        return (seen.count, total)
    }

    private func fetchPurchases(_ client: PSNClient) async throws -> Int {
        var start = 0
        var count = 0
        while true {
            let page = try await client.purchasesPage(size: PSNImporter.purchasesPageSize, start: start)
            let games = page.data?.purchasedTitlesRetrieve?.games ?? []
            count += games.count
            if await client.reachedRateLimitEnd { break }
            guard games.count == PSNImporter.purchasesPageSize else { break }
            start += PSNImporter.purchasesPageSize
        }
        return count
    }

    // MARK: Dev-cache bytes/path from the index (no header, no token)

    private func devCacheInfo(step: PSNBuildStepKind, label: String) -> (bytes: Int, path: String?) {
        guard let devCache else { return (0, nil) }
        let folder = Self.account(label).folder
        let endpoints = Self.devEndpoints(step)
        let matches = devCache.indexEntries().filter { entry in
            entry.account == folder && endpoints.contains(entry.endpoint)
        }
        guard !matches.isEmpty else { return (0, nil) }
        var bytes = 0
        for entry in matches {
            let url = devCache.fileURL(for: entry)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int {
                bytes += size
            }
        }
        // Newest recorded file for "reveal in Finder" (index is newest-first).
        let newest = matches.max { $0.date < $1.date } ?? matches[0]
        return (bytes, devCache.fileURL(for: newest).path)
    }

    /// The exact dev-cache endpoint name(s) a step writes (see ``PSNClient`` `devEndpoint`s).
    private static func devEndpoints(_ step: PSNBuildStepKind) -> [String] {
        switch step {
        case .probeProfile:      return ["profile"]
        case .probeTrophy2:      return ["trophyTitles-trophy2"]
        case .probeTrophy:       return ["trophyTitles-trophy"]
        case .probeGameList, .fetchGameList: return ["gameList"]
        case .probePurchases, .fetchPurchases: return ["purchases"]
        case .fetchTrophyTitles: return ["trophyTitles-trophy2", "trophyTitles-trophy"]
        }
    }
}

// MARK: - Scripted fake (drives every test; no network, no Keychain)

/// A fully scripted ``PSNBuildRunner`` for the model + click tests. Each step is scripted to
/// return an outcome or throw; every call is recorded so a test can assert "exactly one
/// runner call per click" and "a disabled button triggers none".
final class ScriptedPSNBuildRunner: PSNBuildRunner, @unchecked Sendable {
    let budgetLimit: Int

    private let lock = NSLock()
    private var _session: Bool
    private var _onlineID: String?
    private var _requests: Int
    private var outcomes: [PSNBuildStepKind: PSNBuildStepOutcome]
    private var errors: [PSNBuildStepKind: Error]

    private(set) var calls: [PSNBuildStepKind] = []
    private(set) var wipedLabels: [String] = []

    init(session: Bool = true, onlineID: String? = "test_nerd", budgetLimit: Int = 40,
         requestsUsed: Int = 0,
         outcomes: [PSNBuildStepKind: PSNBuildStepOutcome] = [:],
         errors: [PSNBuildStepKind: Error] = [:]) {
        self._session = session
        self._onlineID = onlineID
        self.budgetLimit = budgetLimit
        self._requests = requestsUsed
        self.outcomes = outcomes
        self.errors = errors
    }

    func setSession(_ on: Bool) { lock.withLock { _session = on } }
    func setOnlineID(_ id: String?) { lock.withLock { _onlineID = id } }
    func scriptOutcome(_ outcome: PSNBuildStepOutcome, for step: PSNBuildStepKind) {
        lock.withLock { outcomes[step] = outcome; errors[step] = nil }
    }
    func scriptError(_ error: Error, for step: PSNBuildStepKind) {
        lock.withLock { errors[step] = error }
    }

    var callCount: Int { lock.withLock { calls.count } }

    func hasSession() async -> Bool { lock.withLock { _session } }
    func onlineID() async -> String? { lock.withLock { _onlineID } }
    func requestsUsed(label: String) async -> Int { lock.withLock { _requests } }

    func run(_ step: PSNBuildStepKind, label: String) async throws -> PSNBuildStepOutcome {
        try lock.withLock {
            calls.append(step)
            if let error = errors[step] { throw error }
            let outcome = outcomes[step] ?? PSNBuildStepOutcome(
                itemCount: step.isFullFetch ? 42 : 8, totalItemCount: step.isFullFetch ? 42 : nil,
                fromCache: false, bytes: 1234, devCachePath: "/tmp/dev/\(label)/\(step.rawValue).json",
                requestsUsedTotal: _requests + 1)
            _requests = outcome.requestsUsedTotal
            return outcome
        }
    }

    func wipeDevCache(label: String) async { lock.withLock { wipedLabels.append(label) } }
}
#endif

import Foundation
import GRDB

/// The seam every importer UI drives (the Settings account pane and the sync flow),
/// so the views and models are exercised with a fake and **never** touch the network
/// or the Keychain outside live mode (PLAN §14.4). GOG is the first conformer; PSN
/// (§13) will be the second. `Sendable`: its methods are `async` and hop to the
/// actors/stores they wrap.
protocol ImportBackend: Sendable {
    /// Stable source id (`ImportSourceID.gog`) for the staging + cache tables.
    var source: String { get }
    /// Human label for the sheet title / banners ("GOG").
    var sourceLabel: String { get }
    /// The data sets a sync fetches, with their cold-fetch request cost (Force refresh).
    var dataSets: [ImportDataSet] { get }
    /// The staging store the review sheet reads buckets / decisions from and commits to.
    var staging: ImportStagingStore { get }

    /// Is a session (a stored refresh token) present?
    func hasSession() async -> Bool
    /// The signed-in account's username from the cached account data — never the user id.
    func username() async -> String?
    /// Cache age per data set, newest first (PLAN §14.2 Settings pane).
    func cacheAges() async -> [ImportCacheAge]

    /// Exchange an OAuth authorization `code` for tokens and persist them (PLAN §14.1).
    func completeSignIn(code: String) async throws
    /// Sign out: delete the tokens, and optionally wipe the cached responses (PLAN §14.1).
    func signOut(alsoWipeCache: Bool) async throws
    /// Drop the cached responses for one data set (nil ⇒ all) so the next sync re-fetches
    /// them (PLAN §14.2 Force refresh). Other data sets stay cached.
    func forceRefresh(dataSetID: String?) async throws

    /// Run one sync (cache-first, budgeted, validated): stage, match, summarise. Throws
    /// ``ImportError`` on a reject — nothing is retried (PLAN §14.5).
    func runSync(onProgress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportSyncResult
}

extension ImportBackend {
    /// The most recent successful fetch across all data sets, or nil if nothing cached.
    func lastSync() async -> Date? {
        await cacheAges().map(\.fetchedAt).max()
    }
}

// MARK: - Live GOG backend

/// Wraps the real GOG objects (auth actor, importer, coordinator, matcher, cache) into
/// the ``ImportBackend`` seam. Built **only in live mode** by ``AppEnvironment``; every
/// other mode uses a fake so nothing GOG touches the network or the Keychain.
struct LiveGOGImportBackend: ImportBackend {
    let auth: GOGAuth
    let importer: GOGImporter
    let coordinator: ImportSyncCoordinator
    let matcher: any ImportMatcher
    let cache: ImportResponseCacheStore
    let staging: ImportStagingStore
    /// Expands a bundle match into its member games during matching (PLAN §5.1); nil when
    /// IGDB is not configured, so a bundle simply commits as a single.
    var bundleExpander: (any ImportBundleExpanding)? = nil

    var source: String { ImportSourceID.gog }
    var sourceLabel: String { "GOG" }
    var dataSets: [ImportDataSet] { importer.dataSets }

    func hasSession() async -> Bool { await auth.hasSession() }

    func username() async -> String? {
        guard let record = try? await cache.entry(source: source, key: GOGEndpoint.userData),
              let user = try? JSONDecoder().decode(GOGUserData.self, from: record.body) else { return nil }
        return user.username
    }

    func cacheAges() async -> [ImportCacheAge] {
        (try? await cache.ages(source: source)) ?? []
    }

    func completeSignIn(code: String) async throws {
        try await auth.completeSignIn(code: code)
    }

    func signOut(alsoWipeCache: Bool) async throws {
        try await auth.signOut()
        if alsoWipeCache { try await cache.wipe(source: source) }
    }

    func forceRefresh(dataSetID: String?) async throws {
        guard let dataSetID else {
            try await cache.wipe(source: source)
            return
        }
        // Drop just this data set's cache rows so the next sync re-fetches only it
        // (PLAN §14.2). The library data set spans per-page keys + a manifest, all
        // prefixed by the endpoint, so a single-request set deletes its exact key and
        // the paged set deletes the prefix.
        let src = source
        try await cache.dbWriter.write { db in
            switch dataSetID {
            case GOGEndpoint.filteredProducts:
                try db.execute(sql: "DELETE FROM import_cache WHERE source = ? AND key LIKE ?",
                               arguments: [src, "\(GOGEndpoint.filteredProducts)%"])
            default:
                try db.execute(sql: "DELETE FROM import_cache WHERE source = ? AND key = ?",
                               arguments: [src, dataSetID])
            }
        }
    }

    func runSync(onProgress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportSyncResult {
        try await coordinator.run(importer, matcher: matcher, bundleExpander: bundleExpander,
                                  onProgress: onProgress)
    }
}

/// An always-signed-out, do-nothing ``ImportBackend`` (PLAN §14.4): the backend used in
/// sample/seeded modes so the Settings pane renders and nothing GOG ever touches the
/// network or the Keychain. Sign-in is unavailable there (`login == nil`), so it is only
/// ever asked for its (empty) state.
struct InertImportBackend: ImportBackend {
    let source: String
    let sourceLabel: String
    let staging: ImportStagingStore
    var dataSets: [ImportDataSet] { [] }

    init(source: String = ImportSourceID.gog, sourceLabel: String = "GOG", staging: ImportStagingStore) {
        self.source = source
        self.sourceLabel = sourceLabel
        self.staging = staging
    }

    func hasSession() async -> Bool { false }
    func username() async -> String? { nil }
    func cacheAges() async -> [ImportCacheAge] { [] }
    func completeSignIn(code: String) async throws {}
    func signOut(alsoWipeCache: Bool) async throws {}
    func forceRefresh(dataSetID: String?) async throws {}
    func runSync(onProgress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportSyncResult {
        ImportSyncResult(summary: ImportSyncSummary(source: source), matches: [], rows: [])
    }
}

#if DEBUG
/// A fully in-memory ``ImportBackend`` for previews and tests: no network, no
/// Keychain. Scriptable — seed the session, username, cache ages, and either a sync
/// result or a thrown error; it records the sign-out / force-refresh / sign-in calls
/// so the account-model tests can assert them.
final class FakeImportBackend: ImportBackend, @unchecked Sendable {
    let source: String
    let sourceLabel: String
    let dataSets: [ImportDataSet]
    let staging: ImportStagingStore

    private let lock = NSLock()
    private var _session: Bool
    private var _username: String?
    private var _ages: [ImportCacheAge]
    private var _result: ImportSyncResult?
    private var _error: Error?

    // Recorded calls (for assertions).
    private(set) var completedCode: String?
    private(set) var signOutCalls: [Bool] = []
    private(set) var forceRefreshCalls: [String?] = []
    private(set) var syncCount = 0

    init(source: String = ImportSourceID.gog,
         sourceLabel: String = "GOG",
         dataSets: [ImportDataSet] = [],
         staging: ImportStagingStore,
         session: Bool = false,
         username: String? = nil,
         ages: [ImportCacheAge] = [],
         result: ImportSyncResult? = nil,
         error: Error? = nil) {
        self.source = source
        self.sourceLabel = sourceLabel
        self.dataSets = dataSets
        self.staging = staging
        self._session = session
        self._username = username
        self._ages = ages
        self._result = result
        self._error = error
    }

    func setSession(_ on: Bool) { lock.withLock { _session = on } }
    func setError(_ error: Error?) { lock.withLock { _error = error } }
    func setResult(_ result: ImportSyncResult?) { lock.withLock { _result = result } }

    func hasSession() async -> Bool { lock.withLock { _session } }
    func username() async -> String? { lock.withLock { _username } }
    func cacheAges() async -> [ImportCacheAge] { lock.withLock { _ages } }

    func completeSignIn(code: String) async throws {
        if let error = lock.withLock({ _error }) { throw error }
        lock.withLock { completedCode = code; _session = true }
    }

    func signOut(alsoWipeCache: Bool) async throws {
        lock.withLock { signOutCalls.append(alsoWipeCache); _session = false }
    }

    func forceRefresh(dataSetID: String?) async throws {
        if let error = lock.withLock({ _error }) { throw error }
        lock.withLock { forceRefreshCalls.append(dataSetID) }
    }

    func runSync(onProgress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportSyncResult {
        lock.withLock { syncCount += 1 }
        onProgress(ImportProgress(phase: .finished))
        if let error = lock.withLock({ _error }) { throw error }
        return lock.withLock { _result } ?? ImportSyncResult(
            summary: ImportSyncSummary(source: source), matches: [], rows: [])
    }
}
#endif

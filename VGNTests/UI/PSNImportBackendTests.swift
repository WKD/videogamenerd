import Foundation
import GRDB
import Testing
@testable import VGN

/// `LivePSNImportBackend`: force-refresh drops only the named data set's cached rows and
/// **keeps the probe markers** (a different key prefix), and `username()` reads the
/// signed-in **online id** from the cached profile. No network is made (force-refresh and
/// username only touch the cache DB).
@Suite(.serialized)
struct PSNImportBackendTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeBackend() throws -> (LivePSNImportBackend, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let cache = ImportResponseCacheStore(db)
        let staging = ImportStagingStore(db)
        let transport = try psnHappyPathTransport()
        let auth = seededPSNAuth(transport: transport, now: now)
        let importer = PSNImporter(auth: auth, transport: transport, cache: cache)
        let backend = LivePSNImportBackend(
            auth: auth, importer: importer, coordinator: ImportSyncCoordinator(staging: staging),
            matcher: NoMatchImportMatcher(), cache: cache, staging: staging)
        return (backend, db)
    }

    private func seed(_ db: AppDatabase, key: String, body: Data = Data("{}".utf8)) throws {
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO import_cache (source, key, endpoint, fetched_at, expires_at, status, body)
                VALUES ('psn', ?, 'x', ?, ?, 200, ?)
                """, arguments: [key, self.now, self.now.addingTimeInterval(86_400), body])
        }
    }

    private func keys(_ db: AppDatabase) throws -> [String] {
        try db.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM import_cache WHERE source = 'psn' ORDER BY key")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func forceRefreshDropsDataSetButKeepsProbeMarkers() async throws {
        let (backend, db) = try makeBackend()
        try seed(db, key: "trophyTitles?limit=800&offset=0")
        try seed(db, key: "probe:trophyTitles:test")             // probe marker — must survive
        try seed(db, key: "gameList?limit=200&offset=0")          // other data set — must survive

        try await backend.forceRefresh(dataSetID: PSNEndpoint.trophyTitles)

        let remaining = try keys(db)
        #expect(!remaining.contains { $0.hasPrefix("trophyTitles?") })
        #expect(remaining.contains("probe:trophyTitles:test"))
        #expect(remaining.contains("gameList?limit=200&offset=0"))
    }

    @Test(.timeLimit(.minutes(1)))
    func forceRefreshNilWipesEverythingForTheSource() async throws {
        let (backend, db) = try makeBackend()
        try seed(db, key: "trophyTitles?a")
        try seed(db, key: "gameList?b")
        try await backend.forceRefresh(dataSetID: nil)
        #expect(try keys(db).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func usernameReadsOnlineIDFromCachedProfile() async throws {
        let (backend, db) = try makeBackend()
        try seed(db, key: PSNEndpoint.profile, body: Data(#"{"onlineId":"nerd_ps","accountId":"SECRET"}"#.utf8))
        let name = await backend.username()
        #expect(name == "nerd_ps")   // never the accountId
    }
}

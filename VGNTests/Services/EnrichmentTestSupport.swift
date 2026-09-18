import Foundation
import GRDB
@testable import VGN

// MARK: - Mutable credentials (for @Sendable closures)

/// Mutable credentials so a test can start with none and make them appear.
/// (`MutableDate` lives in `EnrichmentClockSupport.swift`.)
final class MutableCreds: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IGDBCredentials?
    init(_ creds: IGDBCredentials? = IGDBCredentials(clientID: "cid", secret: "sec")) { self.value = creds }
    var current: IGDBCredentials? { lock.withLock { value } }
    func set(_ creds: IGDBCredentials?) { lock.withLock { value = creds } }
}

// MARK: - Scripted IGDB + image transport

/// A body-aware `HTTPTransport` for the enrichment coordinator tests: it answers
/// the Twitch token endpoint, synthesises a game object per requested id for
/// `/v4/games`, a time-to-beat row per id for `/v4/game_time_to_beats`, and serves
/// a PNG for any image download. Records requests + peak concurrency and can inject
/// a per-image delay and a scriptable failure.
final class ScriptedIGDBTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var active = 0
    private var peak = 0
    private var failure: (@Sendable () -> Error)?
    private var failureAppliesToAPI = true
    private let imageDelay: TimeInterval

    init(imageDelay: TimeInterval = 0) { self.imageDelay = imageDelay }

    /// Make every subsequent IGDB API call throw (covers still succeed). Clear with nil.
    func failAPI(_ factory: (@Sendable () -> Error)?) {
        lock.withLock { failure = factory; failureAppliesToAPI = true }
    }

    var totalRequests: Int { lock.withLock { urls.count } }
    var peakConcurrency: Int { lock.withLock { peak } }
    func requestCount(urlContains needle: String) -> Int {
        lock.withLock { urls.filter { $0.contains(needle) }.count }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let thrown: Error? = lock.withLock {
            urls.append(url)
            active += 1
            peak = max(peak, active)
            if url.contains("api.igdb.com"), let failure { return failure() }
            return nil
        }
        let isImage = url.contains("images.igdb.com") || url.contains("raw.githubusercontent")
        if isImage, imageDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(imageDelay * 1_000_000_000))
        }
        lock.withLock { active -= 1 }
        if let thrown { throw thrown }

        let (status, data) = Self.response(url: url, body: body)
        let http = HTTPURLResponse(url: request.url ?? URL(string: "https://x")!,
                                   statusCode: status, httpVersion: nil, headerFields: [:])!
        return (data, http)
    }

    private static func response(url: String, body: String) -> (Int, Data) {
        if url.contains("id.twitch.tv") {
            return (200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8))
        }
        if url.contains("api.igdb.com/v4/game_time_to_beats") {
            let ids = idsInBody(body, after: "game_id = ")
            let rows = ids.map { id -> [String: Any] in
                ["game_id": id, "hastily": 3600, "normally": 7200, "completely": 14400, "count": 12]
            }
            return (200, (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8))
        }
        if url.contains("api.igdb.com/v4/games") {
            let ids = idsInBody(body, after: "where id = ")
            let rows = ids.map { syntheticGame(id: $0) }
            return (200, (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8))
        }
        // Any image download → a small PNG.
        return (200, TestImage.png(width: 264, height: 374))
    }

    static func syntheticGame(id: Int64) -> [String: Any] {
        [
            "id": id,
            "name": "Game \(id)",
            "slug": "game-\(id)",
            "summary": "Summary of game \(id).",
            "first_release_date": 1_420_070_400,          // 2015-01-01
            "game_type": 0,
            "cover": ["image_id": "img\(id)"],
            "platforms": [["id": 48, "abbreviation": "PS4"]],
            "genres": [["id": 1, "name": "Action"], ["id": 2, "name": "Adventure"]],
            "alternative_names": [["id": 1, "name": "altbaphomet\(id)"]],
            // §7b traits + crowd rating.
            "franchises": [["id": 7, "name": "Synthetica"]],
            "collections": [["id": 8, "name": "Synth Saga"]],
            "involved_companies": [
                ["company": ["id": 9, "name": "Stub Studio"], "developer": true],
                ["company": ["id": 10, "name": "Stub Publisher"], "developer": false],
            ],
            "themes": [["id": 1, "name": "Action"], ["id": 17, "name": "Fantasy"]],
            "game_modes": [["id": 1, "name": "Single player"]],
            "player_perspectives": [["id": 2, "name": "Third person"]],
            "keywords": [["id": 1, "name": "kw-a"], ["id": 2, "name": "kw-b"]],
            "similar_games": [5000, 5001],
            "total_rating": 88.5,
            "total_rating_count": 300,
        ]
    }

    /// Pull the integer ids from the first `(...)` group after `keyword` in an
    /// Apicalypse body (e.g. `where id = (1000,1001)`).
    static func idsInBody(_ body: String, after keyword: String) -> [Int64] {
        guard let kw = body.range(of: keyword) else { return [] }
        let rest = body[kw.upperBound...]
        guard let open = rest.firstIndex(of: "("),
              let close = rest[open...].firstIndex(of: ")") else { return [] }
        let inside = rest[rest.index(after: open)..<close]
        return inside.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - Harness

/// Everything wired over one in-memory DB with the scripted transport — the
/// coordinator-under-test plus the pieces to poke and assert.
struct EnrichmentHarness {
    let database: AppDatabase
    let library: LibraryStore
    let jobStore: EnrichmentJobStore
    let catalogCache: CatalogCacheStore
    let igdbClient: IGDBClient
    let coverStore: CoverStore
    let coordinator: EnrichmentCoordinator
    let transport: ScriptedIGDBTransport
    let date: MutableDate
    let creds: MutableCreds
    let coversDirectory: URL

    static func make(
        backoff: EnrichmentBackoff = EnrichmentBackoff(maxAttempts: 3, baseDelay: 60),
        jitter: Double = 0.5,
        imageDelay: TimeInterval = 0,
        creds: MutableCreds = MutableCreds()
    ) async throws -> EnrichmentHarness {
        let db = try AppDatabase.inMemory()
        try await db.seedPlatforms(from: TestDB.platforms)
        let date = MutableDate()
        let transport = ScriptedIGDBTransport(imageDelay: imageDelay)
        let credsBox = creds
        let credentials: @Sendable () async -> IGDBCredentials? = { credsBox.current }

        let library = LibraryStore(db)
        let catalogCache = CatalogCacheStore(db, now: { date.now })
        let clock = RecordingImmediateClock()
        let igdbClient = IGDBClient(
            transport: transport,
            credentials: credentials,
            catalog: TestCatalog.catalog,
            cache: catalogCache,
            retryPolicy: .none,       // job-level backoff owns retries; no internal sleeps
            clock: clock
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vgn-enrich-\(UUID().uuidString)")
        let coverStore = CoverStore(
            chain: CoverProviderChain(providers: [IGDBCoverProvider()]),
            transport: transport,
            coversDirectory: root.appendingPathComponent("covers"),
            thumbsDirectory: root.appendingPathComponent("thumbs")
        )
        let jobStore = EnrichmentJobStore(db, backoff: backoff, now: { date.now }, jitter: { jitter })
        let coordinator = EnrichmentCoordinator(
            jobStore: jobStore,
            libraryStore: library,
            catalogCache: catalogCache,
            igdbClient: igdbClient,
            coverStore: coverStore,
            credentials: credentials
        )
        return EnrichmentHarness(
            database: db, library: library, jobStore: jobStore, catalogCache: catalogCache,
            igdbClient: igdbClient, coverStore: coverStore, coordinator: coordinator,
            transport: transport, date: date, creds: creds, coversDirectory: root.appendingPathComponent("covers")
        )
    }

    /// Add `count` owned IGDB games on PS4, returning their game ids in order.
    @discardableResult
    func addGames(_ count: Int, firstIGDBID: Int64 = 1000) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 0..<count {
            let outcome = try await library.addGame(GameDraft(
                title: "Game \(firstIGDBID + Int64(i))",
                igdbID: firstIGDBID + Int64(i),
                platformIDs: ["ps4"],
                owned: true
            ))
            ids.append(outcome.gameID)
        }
        return ids
    }

    /// Read one game row (for assertions).
    func game(_ id: Int64) async throws -> GameRecord? {
        try await database.dbWriter.read { db in try GameRecord.fetchOne(db, key: id) }
    }

    /// Number of games whose alt title matches an FTS query.
    func ftsMatchCount(_ query: String) async throws -> Int {
        try await database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games_fts WHERE games_fts MATCH ?",
                             arguments: [query]) ?? 0
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: coversDirectory.deletingLastPathComponent())
    }
}

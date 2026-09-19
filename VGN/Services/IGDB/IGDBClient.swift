import Foundation

/// IGDB v4 client: Apicalypse over `POST https://api.igdb.com/v4/<endpoint>`.
///
/// Every call is rate-limited (PLAN §5.1: 4 req/s), goes through the retry helper for
/// 429/5xx, and refreshes-and-retries once on a 401. All work is cancellable. Search
/// results populate the injected `CatalogCaching` so repeat autocomplete is instant.
///
/// The `credentials` closure is the seam the UI lane fills next wave (its
/// `CredentialsProviding` → one line). We take a closure, not that protocol, to avoid
/// a duplicate-declaration collision at merge.
actor IGDBClient {
    private let transport: HTTPTransport
    private let credentials: @Sendable () async -> IGDBCredentials?
    private let tokenProvider: IGDBTokenProvider
    private let rateLimiter: RateLimiter
    private let catalog: PlatformCatalog
    private let cache: CatalogCaching
    private let retryPolicy: RetryPolicy
    private let clock: ServiceClock
    private let jitterProvider: @Sendable () -> Double
    private let baseURL: URL

    init(
        transport: HTTPTransport,
        credentials: @Sendable @escaping () async -> IGDBCredentials?,
        catalog: PlatformCatalog,
        cache: CatalogCaching = InMemoryCatalogCache(),
        tokenProvider: IGDBTokenProvider? = nil,
        rateLimiter: RateLimiter? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: ServiceClock = SystemClock(),
        jitterProvider: @Sendable @escaping () -> Double = { Double.random(in: 0...1) },
        baseURL: URL = URL(string: "https://api.igdb.com/v4/")!
    ) {
        self.transport = transport
        self.credentials = credentials
        self.catalog = catalog
        self.cache = cache
        self.tokenProvider = tokenProvider
            ?? IGDBTokenProvider(transport: transport, credentials: credentials)
        self.rateLimiter = rateLimiter ?? RateLimiter(rate: 4, clock: clock)
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.jitterProvider = jitterProvider
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Autocomplete search (PLAN §5.1). Optionally constrained to platforms. Populates
    /// the catalog cache with each returned game's raw JSON.
    func searchGames(
        _ text: String,
        platformIGDBIDs: [Int]? = nil,
        limit: Int = 12
    ) async throws -> [IGDBSearchResult] {
        try await runGamesSearch(IGDBAutocomplete.searchQuery(text, platformIGDBIDs: platformIGDBIDs, limit: limit))
    }

    /// Run a `/v4/games` query that yields search-result DTOs, populating the
    /// catalogue cache. The single entry point shared by ``searchGames`` and the
    /// Quick Add autocomplete (`IGDBClient+Autocomplete.swift`), so every path uses
    /// the one pipeline — token, rate-limit, retry and the 401 refresh.
    func runGamesSearch(_ query: IGDBQuery) async throws -> [IGDBSearchResult] {
        let data = try await requestData(endpoint: "games", body: query.build())
        await populateCache(from: data)
        let dtos = try decode([IGDBGameDTO].self, from: data)
        return dtos.map(searchResult(from:))
    }

    /// Full metadata for enrichment (PLAN §5.1).
    func games(ids: [Int64]) async throws -> [IGDBGameMetadata] {
        guard !ids.isEmpty else { return [] }
        let query = IGDBQuery()
            .fields(IGDBFields.full)
            .filter("id = \(IGDBQuery.idSet(ids))")
            .limit(ids.count)
        let data = try await requestData(endpoint: "games", body: query.build())
        await populateCache(from: data)
        let dtos = try decode([IGDBGameDTO].self, from: data)
        return dtos.map(metadata(from:))
    }

    /// Member games of a bundle/compilation (PLAN §5.1). Given a bundle game's own
    /// metadata, resolve its members: prefer the `bundles` relation when populated,
    /// otherwise fall back to the reverse lookup `where bundles = (id)`. Returns
    /// search-result DTOs; never fails hard on imperfect coverage (returns `[]`).
    func bundleMembers(of bundle: IGDBGameMetadata) async throws -> [IGDBSearchResult] {
        // NOTE: a game's own `bundles` field lists the bundles it BELONGS TO (its
        // parents) — e.g. "God of War Collection".bundles = ["God of War Trilogy"] —
        // never its members. Members are only reachable through the reverse lookup.
        try await bundleMembers(ofBundleID: bundle.id)
    }

    /// Members of bundle `id`: the games that list `id` in their `bundles` relation
    /// (reverse lookup). Nested bundles are expanded (a trilogy made of a two-game
    /// collection + a third game yields the three games), add-on content is dropped,
    /// results are de-duplicated and keep IGDB's order.
    func bundleMembers(ofBundleID id: Int64) async throws -> [IGDBSearchResult] {
        var visited: Set<Int64> = [id]
        return try await expandedMembers(ofBundleID: id, depth: 0, visited: &visited)
    }

    private func expandedMembers(
        ofBundleID id: Int64, depth: Int, visited: inout Set<Int64>
    ) async throws -> [IGDBSearchResult] {
        let query = IGDBQuery()
            .fields(IGDBFields.search)
            .filter("bundles = (\(id))")
            .limit(50)
        let data = try await requestData(endpoint: "games", body: query.build())
        let direct = try decode([IGDBGameDTO].self, from: data).map(searchResult(from:))

        var members: [IGDBSearchResult] = []
        for member in direct where !visited.contains(member.id) {
            visited.insert(member.id)
            if member.gameType.isAddOnContent { continue }   // DLC / packs / updates / mods
            if member.gameType == .bundle, depth < 3 {
                let nested = try await expandedMembers(ofBundleID: member.id, depth: depth + 1, visited: &visited)
                // A nested bundle IGDB knows nothing about stays as one entry.
                members.append(contentsOf: nested.isEmpty ? [member] : nested)
            } else {
                members.append(member)
            }
        }
        return members
    }

    /// Average completion times, batched by game id (PLAN §5.1 / §6.4).
    func timeToBeat(gameIDs: [Int64]) async throws -> [IGDBTimeToBeat] {
        guard !gameIDs.isEmpty else { return [] }
        let query = IGDBQuery()
            .fields(IGDBFields.timeToBeat)
            .filter("game_id = \(IGDBQuery.idSet(gameIDs))")
            .limit(gameIDs.count)
        let data = try await requestData(endpoint: "game_time_to_beats", body: query.build())
        let dtos = try decode([IGDBTimeToBeatDTO].self, from: data)
        return dtos.map {
            IGDBTimeToBeat(
                gameID: $0.gameId,
                hastily: $0.hastily,
                normally: $0.normally,
                completely: $0.completely,
                count: $0.count
            )
        }
    }

    // MARK: - Cache decode (enrichment cache-hit path)

    /// Decode one cached `/v4/games` JSON object into public metadata, so the
    /// enrichment metadata job can serve a fresh catalogue-cache hit without a
    /// network call (PLAN §4/§9). Nonisolated: reads only the immutable catalogue.
    nonisolated func metadata(fromCachedGameJSON data: Data) -> IGDBGameMetadata? {
        guard let dto = try? JSONDecoder().decode(IGDBGameDTO.self, from: data) else { return nil }
        return metadata(from: dto)
    }

    // MARK: - DTO → public mapping

    private nonisolated func searchResult(from dto: IGDBGameDTO) -> IGDBSearchResult {
        let igdbIDs = (dto.platforms ?? []).map(\.id)
        return IGDBSearchResult(
            id: dto.id,
            name: dto.name ?? "",
            releaseYear: IGDBDate.year(fromUnix: dto.firstReleaseDate),
            coverImageID: dto.cover?.imageId,
            platformIGDBIDs: igdbIDs,
            platformAbbreviations: (dto.platforms ?? []).compactMap(\.abbreviation),
            platformSlugs: catalog.slugs(forIGDBIDs: igdbIDs),
            genres: (dto.genres ?? []).compactMap(\.name),
            alternativeNames: (dto.alternativeNames ?? []).compactMap(\.name),
            gameType: IGDBGameType(rawValue: dto.gameType ?? 0)
        )
    }

    private nonisolated func metadata(from dto: IGDBGameDTO) -> IGDBGameMetadata {
        let igdbIDs = (dto.platforms ?? []).map(\.id)
        var meta = IGDBGameMetadata(
            id: dto.id,
            name: dto.name ?? "",
            slug: dto.slug,
            summary: dto.summary,
            releaseDate: IGDBDate.date(fromUnix: dto.firstReleaseDate),
            releaseYear: IGDBDate.year(fromUnix: dto.firstReleaseDate),
            coverImageID: dto.cover?.imageId,
            platformIGDBIDs: igdbIDs,
            platformSlugs: catalog.slugs(forIGDBIDs: igdbIDs),
            genres: (dto.genres ?? []).compactMap(\.name),
            alternativeNames: (dto.alternativeNames ?? []).compactMap(\.name),
            gameType: IGDBGameType(rawValue: dto.gameType ?? 0),
            bundleMemberIDs: dto.bundles ?? [],
            parentGameID: dto.parentGame,
            versionParentID: dto.versionParent
        )
        // §7b traits (deduped, order-preserving).
        meta.franchises = Self.names(dto.franchise.map { [$0] } ?? [], dto.franchises)
        meta.series = Self.names(dto.collection.map { [$0] } ?? [], dto.collections)
        meta.developers = Self.dedup((dto.involvedCompanies ?? [])
            .filter { $0.developer == true }
            .compactMap { $0.company?.name })
        meta.themes = Self.names(nil, dto.themes)
        meta.gameModes = Self.names(nil, dto.gameModes)
        meta.perspectives = Self.names(nil, dto.playerPerspectives)
        meta.keywords = Array(Self.names(nil, dto.keywords).prefix(IGDBTraitLimits.keywords))
        meta.similarGameIDs = dto.similarGames ?? []
        let (rating, count) = Self.resolveRating(dto)
        meta.igdbRating = rating
        meta.igdbRatingCount = count
        return meta
    }

    /// Deduped, non-empty names from an optional leading singular ref plus an
    /// optional array of refs, in order (singular first).
    private nonisolated static func names(
        _ leading: [IGDBGameDTO.NamedRef]?, _ array: [IGDBGameDTO.NamedRef]?
    ) -> [String] {
        dedup(((leading ?? []) + (array ?? [])).compactMap(\.name))
    }

    private nonisolated static func dedup(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Resolve the crowd rating (PLAN §7b): `total_rating` when present, else the
    /// critic `aggregated_rating`, else the user `rating`. The count follows the
    /// chosen source.
    private nonisolated static func resolveRating(_ dto: IGDBGameDTO) -> (Double?, Int?) {
        if let r = dto.totalRating { return (r, dto.totalRatingCount) }
        if let r = dto.aggregatedRating { return (r, dto.aggregatedRatingCount) }
        if let r = dto.rating { return (r, dto.ratingCount) }
        return (nil, nil)
    }

    private func searchResult(from meta: IGDBGameMetadata) -> IGDBSearchResult {
        IGDBSearchResult(
            id: meta.id,
            name: meta.name,
            releaseYear: meta.releaseYear,
            coverImageID: meta.coverImageID,
            platformIGDBIDs: meta.platformIGDBIDs,
            platformAbbreviations: [],
            platformSlugs: meta.platformSlugs,
            genres: meta.genres,
            alternativeNames: meta.alternativeNames,
            gameType: meta.gameType
        )
    }

    // MARK: - Networking

    private func requestData(endpoint: String, body: String) async throws -> Data {
        try await withRetry(policy: retryPolicy, clock: clock, jitterProvider: jitterProvider) {
            try await self.performRequest(endpoint: endpoint, body: body)
        }
    }

    private func performRequest(endpoint: String, body: String) async throws -> Data {
        guard let clientID = await credentials()?.clientID else {
            throw IGDBError.missingCredentials
        }
        try await rateLimiter.acquire()
        let token = try await tokenProvider.validToken()
        let (data, response) = try await send(endpoint: endpoint, body: body, clientID: clientID, token: token)

        if response.statusCode == 401 {
            // Token rejected — refresh once and retry (still rate-limited).
            let fresh = try await tokenProvider.forceRefresh()
            try await rateLimiter.acquire()
            let (data2, response2) = try await send(endpoint: endpoint, body: body, clientID: clientID, token: fresh)
            return try validate(data2, response2)
        }
        return try validate(data, response)
    }

    private func send(
        endpoint: String,
        body: String,
        clientID: String,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        try Task.checkCancellation()
        return try await transport.data(for: request)
    }

    private func validate(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
        guard (200...299).contains(response.statusCode) else {
            throw HTTPStatusError(
                status: response.statusCode,
                body: data,
                retryAfter: response.retryAfterSeconds
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw IGDBError.decoding("\(type): \(error)")
        }
    }

    /// Store each returned game's raw JSON object in the catalog cache.
    private func populateCache(from data: Data) async {
        guard let entries = Self.rawGameEntries(from: data, now: Date()) else { return }
        await cache.store(entries)
    }

    /// Split a `/v4/games` response into per-game `(id, rawJSON)` cache entries.
    static func rawGameEntries(from data: Data, now: Date) -> [CatalogCacheEntry]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var out: [CatalogCacheEntry] = []
        out.reserveCapacity(array.count)
        for object in array {
            guard let id = (object["id"] as? NSNumber)?.int64Value,
                  let json = try? JSONSerialization.data(withJSONObject: object)
            else { continue }
            out.append(CatalogCacheEntry(igdbID: id, json: json, fetchedAt: now))
        }
        return out
    }
}

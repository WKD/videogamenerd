import Foundation

/// Autocomplete for Quick Add (PLAN §5.1 / §6.1).
///
/// The services lane found that IGDB `search "…"` gives the cleanest autocomplete
/// ordering but returns **nothing** for mid-word prefixes ("bloodb") and for
/// alt-name-only titles ("chevaliers de baphomet" → *Broken Sword*). This adds the
/// two documented fallbacks and merges them behind `search`:
///
///  1. `search "text"`                              — the ranked primary path.
///  2. `where name ~ "text"*`                        — name-prefix (fixes "bloodb").
///  3. `where alternative_names.name ~ *"text"*`     — alt-name contains (fixes the
///                                                     French box titles).
///
/// Verified live against the six brief cases (see the handoff): 1+2 recover
/// "bloodb" → Bloodborne, 3 recovers "chevaliers de baphomet" → Broken Sword, and
/// `search` alone already covers "zelda" / "ico" / "metal gear solid legacy".
///
/// ## Why a sibling type, not a method on `IGDBClient`
/// `IGDBClient`'s request pipeline (`requestData`, `send`, the DTO mappers) is
/// `private` and this lane may not edit `IGDBClient.swift` (the data lane owns it).
/// An extension in this separate file therefore cannot reach that pipeline, so the
/// fallback runs through a small dedicated request path here, built from the same
/// **internal** pieces (`IGDBTokenProvider`, `RateLimiter`, `IGDBQuery`,
/// `IGDBGameDTO`, `IGDBFields`). If the data lane later exposes an internal query
/// hook this collapses into a true `IGDBClient` extension — the merge logic
/// (`IGDBAutocomplete.merge`) already lives as a pure static and is unit-tested.
struct IGDBAutocomplete: Sendable {
    private let transport: HTTPTransport
    private let credentials: @Sendable () async -> IGDBCredentials?
    private let catalog: PlatformCatalog
    private let cache: CatalogCaching?
    private let tokenProvider: IGDBTokenProvider
    private let rateLimiter: RateLimiter
    private let baseURL: URL
    /// `search` yields fewer than this ⇒ run the prefix / alt-name fallbacks.
    private let fallbackThreshold: Int

    init(
        transport: HTTPTransport = URLSessionTransport(),
        credentials: @Sendable @escaping () async -> IGDBCredentials?,
        catalog: PlatformCatalog,
        cache: CatalogCaching? = nil,
        clock: ServiceClock = SystemClock(),
        baseURL: URL = URL(string: "https://api.igdb.com/v4/")!,
        fallbackThreshold: Int = 4
    ) {
        self.transport = transport
        self.credentials = credentials
        self.catalog = catalog
        self.cache = cache
        self.tokenProvider = IGDBTokenProvider(transport: transport, credentials: credentials)
        self.rateLimiter = RateLimiter(rate: 4, clock: clock)
        self.baseURL = baseURL
        self.fallbackThreshold = fallbackThreshold
    }

    /// Autocomplete `text`, optionally constrained to `platformIGDBIDs`. Runs
    /// `search` first and, only when it is thin, the two fallbacks; merges keeping
    /// `search` order, then name-prefix, then alt-name, de-duping by game id.
    /// Throws `IGDBError.missingCredentials` (offline / not-configured) — the caller
    /// falls back to local + manual rows.
    func autocomplete(
        _ text: String,
        platformIGDBIDs: [Int]? = nil,
        limit: Int = 12
    ) async throws -> [IGDBSearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        let primary = try await run(searchQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        try Task.checkCancellation()
        if primary.count >= fallbackThreshold {
            return Self.merge([primary], limit: limit)
        }

        // Run the two fallbacks (best-effort — a failing fallback never sinks the
        // primary results we already have).
        async let prefixResults = tryRun(namePrefixQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        async let altResults = tryRun(altNameQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        return Self.merge([primary, await prefixResults, await altResults], limit: limit)
    }

    // MARK: - Queries

    private func searchQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
        var q = IGDBQuery().search(text).fields(IGDBFields.search).limit(limit)
        if let ids = platformIGDBIDs, !ids.isEmpty {
            q = q.filter("platforms = \(IGDBQuery.idSet(ids))")
        }
        return q
    }

    private func namePrefixQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
        let esc = IGDBQuery.escape(text)
        var clause = "name ~ \"\(esc)\"*"
        if let ids = platformIGDBIDs, !ids.isEmpty {
            clause += " & platforms = \(IGDBQuery.idSet(ids))"
        }
        return IGDBQuery()
            .fields(IGDBFields.search)
            .filter(clause)
            .sort("total_rating_count desc")
            .limit(limit)
    }

    private func altNameQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
        let esc = IGDBQuery.escape(text)
        var clause = "alternative_names.name ~ *\"\(esc)\"*"
        if let ids = platformIGDBIDs, !ids.isEmpty {
            clause += " & platforms = \(IGDBQuery.idSet(ids))"
        }
        return IGDBQuery()
            .fields(IGDBFields.search)
            .filter(clause)
            .limit(limit)
    }

    // MARK: - Networking (minimal, dedicated — see the type doc)

    private func tryRun(_ query: IGDBQuery) async -> [IGDBSearchResult] {
        (try? await run(query)) ?? []
    }

    private func run(_ query: IGDBQuery) async throws -> [IGDBSearchResult] {
        let data = try await request(body: query.build())
        if let cache { await cache.store(Self.cacheEntries(from: data)) }
        let dtos = try JSONDecoder().decode([IGDBGameDTO].self, from: data)
        return dtos.map(searchResult(from:))
    }

    private func request(body: String) async throws -> Data {
        guard let clientID = await credentials()?.clientID else {
            throw IGDBError.missingCredentials
        }
        try await rateLimiter.acquire()
        let token = try await tokenProvider.validToken()
        let (data, response) = try await send(body: body, clientID: clientID, token: token)
        if response.statusCode == 401 {
            let fresh = try await tokenProvider.forceRefresh()
            try await rateLimiter.acquire()
            let (data2, response2) = try await send(body: body, clientID: clientID, token: fresh)
            return try validate(data2, response2)
        }
        return try validate(data, response)
    }

    private func send(body: String, clientID: String, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("games"))
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
            throw HTTPStatusError(status: response.statusCode, body: data, retryAfter: response.retryAfterSeconds)
        }
        return data
    }

    // MARK: - DTO → result

    private func searchResult(from dto: IGDBGameDTO) -> IGDBSearchResult {
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

    private static func cacheEntries(from data: Data) -> [CatalogCacheEntry] {
        IGDBClient.rawGameEntries(from: data, now: Date()) ?? []
    }

    // MARK: - Merge (pure, unit-tested)

    /// Concatenate result groups in priority order (search, then name-prefix, then
    /// alt-name), de-duping by game id — the first occurrence wins, so `search`
    /// ranking is preserved — and cap to `limit`.
    static func merge(_ groups: [[IGDBSearchResult]], limit: Int) -> [IGDBSearchResult] {
        var seen = Set<Int64>()
        var out: [IGDBSearchResult] = []
        for group in groups {
            for result in group where !seen.contains(result.id) {
                seen.insert(result.id)
                out.append(result)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

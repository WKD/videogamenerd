import Foundation
import GRDB

/// Title search over the local `catalog_cache` so Quick Add can show instant,
/// offline catalogue hits *before* the debounced IGDB call (PLAN §6.1: "local
/// library + catalog cache instantly"). Works with no network / no credentials.
protocol CatalogTitleSearching: Sendable {
    /// Accent-insensitive, multi-token prefix search over cached game titles +
    /// alternative names. Returns catalogue search results (same shape as a live
    /// IGDB hit) so Quick Add merges them the same way.
    func searchTitles(_ text: String, limit: Int) async -> [IGDBSearchResult]
}

/// An in-process index over the raw IGDB JSON kept in `catalog_cache`. The table
/// keys blobs by igdb id, so rather than a side table / FTS (which would need a
/// migration), we parse-and-scan in memory: a small index built once from the DB
/// (a few thousand entries is trivial) and **refreshed on every write** — so a
/// game seen in any IGDB search this or a prior session is instantly searchable
/// offline next time.
///
/// A reference type (actor) shared by every copy of the value-type
/// ``CatalogCacheStore``, so `store(_:)` write-throughs and the Quick Add search
/// all see the one index.
actor CatalogTitleIndex {
    private struct Indexed {
        let result: IGDBSearchResult
        /// Folded (case/diacritic-insensitive) tokens of title + alt names.
        let tokens: [String]
    }

    private var byID: [Int64: Indexed] = [:]
    private var loaded = false
    private let catalog: PlatformCatalog

    init(catalog: PlatformCatalog) { self.catalog = catalog }

    /// One-time bulk load from the DB (idempotent). Called lazily on the first
    /// search so an app with an existing cache is searchable at once.
    func loadIfNeeded(reader: any DatabaseReader) async {
        guard !loaded else { return }
        loaded = true
        let rows: [(Int64, Data)] = (try? await reader.read { db in
            try Row.fetchAll(db, sql: "SELECT igdb_id, json FROM catalog_cache").map { row in
                (row["igdb_id"] as Int64, Data((row["json"] as String).utf8))
            }
        }) ?? []
        for (id, json) in rows { index(id: id, json: json) }
    }

    /// Write-through: add / refresh entries as they are cached.
    func upsert(_ entries: [CatalogCacheEntry]) {
        for entry in entries { index(id: entry.igdbID, json: entry.json) }
    }

    private func index(id: Int64, json: Data) {
        guard let dto = try? JSONDecoder().decode(IGDBGameDTO.self, from: json) else { return }
        let result = Self.searchResult(from: dto, catalog: catalog)
        guard !result.name.isEmpty else { return }
        let tokens = ([result.name] + result.alternativeNames).flatMap(Self.foldTokens)
        byID[id] = Indexed(result: result, tokens: tokens)
    }

    /// Rank matches: title-prefix first, then more exact token matches, then title
    /// then id (stable). Every query token must prefix some haystack token (AND —
    /// mirrors the FTS multi-token prefix semantics of the live search).
    func search(_ text: String, limit: Int) -> [IGDBSearchResult] {
        let queryTokens = Self.foldTokens(text)
        guard !queryTokens.isEmpty, limit > 0 else { return [] }
        var scored: [(result: IGDBSearchResult, score: Int)] = []
        for indexed in byID.values {
            guard let score = Self.matchScore(queryTokens: queryTokens, haystack: indexed.tokens) else { continue }
            scored.append((indexed.result, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let t = a.result.name.localizedCaseInsensitiveCompare(b.result.name)
            if t != .orderedSame { return t == .orderedAscending }
            return a.result.id < b.result.id
        }
        return scored.prefix(limit).map(\.result)
    }

    // MARK: - Pure helpers

    /// Fold to case/diacritic-insensitive tokens, split on any non-alphanumeric
    /// (so "NieR:Automata" → ["nier","automata"], "Pokémon" → ["pokemon"]).
    static func foldTokens(_ text: String) -> [String] {
        TitleNormalizer.normalize(text, level: .fold)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// `nil` when not every query token prefixes some haystack token; otherwise a
    /// score (exact-token matches count double; a title-start prefix is a big
    /// bonus so "blood" ranks *Bloodborne* above a game merely containing "blood").
    static func matchScore(queryTokens: [String], haystack: [String]) -> Int? {
        guard !haystack.isEmpty else { return nil }
        var score = 0
        for q in queryTokens {
            guard let hit = haystack.first(where: { $0.hasPrefix(q) }) else { return nil }
            score += (hit == q) ? 2 : 1
        }
        if let first = haystack.first, let q0 = queryTokens.first, first.hasPrefix(q0) { score += 5 }
        return score
    }

    /// DTO → `IGDBSearchResult` (mirrors `IGDBClient`'s mapping; kept here so the
    /// index is self-contained and needs no actor hop into the client).
    static func searchResult(from dto: IGDBGameDTO, catalog: PlatformCatalog) -> IGDBSearchResult {
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
}

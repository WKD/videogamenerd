import Foundation

/// Autocomplete for Quick Add (PLAN §5.1 / §6.1), now a true ``IGDBClient``
/// extension so it runs on the **same** request pipeline as every other call
/// (token, rate-limit, retry, 401-refresh) rather than a parallel request path.
///
/// The services lane found that IGDB `search "…"` gives the cleanest autocomplete
/// ordering but returns **nothing** for mid-word prefixes ("bloodb") and for
/// alt-name-only titles ("chevaliers de baphomet" → *Broken Sword*). This runs the
/// two documented fallbacks and merges them behind `search`:
///
///  1. `search "text"`                              — the ranked primary path.
///  2. `where name ~ "text"*`                        — name-prefix (fixes "bloodb").
///  3. `where alternative_names.name ~ *"text"*`     — alt-name contains (fixes the
///                                                     French box titles).
///
/// Verified live against the six brief cases: 1+2 recover "bloodb" → Bloodborne, 3
/// recovers "chevaliers de baphomet" → Broken Sword, and `search` alone already
/// covers "zelda" / "ico" / "metal gear solid legacy".
extension IGDBClient {
    /// Autocomplete `text`, optionally constrained to `platformIGDBIDs`. Runs
    /// `search` first and, only when it is thin (fewer than `fallbackThreshold`
    /// hits), the two fallbacks; merges keeping `search` order, then name-prefix,
    /// then alt-name, de-duping by game id. Throws `IGDBError.missingCredentials`
    /// (offline / not-configured) — the caller falls back to local + manual rows.
    func autocomplete(
        _ text: String,
        platformIGDBIDs: [Int]? = nil,
        limit: Int = 12,
        fallbackThreshold: Int = 4
    ) async throws -> [IGDBSearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        let primary = try await runGamesSearch(
            IGDBAutocomplete.searchQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        try Task.checkCancellation()
        if primary.count >= fallbackThreshold {
            return IGDBAutocomplete.merge([primary], limit: limit)
        }

        // Run the two fallbacks (best-effort — a failing fallback never sinks the
        // primary results we already have).
        async let prefixResults = tryAutocomplete(
            IGDBAutocomplete.namePrefixQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        async let altResults = tryAutocomplete(
            IGDBAutocomplete.altNameQuery(trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
        return IGDBAutocomplete.merge([primary, await prefixResults, await altResults], limit: limit)
    }

    private func tryAutocomplete(_ query: IGDBQuery) async -> [IGDBSearchResult] {
        (try? await runGamesSearch(query)) ?? []
    }
}

/// The pure, network-free pieces of autocomplete — the three query builders and
/// the merge — kept as a namespace so they stay directly unit-testable (the live
/// behaviour rides on ``IGDBClient``'s pipeline above).
enum IGDBAutocomplete {

    // MARK: - Queries

    static func searchQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
        var q = IGDBQuery().search(text).fields(IGDBFields.search).limit(limit)
        if let ids = platformIGDBIDs, !ids.isEmpty {
            q = q.filter("platforms = \(IGDBQuery.idSet(ids))")
        }
        return q
    }

    static func namePrefixQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
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

    static func altNameQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int) -> IGDBQuery {
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

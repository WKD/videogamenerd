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

        // A year in the query ("super mario bros 1985") disambiguates long series: the
        // plain search returns 12 of dozens of entries and the wanted one may not be among
        // them. Year-constrained lookups run first; the literal text still runs last so
        // titles that contain a year ("Cyberpunk 2077", "FIFA 2005") keep working.
        let split = IGDBAutocomplete.splitYear(trimmed)
        if let year = split.year, split.text.count >= 3 {
            async let yearSearch = tryAutocomplete(IGDBAutocomplete.searchQuery(
                split.text, platformIGDBIDs: platformIGDBIDs, limit: limit, releaseYear: year))
            async let yearPrefix = tryAutocomplete(IGDBAutocomplete.namePrefixQuery(
                split.text, platformIGDBIDs: platformIGDBIDs, limit: limit, releaseYear: year))
            async let literal = tryAutocomplete(IGDBAutocomplete.searchQuery(
                trimmed, platformIGDBIDs: platformIGDBIDs, limit: limit))
            let merged = IGDBAutocomplete.merge([await yearSearch, await yearPrefix, await literal], limit: limit)
            try Task.checkCancellation()
            if !merged.isEmpty { return merged }
            // Nothing for that year (typo, regional date): fall through to the plain path
            // on the text without the year.
            return try await autocomplete(split.text, platformIGDBIDs: platformIGDBIDs,
                                          limit: limit, fallbackThreshold: fallbackThreshold)
        }

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

    /// Splits a trailing/embedded release year off a query: "super mario bros 1985" →
    /// ("super mario bros", 1985); "(1985)" works too. A year is a standalone 4-digit
    /// token in 1970…(this year + 2), and only counts when real title text remains
    /// (so "1942" or "2048" alone stay titles). With several candidates the last wins.
    static func splitYear(_ text: String, now: Date = Date()) -> (text: String, year: Int?) {
        let maxYear = Calendar(identifier: .gregorian).component(.year, from: now) + 2
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var found: (index: Int, year: Int)?
        for (i, token) in tokens.enumerated() {
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[],."))
            if core.count == 4, core.allSatisfy(\.isNumber), let y = Int(core), (1970...maxYear).contains(y) {
                found = (i, y)
            }
        }
        guard let found else { return (text, nil) }
        tokens.remove(at: found.index)
        let rest = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard rest.filter(\.isLetter).count >= 3 else { return (text, nil) }
        return (rest, found.year)
    }

    /// `release_dates.y` covers every regional / platform release of the entry, so
    /// "1987" still finds a 1985 game that reached Europe in 1987.
    private static func yearClause(_ year: Int?) -> String? {
        year.map { "release_dates.y = \($0)" }
    }

    static func searchQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int,
                            releaseYear: Int? = nil) -> IGDBQuery {
        var q = IGDBQuery().search(text).fields(IGDBFields.search).limit(limit)
        var clauses: [String] = []
        if let ids = platformIGDBIDs, !ids.isEmpty { clauses.append("platforms = \(IGDBQuery.idSet(ids))") }
        if let y = yearClause(releaseYear) { clauses.append(y) }
        if !clauses.isEmpty { q = q.filter(clauses.joined(separator: " & ")) }
        return q
    }

    static func namePrefixQuery(_ text: String, platformIGDBIDs: [Int]?, limit: Int,
                                releaseYear: Int? = nil) -> IGDBQuery {
        let esc = IGDBQuery.escape(text)
        var clause = "name ~ \"\(esc)\"*"
        if let ids = platformIGDBIDs, !ids.isEmpty {
            clause += " & platforms = \(IGDBQuery.idSet(ids))"
        }
        if let y = yearClause(releaseYear) { clause += " & \(y)" }
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

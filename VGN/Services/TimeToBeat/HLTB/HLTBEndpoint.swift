import Foundation

// =============================================================================
//  EVERYTHING HowLongToBeat-specific lives in THIS ONE FILE (PLAN §5.3).
//
//  When HLTB rotates its private search endpoint / key again, this is the only
//  place to fix — the client, matcher, fill path and UI are all endpoint-agnostic.
//
//  Ported from the maintained open-source client
//      ScrappyCocco/HowLongToBeat-PythonAPI  (branch `master`, read 2026-09-19)
//      github.com/ScrappyCocco/HowLongToBeat-PythonAPI
//      → howlongtobeatpy/HTMLRequests.py  (endpoint discovery, headers, POST body)
//      → howlongtobeatpy/JSONResultParser.py  (response field names)
//  cross-checked against the JS wrapper
//      ckatzorke/howlongtobeat  (github.com/ckatzorke/howlongtobeat, read 2026-09-19).
//
//  Today's mechanics (2026-09-19):
//   - Base site: https://howlongtobeat.com/
//   - The search endpoint path is NOT constant: the site's Next.js app bundles a
//     `fetch("/api/<word>/<token>…", { method: "POST" })` call whose `<token>` is
//     assembled from string literals in the JS. We discover it by fetching the
//     homepage, then a `/_next/static/chunks/*.js` app chunk, then extracting the
//     path (with a `api/s/` fallback for older builds).
//   - Headers: content-type application/json, Referer + Origin the site itself, a
//     desktop User-Agent (some builds 403 an empty UA).
//   - POST body: { searchType:"games", searchTerms:[…], searchPage, size,
//     searchOptions:{ games:{…}, … }, useCache:true }.
//   - Response: { data: [ { game_id, game_name, game_alias, release_world,
//     comp_main, comp_plus, comp_100, profile_platform, … } ], count }.
//     comp_* are SECONDS; release_world is the world release year.
// =============================================================================

/// The one place HLTB request/response mechanics live. Pure and Foundation-only —
/// no I/O — so every part (discovery parsing, payload, DTO) is unit-testable with
/// synthetic strings.
enum HLTBEndpoint {
    static let baseString = "https://howlongtobeat.com/"
    static let base = URL(string: baseString)!
    static let referer = "https://howlongtobeat.com/"
    static let origin = "https://howlongtobeat.com"
    /// A plain desktop UA — the site 403s an empty/absent one.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    static let searchPageSize = 20
    /// The historical constant path, used when discovery finds nothing (older builds).
    static let fallbackSearchPath = "api/s/"

    // MARK: - Discovery

    /// A resolved search endpoint: the path (no leading slash) plus an optional extra
    /// body key/value some builds require. Cached for one run.
    struct Discovery: Sendable, Hashable, Codable {
        var searchPath: String
        var payloadKey: String?
        var payloadValue: String?

        var searchURL: URL { URL(string: baseString + searchPath) ?? base }

        static let fallback = Discovery(searchPath: fallbackSearchPath, payloadKey: nil, payloadValue: nil)
    }

    /// Extract the `/_next/static/chunks/*.js` app-chunk paths referenced by the
    /// homepage HTML, most-specific (`_app`/`main`) first so the search fetch is
    /// found quickly.
    static func scriptPaths(inHTML html: String) -> [String] {
        let pattern = #"src="(/_next/static/chunks/[^"]+?\.js)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var paths: [String] = []
        for m in re.matches(in: html, range: range) {
            if let r = Range(m.range(at: 1), in: html) { paths.append(String(html[r])) }
        }
        // Prefer app/main chunks (they carry the fetch), keep order otherwise, dedupe.
        var seen = Set<String>()
        let ordered = paths.filter { seen.insert($0).inserted }
        return ordered.sorted { a, b in
            func rank(_ s: String) -> Int {
                if s.contains("_app") { return 0 }
                if s.contains("main") { return 1 }
                if s.contains("pages") { return 2 }
                return 3
            }
            return rank(a) < rank(b)
        }
    }

    /// Resolve the search endpoint from one app-chunk's JavaScript. Handles the
    /// current shape — a quoted `"/api/<word>/"` base path optionally followed by a
    /// concatenated token (`.concat("a","b")` or `+ "a" + "b"`) before the request
    /// options object — and the older bare-literal form (`"/api/s/"`). Returns nil
    /// when nothing plausible is found (the caller then stops with a `schemaMismatch`
    /// reject: "discovery failed").
    static func resolveDiscovery(fromScript js: String) -> Discovery? {
        // The base path is a *quoted* literal that starts with `/api/`.
        let pattern = #"["'`](/api/[A-Za-z0-9_/]*)["'`]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(js.startIndex..., in: js)
        guard let m = re.firstMatch(in: js, range: full),
              let pathRange = Range(m.range(at: 1), in: js),
              let litRange = Range(m.range, in: js) else { return nil }

        var basePath = String(js[pathRange])                // "/api/seek/"
        basePath.removeFirst("/api/".count)                 // "seek/"

        // Everything after the closing quote up to the options object `{…}` may carry
        // a concatenated token; join every url-safe quoted literal in that window.
        let afterLiteral = js[litRange.upperBound...]
        let windowEnd = afterLiteral.firstIndex(of: "{") ?? afterLiteral.endIndex
        let window = String(afterLiteral[..<windowEnd].prefix(400))
        let token = urlSafeLiterals(in: window)

        return Discovery(searchPath: "api/" + basePath + token, payloadKey: nil, payloadValue: nil)
    }

    /// Concatenate, in order, every url-safe quoted string literal in `s` (the token
    /// pieces of `.concat("a","b")` / `"a"+"b"`). A literal with any non-token
    /// character is skipped, so a stray argument never corrupts the endpoint.
    static func urlSafeLiterals(in s: String) -> String {
        let pattern = #"["'`]([A-Za-z0-9_-]*)["'`]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(s.startIndex..., in: s)
        var out = ""
        for m in re.matches(in: s, range: range) {
            if let r = Range(m.range(at: 1), in: s) { out += String(s[r]) }
        }
        return out
    }

    // MARK: - Request

    /// Headers every HLTB request carries (the site 403s without a UA / Origin).
    static func headers() -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "*/*",
            "User-Agent": userAgent,
            "Referer": referer,
            "Origin": origin,
        ]
    }

    /// The POST body for a search, ported from `HTMLRequests.get_search_request_data`.
    static func searchPayload(title: String, page: Int = 1, discovery: Discovery) -> Data {
        let terms = title
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var body: [String: Any] = [
            "searchType": "games",
            "searchTerms": terms,
            "searchPage": page,
            "size": searchPageSize,
            "searchOptions": [
                "games": [
                    "userId": 0,
                    "platform": "",
                    "sortCategory": "popular",
                    "rangeCategory": "main",
                    "rangeTime": ["min": 0, "max": 0],
                    "gameplay": ["perspective": "", "flow": "", "genre": ""],
                    "rangeYear": ["min": "", "max": ""],
                    "modifier": "",
                ],
                "users": ["sortCategory": "postcount"],
                "lists": ["sortCategory": "follows"],
                "filter": "",
                "sort": 0,
                "randomizer": 0,
            ],
            "useCache": true,
        ]
        if let key = discovery.payloadKey, let value = discovery.payloadValue {
            body[key] = value
        }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// Build the search `URLRequest` for `title`.
    static func searchRequest(title: String, page: Int = 1, discovery: Discovery) -> URLRequest {
        var request = URLRequest(url: discovery.searchURL)
        request.httpMethod = "POST"
        for (k, v) in headers() { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = searchPayload(title: title, page: page, discovery: discovery)
        return request
    }

    /// The homepage GET, used to discover the endpoint.
    static func homepageRequest() -> URLRequest {
        var request = URLRequest(url: base)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }

    /// A GET for one discovered app-chunk script.
    static func scriptRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseString + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? base)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: - Response DTO → candidates

    /// The search response envelope (`JSONResultParser`): a `data` array of games.
    private struct SearchResponse: Decodable {
        var data: [Game]
        struct Game: Decodable {
            var game_id: Int64
            var game_name: String
            var game_alias: String?
            var release_world: Int?
            var comp_main: Int?
            var comp_plus: Int?
            var comp_100: Int?
            var profile_platform: String?
        }
    }

    /// Decode a search response body into candidates. Throws when the body is not the
    /// expected `{ data: [...] }` shape (the client turns that into a schemaMismatch
    /// reject and stops — PLAN §5.3).
    static func parseCandidates(_ data: Data) throws -> [HLTBCandidate] {
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.data.map { g in
            HLTBCandidate(
                id: g.game_id,
                name: g.game_name,
                aliases: splitList(g.game_alias),
                releaseYear: (g.release_world ?? 0) > 0 ? g.release_world : nil,
                mainSeconds: positive(g.comp_main),
                mainExtraSeconds: positive(g.comp_plus),
                completionistSeconds: positive(g.comp_100),
                platforms: splitList(g.profile_platform))
        }
    }

    /// True when the body at least parses as the search envelope (validator hook).
    static func looksLikeSearchResponse(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(SearchResponse.self, from: data)) != nil
    }

    private static func positive(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

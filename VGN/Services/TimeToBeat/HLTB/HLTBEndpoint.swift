import Foundation

// =============================================================================
//  EVERYTHING HowLongToBeat-specific lives in THIS ONE FILE (PLAN §5.3).
//
//  When HLTB rotates its private search endpoint / token scheme again, this is the
//  only place to fix — the client, matcher, fill path and UI are all
//  endpoint-agnostic.
//
//  Ported from the maintained open-source client
//      ScrappyCocco/HowLongToBeat-PythonAPI  (branch `master`, read 2026-09-19,
//      commit read via raw githubusercontent — HTMLRequests.py + JSONResultParser.py)
//      github.com/ScrappyCocco/HowLongToBeat-PythonAPI
//  cross-checked against the JS wrapper ckatzorke/howlongtobeat, and — decisively —
//  against howlongtobeat.com's own app chunk, read live 2026-09-19 (see docs/hltb.md
//  for the recorded request log). The mechanics below are what the live site does.
//
//  Today's mechanics (verified live 2026-09-19):
//   - Base site: https://howlongtobeat.com/  (the CDN 403s bare clients, so browser
//     Accept / User-Agent headers are mandatory on every GET).
//   - Endpoint discovery: GET the homepage → its `/_next/static/chunks/*.js` app
//     chunks (turbopack, opaque hashed names — there is no `_app`/`main` chunk any
//     more) → find the one chunk that contains a `fetch("/api/<path>", {method:"POST"…})`
//     and take that whole `<path>` (currently `search/site`). No token is concatenated
//     into the URL; the path is a plain literal.
//   - Per-session auth: GET `<searchPath>/init?t=<ms>` → JSON `{ token, hpKey, hpVal }`.
//     The search then carries headers `x-auth-token: token`, `x-hp-key: hpKey`,
//     `x-hp-val: hpVal`, AND injects `body[hpKey] = hpVal` into the POST payload. The
//     field names are read defensively (any field whose name contains "key"/"val"), so
//     a rename survives. The token embeds the caller IP + UA and expires — fetch it
//     once per run; a 403 later means it lapsed (we stop; the owner re-runs).
//     **2026-09-24:** `/init` now answers `{ token }` only (no hpKey/hpVal). A token-only
//     reply is accepted: the search then sends just `x-auth-token` — no `x-hp-*` headers,
//     no body field. Whether the search accepts that is UNVERIFIED (the owner's next live
//     retry tells); the search validator stays strict, so a refusal stops the run cleanly.
//   - POST body: { searchType:"games", searchTerms:[…], searchPage, size,
//     searchOptions:{ games:{…}, … }, useCache:true, <hpKey>:<hpVal> }.
//   - Response: { data: [ { game_id, game_name, game_alias, release_world,
//     comp_main, comp_plus, comp_100, profile_platform, … } ], count, … }.
//     comp_* are SECONDS (Bloodborne comp_main == 115887 ≈ 32 h); release_world is the
//     world release year.
// =============================================================================

/// The one place HLTB request/response mechanics live. Pure and Foundation-only —
/// no I/O — so every part (discovery parsing, auth parsing, payload, DTO) is
/// unit-testable with synthetic strings.
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
    /// The historical constant path, used when discovery finds nothing (the upstream's
    /// static `SEARCH_URL`). A stale endpoint then surfaces as a reject on the search.
    static let fallbackSearchPath = "api/s/"

    // MARK: - Discovery

    /// A resolved search endpoint: the path (no leading slash), e.g. `api/search/site`.
    /// Cached for one run. The token/`hpKey`/`hpVal` are a separate per-session `Auth`.
    struct Discovery: Sendable, Hashable, Codable {
        var searchPath: String

        var searchURL: URL { URL(string: baseString + searchPath) ?? base }
        /// The security-init endpoint for this search path (`<searchPath>/init`).
        var initPath: String { searchPath + "/init" }

        init(searchPath: String) { self.searchPath = searchPath }

        static let fallback = Discovery(searchPath: fallbackSearchPath)
    }

    /// The per-session credentials the `/init` endpoint hands out. `key`/`value` are
    /// both an `x-hp-*` header pair and a dynamic field injected into the POST body.
    ///
    /// Since **2026-09-24** `/init` answers `{ "token": "…" }` only — no `hpKey`/`hpVal`
    /// (seen in the owner's reject log). The pair is therefore optional: when absent the
    /// search carries only `x-auth-token` (no `x-hp-*` header, no body field); when present
    /// it behaves exactly as before. Whether the search accepts a token-only session is
    /// **unverified** — the search validator stays strict, so a refusal stops cleanly.
    struct Auth: Sendable, Hashable, Codable {
        var token: String
        var key: String?
        var value: String?

        init(token: String, key: String? = nil, value: String? = nil) {
            self.token = token
            self.key = key
            self.value = value
        }

        /// The `hpKey`/`hpVal` pair, when `/init` handed one out.
        var hpPair: (key: String, value: String)? {
            guard let key, let value else { return nil }
            return (key, value)
        }
    }

    /// Extract the `/_next/static/chunks/*.js` app-chunk paths referenced by the
    /// homepage HTML, in document order, deduped. The build is turbopack now, so the
    /// names are opaque hashes with no `_app`/`main` to prioritise — we try them in
    /// order until one carries the search `fetch`.
    static func scriptPaths(inHTML html: String) -> [String] {
        let pattern = #"src="(/_next/static/chunks/[^"]+?\.js)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var paths: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: range) {
            if let r = Range(m.range(at: 1), in: html) {
                let p = String(html[r])
                if seen.insert(p).inserted { paths.append(p) }
            }
        }
        return paths
    }

    /// Resolve the search endpoint from one app-chunk's JavaScript. Mirrors the
    /// reference client: find the `fetch("/api/<path>", { … method:"POST" … })` call —
    /// the POST method is what marks the real search endpoint — and take the whole
    /// `<path>` (which may contain slashes, e.g. `search/site`). Returns nil when the
    /// chunk carries no such call (the caller tries the next chunk, then the fallback).
    static func resolveDiscovery(fromScript js: String) -> Discovery? {
        let pattern =
            #"fetch\s*\(\s*["'`]/api/([A-Za-z0-9_/]+)[^"'`]*["'`]\s*,\s*\{[^}]*method\s*:\s*["'`]POST["'`][^}]*\}"#
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let full = NSRange(js.startIndex..., in: js)
        guard let m = re.firstMatch(in: js, range: full),
              let pathRange = Range(m.range(at: 1), in: js) else { return nil }
        var path = String(js[pathRange])
        while path.hasSuffix("/") { path.removeLast() }   // "search/site/" → "search/site"
        guard !path.isEmpty else { return nil }
        return Discovery(searchPath: "api/" + path)
    }

    /// Parse the `/init` response into per-session `Auth`. `token` is required and must be
    /// a non-empty string. The key/value pair is taken from whichever fields' names contain
    /// "key" / "val" (historically `hpKey` / `hpVal`), so a field rename doesn't break the
    /// port; since 2026-09-24 the site sends **token only**, which is accepted as a
    /// token-only session. Returns nil (→ the client stops with a schemaMismatch reject)
    /// when the body is not a JSON object, has no string `token`, or carries only half of
    /// the key/value pair.
    static func parseAuth(_ data: Data) -> Auth? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        var key: String?
        var value: String?
        for (name, raw) in obj {
            guard let v = raw as? String else { continue }
            let lower = name.lowercased()
            if lower == "token" { continue }
            if lower.contains("key") { key = v }
            if lower.contains("val") { value = v }
        }
        switch (key, value) {
        case let (k?, val?): return Auth(token: token, key: k, value: val)
        case (nil, nil):     return Auth(token: token)
        default:             return nil   // half a pair — an unknown shape, stop
        }
    }

    // MARK: - Request

    /// Headers a search request carries. Without the browser UA / Origin the CDN 403s;
    /// without `x-auth-token` (plus the `x-hp-*` pair when `/init` sent one) the search
    /// endpoint 403s.
    static func headers(auth: Auth?) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Accept-Language": "en-GB,en;q=0.9",
            "User-Agent": userAgent,
            "Referer": referer,
            "Origin": origin,
        ]
        if let auth {
            h["x-auth-token"] = auth.token
            if let pair = auth.hpPair {
                h["x-hp-key"] = pair.key
                h["x-hp-val"] = pair.value
            }
        }
        return h
    }

    /// The POST body for a search, ported from `HTMLRequests.get_search_request_data`.
    /// When `auth` is present it injects the dynamic `body[key] = value` field the site
    /// requires alongside the header trio.
    static func searchPayload(title: String, page: Int = 1, auth: Auth?) -> Data {
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
                    "gameplay": ["perspective": "", "flow": "", "genre": "", "difficulty": ""],
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
        if let pair = auth?.hpPair { body[pair.key] = pair.value }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// Build the search `URLRequest` for `title`.
    static func searchRequest(title: String, page: Int = 1, discovery: Discovery, auth: Auth?) -> URLRequest {
        var request = URLRequest(url: discovery.searchURL)
        request.httpMethod = "POST"
        for (k, v) in headers(auth: auth) { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = searchPayload(title: title, page: page, auth: auth)
        return request
    }

    /// The homepage GET, used to discover the endpoint.
    static func homepageRequest() -> URLRequest { browserGET(base) }

    /// A GET for one discovered app-chunk script.
    static func scriptRequest(path: String) -> URLRequest {
        let url = URL(string: baseString + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? base
        return browserGET(url)
    }

    /// The per-session auth-token GET: `<searchPath>/init?t=<ms>`.
    static func authInitRequest(discovery: Discovery) -> URLRequest {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: baseString + discovery.initPath + "?t=\(ms)") ?? base
        return browserGET(url)
    }

    /// A browser-like GET (the CDN answers 403 to bare clients).
    private static func browserGET(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
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
            var comp_all: Int?
            var comp_main_count: Int?
            var comp_plus_count: Int?
            var comp_100_count: Int?
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
                platforms: splitList(g.profile_platform),
                allStylesSeconds: positive(g.comp_all),
                mainCount: positive(g.comp_main_count),
                mainExtraCount: positive(g.comp_plus_count),
                completionistCount: positive(g.comp_100_count))
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

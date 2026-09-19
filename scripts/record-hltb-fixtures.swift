#!/usr/bin/env swift
import Foundation

// record-hltb-fixtures.swift — bounded live recorder for the HowLongToBeat fallback
// (PLAN §5.3). Self-contained (scripts don't link the app target): it mirrors the
// request mechanics isolated in `VGN/Services/TimeToBeat/HLTB/HLTBEndpoint.swift`,
// verified live against howlongtobeat.com on 2026-09-19 (see docs/hltb.md).
//
// Flow (what the live site does): GET homepage → find the `/_next/static/chunks/*.js`
// chunk carrying `fetch("/api/<path>",{method:"POST"…})` → GET `<path>/init?t=<ms>` for
// the per-session `{token,hpKey,hpVal}` → POST each search with the `x-auth-token` /
// `x-hp-key` / `x-hp-val` headers and a `body[hpKey]=hpVal` field.
//
// HARD LIMITS — a public site with no account at stake, but stay polite:
//   • at most 25 requests total, ≥ 2 s apart, serial,
//   • STOP on the FIRST unexpected response (non-200, HTML/captcha, non-JSON, wrong
//     shape) — do not retry, do not vary. Print what was sent and received.
// Search responses are trimmed to the first 5 results and saved as
// VGNTests/Fixtures/hltb-search-<slug>.json. Discovery + init fixtures are hand-authored
// (minimal + sanitised) — this recorder never dumps whole minified bundles or the token
// (it embeds the caller IP). No credentials are involved.
//
// Usage:  swift scripts/record-hltb-fixtures.swift          (interpreted)
//    or:  swiftc -O -o /tmp/hltb-rec scripts/record-hltb-fixtures.swift && /tmp/hltb-rec
// Both run to completion: I/O is synchronous (DispatchSemaphore), stdout is unbuffered,
// and every request has a 15 s timeout.

setvbuf(stdout, nil, _IONBF, 0)

let base = "https://howlongtobeat.com/"
let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       + "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("VGNTests/Fixtures")
let trimResults = 5

var requestBudget = 25
var requestsUsed = 0

let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = 15
cfg.timeoutIntervalForResource = 20
let session = URLSession(configuration: cfg)

struct StopError: Error { let why: String }

func spend() throws {
    guard requestBudget > 0 else { throw StopError(why: "request budget exhausted") }
    requestBudget -= 1
    requestsUsed += 1
}

/// Synchronous request (no async runtime — robust interpreted or compiled).
func send(_ req: URLRequest) throws -> (Int, Data, String?) {
    try spend()
    let sem = DispatchSemaphore(value: 0)
    var result: (Int, Data, String?)?
    var failure: Error?
    session.dataTask(with: req) { data, resp, err in
        if let http = resp as? HTTPURLResponse, let data = data {
            result = (http.statusCode, data, http.value(forHTTPHeaderField: "Content-Type"))
        } else {
            failure = err ?? StopError(why: "no response")
        }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 18) == .timedOut { throw StopError(why: "request timed out") }
    if let failure { throw failure }
    return result!
}

func browserGET(_ urlString: String, accept: String) -> URLRequest {
    var req = URLRequest(url: URL(string: urlString)!)
    req.httpMethod = "GET"
    req.setValue(ua, forHTTPHeaderField: "User-Agent")
    req.setValue(base, forHTTPHeaderField: "Referer")
    req.setValue(accept, forHTTPHeaderField: "Accept")
    req.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    return req
}

func pauseBetween() { Thread.sleep(forTimeInterval: 2.2) }

func matches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern,
        options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
    let r = NSRange(s.startIndex..., in: s)
    return re.matches(in: s, range: r).compactMap { m in
        m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } : nil
    }
}

func firstGroup(_ pattern: String, in s: String) -> String? { matches(pattern, in: s).first }

func slug(_ t: String) -> String {
    t.lowercased().replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        .replacingOccurrences(of: "--", with: "-")
}

// Discovery: homepage → app chunk carrying the POST fetch → its "/api/<path>".
func discover() throws -> String {
    let (status, data, _) = try send(browserGET(base,
        accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"))
    guard status == 200 else { throw StopError(why: "homepage returned HTTP \(status)") }
    let html = String(decoding: data, as: UTF8.self)
    let scriptPaths = matches(#"src="(/_next/static/chunks/[^"]+?\.js)""#, in: html)
    print("  \(scriptPaths.count) app chunks; scanning for the POST fetch…")
    let fetchPat =
        #"fetch\s*\(\s*["'`]/api/([A-Za-z0-9_/]+)[^"'`]*["'`]\s*,\s*\{[^}]*method\s*:\s*["'`]POST["'`][^}]*\}"#
    for path in scriptPaths.prefix(12) {
        pauseBetween()
        let (s, d, _) = try send(browserGET(base + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                            accept: "*/*"))
        guard s == 200 else { continue }
        if var p = firstGroup(fetchPat, in: String(decoding: d, as: UTF8.self)) {
            while p.hasSuffix("/") { p.removeLast() }
            return "api/" + p
        }
    }
    return "api/s"   // historical fallback
}

// Auth: GET <search>/init?t=<ms> → { token, hpKey, hpVal } (field names read defensively).
func fetchAuth(searchPath: String) throws -> (token: String, key: String, value: String) {
    let ms = Int(Date().timeIntervalSince1970 * 1000)
    let (status, data, ct) = try send(browserGET(base + searchPath + "/init?t=\(ms)", accept: "*/*"))
    guard status == 200 else { throw StopError(why: "auth init returned HTTP \(status) — STOP") }
    guard (ct ?? "").lowercased().contains("json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = obj["token"] as? String else {
        throw StopError(why: "auth init was not the { token, … } envelope — STOP")
    }
    var key: String?, value: String?
    for (name, raw) in obj {
        guard let v = raw as? String else { continue }
        let l = name.lowercased()
        if l == "token" { continue }
        if l.contains("key") { key = v }
        if l.contains("val") { value = v }
    }
    guard let k = key, let val = value else { throw StopError(why: "auth init had no key/val pair — STOP") }
    return (token, k, val)
}

func postSearch(path: String, title: String,
                auth: (token: String, key: String, value: String)) throws -> (Int, Data, String?) {
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("*/*", forHTTPHeaderField: "Accept")
    req.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    req.setValue(ua, forHTTPHeaderField: "User-Agent")
    req.setValue(base, forHTTPHeaderField: "Referer")
    req.setValue("https://howlongtobeat.com", forHTTPHeaderField: "Origin")
    req.setValue(auth.token, forHTTPHeaderField: "x-auth-token")
    req.setValue(auth.key, forHTTPHeaderField: "x-hp-key")
    req.setValue(auth.value, forHTTPHeaderField: "x-hp-val")
    let terms = title.split(separator: " ").map(String.init)
    var payload: [String: Any] = [
        "searchType": "games", "searchTerms": terms, "searchPage": 1, "size": 20,
        "searchOptions": [
            "games": ["userId": 0, "platform": "", "sortCategory": "popular",
                      "rangeCategory": "main", "rangeTime": ["min": 0, "max": 0],
                      "gameplay": ["perspective": "", "flow": "", "genre": "", "difficulty": ""],
                      "rangeYear": ["min": "", "max": ""], "modifier": ""],
            "users": ["sortCategory": "postcount"], "lists": ["sortCategory": "follows"],
            "filter": "", "sort": 0, "randomizer": 0],
        "useCache": true,
    ]
    payload[auth.key] = auth.value
    req.httpBody = try JSONSerialization.data(withJSONObject: payload)
    return try send(req)
}

// MAIN
do {
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    print("Discovering the HLTB search endpoint…")
    let path = try discover()
    print("  endpoint: /\(path)")

    pauseBetween()
    print("Fetching the per-session auth token…")
    let auth = try fetchAuth(searchPath: path)
    print("  auth: token(\(auth.token.count) chars), key=\(auth.key), val(\(auth.value.count) chars)")

    // The task's required titles: four hits + one deliberate miss.
    let titles = ["Bloodborne", "Celeste", "Final Fantasy VII",
                  "The Legend of Zelda: The Wind Waker", "A Totally Fake Game 99999"]
    for title in titles {
        pauseBetween()
        print("Searching “\(title)”…")
        let (status, data, contentType) = try postSearch(path: path, title: title, auth: auth)
        guard status == 200 else { throw StopError(why: "search returned HTTP \(status) — STOP") }
        guard (contentType ?? "").lowercased().contains("json") else {
            throw StopError(why: "search content-type was \(contentType ?? "nil"), not JSON — STOP")
        }
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["data"] as? [[String: Any]] else {
            throw StopError(why: "search body was not the { data: […] } envelope — STOP")
        }
        // Trim to the first few results to keep fixtures small; keep the envelope shape.
        let trimmed = Array(results.prefix(trimResults))
        obj["data"] = trimmed
        obj["count"] = trimmed.count
        let slugName = title == "A Totally Fake Game 99999" ? "empty" : slug(title)
        let out = fixturesDir.appendingPathComponent("hltb-search-\(slugName).json")
        let outData = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try outData.write(to: out)
        print("  ✓ \(results.count) results (saved \(trimmed.count)) → \(out.lastPathComponent)")
    }
    print("Done. Requests used: \(requestsUsed)/25.")
} catch let e as StopError {
    FileHandle.standardError.write(Data("STOPPED: \(e.why)\nMade no further requests. (\(requestsUsed) used)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error) (\(requestsUsed) requests used)\n".utf8))
    exit(1)
}

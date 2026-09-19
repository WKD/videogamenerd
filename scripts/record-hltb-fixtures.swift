#!/usr/bin/env swift
import Foundation

// record-hltb-fixtures.swift — bounded live recorder for the HowLongToBeat fallback
// (PLAN §5.3). Self-contained (scripts don't link the app target): it mirrors the
// request mechanics isolated in `VGN/Services/TimeToBeat/HLTB/HLTBEndpoint.swift`,
// ported from ScrappyCocco/HowLongToBeat-PythonAPI (master, 2026-09-19).
//
// HARD LIMITS — this touches a public site with no account at stake, but stays polite:
//   • at most 12 requests total (discovery + a handful of searches),
//   • ≥ 2 s apart,
//   • STOP on the FIRST unexpected response (non-200, HTML/captcha, non-JSON, wrong
//     shape) — do not retry, do not vary. Print what was sent and received.
// Saves each search response as VGNTests/Fixtures/hltb-<slug>.json.
//
// Usage:  swift scripts/record-hltb-fixtures.swift
// No credentials are involved; nothing is logged that could be sensitive.

let base = "https://howlongtobeat.com/"
let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       + "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
let fixturesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("VGNTests/Fixtures")

var requestBudget = 12
let session = URLSession(configuration: .ephemeral)

struct StopError: Error { let why: String }

func spend() throws {
    guard requestBudget > 0 else { throw StopError(why: "request budget exhausted") }
    requestBudget -= 1
}

func get(_ urlString: String) async throws -> (Int, Data, [AnyHashable: Any]) {
    try spend()
    var req = URLRequest(url: URL(string: urlString)!)
    req.httpMethod = "GET"
    req.setValue(ua, forHTTPHeaderField: "User-Agent")
    req.setValue(base, forHTTPHeaderField: "Referer")
    let (data, resp) = try await session.data(for: req)
    let http = resp as! HTTPURLResponse
    return (http.statusCode, data, http.allHeaderFields)
}

func postSearch(path: String, title: String) async throws -> (Int, Data, String?) {
    try spend()
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("*/*", forHTTPHeaderField: "Accept")
    req.setValue(ua, forHTTPHeaderField: "User-Agent")
    req.setValue(base, forHTTPHeaderField: "Referer")
    req.setValue("https://howlongtobeat.com", forHTTPHeaderField: "Origin")
    let terms = title.split(separator: " ").map(String.init)
    let body: [String: Any] = [
        "searchType": "games", "searchTerms": terms, "searchPage": 1, "size": 20,
        "searchOptions": [
            "games": ["userId": 0, "platform": "", "sortCategory": "popular",
                      "rangeCategory": "main", "rangeTime": ["min": 0, "max": 0],
                      "gameplay": ["perspective": "", "flow": "", "genre": ""],
                      "rangeYear": ["min": "", "max": ""], "modifier": ""],
            "users": ["sortCategory": "postcount"], "lists": ["sortCategory": "follows"],
            "filter": "", "sort": 0, "randomizer": 0],
        "useCache": true,
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, resp) = try await session.data(for: req)
    let http = resp as! HTTPURLResponse
    return (http.statusCode, data, http.value(forHTTPHeaderField: "Content-Type"))
}

func pause() async throws { try await Task.sleep(nanoseconds: 2_200_000_000) }

// Discovery: homepage → app chunk → the quoted "/api/…" path + concatenated token.
func discover() async throws -> String {
    let (status, data, _) = try await get(base)
    guard status == 200 else { throw StopError(why: "homepage returned HTTP \(status)") }
    let html = String(decoding: data, as: UTF8.self)
    let scriptPaths = matches(#"src="(/_next/static/chunks/[^"]+?\.js)""#, in: html)
        .sorted { ($0.contains("_app") ? 0 : 1) < ($1.contains("_app") ? 0 : 1) }
    for path in scriptPaths.prefix(4) {
        try await pause()
        let (s, d, _) = try await get(base + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard s == 200 else { continue }
        let js = String(decoding: d, as: UTF8.self)
        if let m = firstGroup(#"["'`](/api/[A-Za-z0-9_/]*)["'`]"#, in: js) {
            var p = m; p.removeFirst("/api/".count)
            // Grab url-safe literals after the closing quote up to the options object.
            let after = js[js.range(of: m)!.upperBound...]
            let end = after.firstIndex(of: "{") ?? after.endIndex
            let token = matches(#"["'`]([A-Za-z0-9_-]*)["'`]"#, in: String(after[..<end])).joined()
            return "api/" + p + token
        }
    }
    return "api/s/"   // historical fallback
}

func firstGroup(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let r = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > 1,
          let g = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[g])
}
func matches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let r = NSRange(s.startIndex..., in: s)
    return re.matches(in: s, range: r).compactMap { m in
        m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } : nil
    }
}

func slug(_ t: String) -> String {
    t.lowercased().replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
}

// MAIN
do {
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    print("Discovering the HLTB search endpoint…")
    let path = try await discover()
    print("  endpoint: /\(path)")

    // A handful of well-known titles + a miss.
    let titles = ["Bloodborne", "Celeste", "Final Fantasy VII", "A Totally Fake Game 99999"]
    for title in titles {
        try await pause()
        print("Searching “\(title)”…")
        let (status, data, contentType) = try await postSearch(path: path, title: title)
        guard status == 200 else { throw StopError(why: "search returned HTTP \(status) — STOP") }
        guard (contentType ?? "").lowercased().contains("json") else {
            throw StopError(why: "search content-type was \(contentType ?? "nil"), not JSON — STOP")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["data"] != nil else {
            throw StopError(why: "search body was not the { data: […] } envelope — STOP")
        }
        let out = fixturesDir.appendingPathComponent("hltb-search-\(slug(title)).json")
        try data.write(to: out)
        let count = (obj["data"] as? [Any])?.count ?? 0
        print("  ✓ \(count) results → \(out.lastPathComponent)")
    }
    print("Done. Requests used: \(12 - requestBudget)/12.")
} catch let e as StopError {
    FileHandle.standardError.write(Data("STOPPED: \(e.why)\nMade no further requests.\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}

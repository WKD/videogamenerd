#!/usr/bin/env swift
//
// record-igdb-fixtures.swift — record trimmed IGDB response BODIES as test fixtures.
//
//   swift scripts/record-igdb-fixtures.swift
//
// Reads credentials from ~/.config/vgn/igdb.env (IGDB_CLIENT_ID / IGDB_CLIENT_SECRET),
// fetches a Twitch app token, runs the queries the tests need, and writes
// pretty-printed JSON into VGNTests/Fixtures/ with unique `igdb-…` names (the test
// bundle is flattened, so names must be unique).
//
// Fixtures contain response BODIES ONLY — never the token, never Authorization /
// Client-ID headers. It also prints a short search-strategy / bundle-relation report
// to stdout (NOT written to any fixture). Be polite: ≤ 4 req/s (throttled below).

import Foundation

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptURL.deletingLastPathComponent()
let fixturesDir = repoRoot.appendingPathComponent("VGNTests/Fixtures")

// MARK: - Credentials

func loadEnv() -> (id: String, secret: String) {
    let path = (("~/.config/vgn/igdb.env") as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    var dict: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        dict[key] = value
    }
    guard let id = dict["IGDB_CLIENT_ID"], let secret = dict["IGDB_CLIENT_SECRET"] else {
        FileHandle.standardError.write(Data("missing IGDB_CLIENT_ID / IGDB_CLIENT_SECRET\n".utf8)); exit(1)
    }
    return (id, secret)
}

// MARK: - Synchronous HTTP (bridges async URLSession)

func syncData(_ request: URLRequest) -> (Data, HTTPURLResponse)? {
    let semaphore = DispatchSemaphore(value: 0)
    var out: (Data, HTTPURLResponse)?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data, let http = response as? HTTPURLResponse { out = (data, http) }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return out
}

var lastCall = Date.distantPast
func throttle() {
    let since = Date().timeIntervalSince(lastCall)
    if since < 0.3 { Thread.sleep(forTimeInterval: 0.3 - since) }  // ~3 req/s, polite
    lastCall = Date()
}

// MARK: - Token

let creds = loadEnv()

func fetchToken() -> String {
    var comps = URLComponents(string: "https://id.twitch.tv/oauth2/token")!
    comps.queryItems = [
        .init(name: "client_id", value: creds.id),
        .init(name: "client_secret", value: creds.secret),
        .init(name: "grant_type", value: "client_credentials"),
    ]
    var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = comps.percentEncodedQuery.map { Data($0.utf8) }
    guard let (data, http) = syncData(req), http.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = obj["access_token"] as? String else {
        FileHandle.standardError.write(Data("token fetch failed\n".utf8)); exit(1)
    }
    return token
}

let token = fetchToken()
print("· got app token (\(token.count) chars, not logged)")

// MARK: - IGDB request

func igdb(_ endpoint: String, _ body: String) -> Data {
    throttle()
    var req = URLRequest(url: URL(string: "https://api.igdb.com/v4/\(endpoint)")!)
    req.httpMethod = "POST"
    req.setValue(creds.id, forHTTPHeaderField: "Client-ID")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(body.utf8)
    guard let (data, http) = syncData(req) else {
        FileHandle.standardError.write(Data("no response for \(endpoint)\n".utf8)); return Data("[]".utf8)
    }
    if http.statusCode != 200 {
        FileHandle.standardError.write(Data("HTTP \(http.statusCode) for \(endpoint): \(String(decoding: data.prefix(300), as: UTF8.self))\n".utf8))
    }
    return data
}

func prettyWrite(_ data: Data, to name: String) {
    let url = fixturesDir.appendingPathComponent(name)
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
        FileHandle.standardError.write(Data("could not pretty-print \(name)\n".utf8)); return
    }
    try? pretty.write(to: url)
    let count = (obj as? [Any])?.count ?? 0
    print("· wrote \(name) (\(count) items, \(pretty.count) bytes)")
}

func jsonArray(_ data: Data) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
}

let searchFields = "name,first_release_date,platforms.abbreviation,cover.image_id,genres.name,game_type,alternative_names.name,slug,parent_game,version_parent"
let fullFields = "name,slug,summary,first_release_date,platforms.abbreviation,cover.image_id,genres.name,game_type,alternative_names.name,bundles,parent_game,version_parent"

// MARK: - 0. game_types reference

let gameTypes = igdb("game_types", "fields id,type; limit 50;")
prettyWrite(gameTypes, to: "igdb-game-types.json")
print("  game_type values:")
for t in jsonArray(gameTypes).sorted(by: { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }) {
    print("    \(t["id"] ?? "?") = \(t["type"] ?? "?")")
}

// MARK: - 1. Search-strategy exploration (report only, not written)

print("\n=== search strategy: `search \"x\"` vs `where name ~ *\"x\"*` ===")
for prefix in ["bloodb", "zelda", "chevaliers de baphomet", "ico", "metal gear solid legacy"] {
    let esc = prefix.replacingOccurrences(of: "\"", with: "\\\"")
    let bySearch = jsonArray(igdb("games", "search \"\(esc)\"; fields name; limit 6;"))
    let byWhere = jsonArray(igdb("games", "where name ~ *\"\(esc)\"*; fields name; limit 6;"))
    print("· \"\(prefix)\"")
    print("    search: \(bySearch.compactMap { $0["name"] as? String })")
    print("    where~: \(byWhere.compactMap { $0["name"] as? String })")
}

// MARK: - 2. Recorded search fixtures

prettyWrite(igdb("games", "search \"bloodborne\"; fields \(searchFields); limit 8;"),
            to: "igdb-search-bloodborne.json")
// The French alt-name case: search by the English title (IGDB's `name`), whose
// `alternative_names` include "Les Chevaliers de Baphomet".
prettyWrite(igdb("games", "search \"broken sword shadow of the templars\"; fields \(searchFields); limit 8;"),
            to: "igdb-search-broken-sword.json")
prettyWrite(igdb("games", "search \"metal gear solid legacy\"; fields \(searchFields); limit 8;"),
            to: "igdb-search-mgs-legacy.json")

// Find Bloodborne's id for the games()/ttb fixtures.
let bloodborne = jsonArray(igdb("games", "search \"bloodborne\"; fields id,name; limit 5;"))
let bloodborneID = bloodborne.first(where: { ($0["name"] as? String) == "Bloodborne" })?["id"] as? Int
    ?? bloodborne.first?["id"] as? Int ?? 0
print("\nBloodborne id = \(bloodborneID)")

// MARK: - 3. games(ids:) full metadata

prettyWrite(igdb("games", "where id = (\(bloodborneID)); fields \(fullFields); limit 1;"),
            to: "igdb-games-bloodborne.json")

// MARK: - 4. Bundles

print("\n=== bundle relation probe ===")
var collectedMemberIDs: [Int] = []
func recordBundle(searchText: String, outName: String) {
    let hits = jsonArray(igdb("games", "search \"\(searchText)\"; fields id,name,game_type,bundles; limit 10;"))
    // Prefer a hit that is a bundle type (3) or actually has a bundles array.
    let bundle = hits.first(where: { ($0["game_type"] as? Int) == 3 })
        ?? hits.first(where: { ($0["bundles"] as? [Int])?.isEmpty == false })
        ?? hits.first
    guard let bundle, let id = bundle["id"] as? Int else { print("· no bundle for \(searchText)"); return }
    let memberIDs = bundle["bundles"] as? [Int] ?? []
    print("· \(bundle["name"] ?? "?") id=\(id) game_type=\(bundle["game_type"] ?? "?") bundles=\(memberIDs.count) members")

    if !memberIDs.isEmpty {
        let set = "(" + memberIDs.map(String.init).joined(separator: ",") + ")"
        let data = igdb("games", "where id = \(set); fields \(searchFields); limit \(memberIDs.count);")
        prettyWrite(data, to: outName)
        collectedMemberIDs += jsonArray(data).compactMap { $0["id"] as? Int }
        print("    → recorded via `bundles` relation")
    } else {
        let data = igdb("games", "where bundles = (\(id)); fields \(searchFields); limit 20;")
        let members = jsonArray(data)
        print("    `bundles` empty; reverse `where bundles = (\(id))` → \(members.count) games")
        prettyWrite(data, to: outName)
        collectedMemberIDs += members.compactMap { $0["id"] as? Int }
    }
}
recordBundle(searchText: "Metal Gear Solid Legacy Collection", outName: "igdb-bundle-members-mgs.json")
recordBundle(searchText: "ICO Shadow of the Colossus Collection", outName: "igdb-bundle-members-ico.json")

// MARK: - 5. time-to-beat

// Bloodborne + the bundle members we just discovered → several real rows.
let ttbIDs = Set([bloodborneID] + collectedMemberIDs)
let ttbSet = "(" + ttbIDs.map(String.init).joined(separator: ",") + ")"
prettyWrite(igdb("game_time_to_beats", "where game_id = \(ttbSet); fields game_id,hastily,normally,completely,count; limit 30;"),
            to: "igdb-ttb.json")

print("\nDone. Fixtures in \(fixturesDir.path)")

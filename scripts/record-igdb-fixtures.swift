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
// §7b traits + rating fields appended to the enrichment field list.
let traitFields = "franchise.name,franchises.name,collection.name,collections.name,involved_companies.company.name,involved_companies.developer,themes.name,game_modes.name,player_perspectives.name,keywords.name,similar_games,total_rating,total_rating_count,aggregated_rating,aggregated_rating_count,rating,rating_count"
let fullFields = "name,slug,summary,first_release_date,platforms.abbreviation,cover.image_id,genres.name,game_type,alternative_names.name,bundles,parent_game,version_parent," + traitFields

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

// MARK: - 6. §7b Play Next corpus — ~12 well-known games spanning tastes.

// This fixture doubles as the recommendation engine's realistic test corpus. We
// search each title, pick the best main-game match, then fetch full metadata
// (incl. the §7b trait/rating fields) + time-to-beat for all of them.
print("\n=== §7b Play Next corpus ===")
let corpusTitles = [
    "Bloodborne", "Dark Souls", "Elden Ring", "The Last of Us",
    "Uncharted 4 A Thief's End", "Persona 5", "Final Fantasy X", "Hollow Knight",
    "Super Mario Odyssey", "Heavy Rain", "Yakuza 0", "Resident Evil 2",
]
var corpusIDs: [Int] = []
for title in corpusTitles {
    let esc = title.replacingOccurrences(of: "\"", with: "\\\"")
    let hits = jsonArray(igdb("games",
        "search \"\(esc)\"; fields id,name,game_type,version_parent,total_rating_count; limit 12;"))
    // The canonical game is the most-rated main/remake/remaster that is not an
    // edition (version_parent set) — total_rating_count is the crowd-size proxy.
    let eligible = hits.filter {
        ($0["version_parent"] == nil) && [0, 8, 9].contains($0["game_type"] as? Int ?? -1)
            && ($0["total_rating_count"] as? Int ?? 0) > 0
    }
    let pick = eligible.max(by: {
        ($0["total_rating_count"] as? Int ?? 0) < ($1["total_rating_count"] as? Int ?? 0)
    }) ?? hits.first
    if let id = pick?["id"] as? Int {
        corpusIDs.append(id)
        print("· \(title) → \(pick?["name"] ?? "?") (id \(id), ratings \(pick?["total_rating_count"] ?? 0))")
    } else {
        print("· \(title) → NO MATCH")
    }
}
let corpusSet = "(" + corpusIDs.map(String.init).joined(separator: ",") + ")"
let corpusData = igdb("games", "where id = \(corpusSet); fields \(fullFields); limit \(corpusIDs.count);")
prettyWrite(corpusData, to: "igdb-games-corpus.json")
prettyWrite(igdb("game_time_to_beats",
                 "where game_id = \(corpusSet); fields game_id,hastily,normally,completely,count; limit 30;"),
            to: "igdb-ttb-corpus.json")

// Which rating / trait fields are actually populated? (report only)
print("\n=== trait / rating population report ===")
for obj in jsonArray(corpusData) {
    let name = obj["name"] as? String ?? "?"
    let franchises = (obj["franchises"] as? [Int])?.count ?? 0
    let hasFranchise = obj["franchise"] != nil
    let collections = (obj["collections"] as? [Int])?.count ?? ((obj["collection"] != nil) ? 1 : 0)
    let ic = (obj["involved_companies"] as? [[String: Any]])?.count ?? 0
    let themes = (obj["themes"] as? [Int])?.count ?? 0
    let modes = (obj["game_modes"] as? [Int])?.count ?? 0
    let persp = (obj["player_perspectives"] as? [Int])?.count ?? 0
    let keywords = (obj["keywords"] as? [Int])?.count ?? 0
    let similar = (obj["similar_games"] as? [Int])?.count ?? 0
    let total = obj["total_rating"] as? Double
    let totalCount = obj["total_rating_count"] as? Int
    let agg = obj["aggregated_rating"] as? Double
    let rating = obj["rating"] as? Double
    print("· \(name): franchise=\(hasFranchise) franchises=\(franchises) coll=\(collections) companies=\(ic) themes=\(themes) modes=\(modes) persp=\(persp) kw=\(keywords) similar=\(similar) total=\(total.map { String(format: "%.1f", $0) } ?? "-")(\(totalCount ?? -1)) agg=\(agg.map { String(format: "%.1f", $0) } ?? "-") rating=\(rating.map { String(format: "%.1f", $0) } ?? "-")")
}

print("\nDone. Fixtures in \(fixturesDir.path)")

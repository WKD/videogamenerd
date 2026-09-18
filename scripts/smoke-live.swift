#!/usr/bin/env swift
//
// smoke-live.swift — one-shot live smoke test of the whole services chain.
//
//   swift scripts/smoke-live.swift
//
// Proves search → games → time-to-beat → bundle members → libretro listing → one
// cover download work against the REAL services. Not a unit test; writes nothing to
// the repo (a cover downloads to a temp dir). Prints counts + timings. Never logs the
// token or credentials.

import Foundation

func loadEnv() -> (String, String) {
    let path = (("~/.config/vgn/igdb.env") as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("no env"); exit(1) }
    var d: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        d[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
            String(line[line.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
    return (d["IGDB_CLIENT_ID"] ?? "", d["IGDB_CLIENT_SECRET"] ?? "")
}

func sync(_ req: URLRequest) -> (Data, HTTPURLResponse)? {
    let sem = DispatchSemaphore(value: 0); var out: (Data, HTTPURLResponse)?
    URLSession.shared.dataTask(with: req) { d, r, _ in if let d, let h = r as? HTTPURLResponse { out = (d, h) }; sem.signal() }.resume()
    sem.wait(); return out
}

func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

let (cid, secret) = loadEnv()

// Token
var t = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
t.httpMethod = "POST"
t.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
var comps = URLComponents()
comps.queryItems = [.init(name: "client_id", value: cid), .init(name: "client_secret", value: secret), .init(name: "grant_type", value: "client_credentials")]
t.httpBody = comps.percentEncodedQuery.map { Data($0.utf8) }
var start = Date()
guard let (td, _) = sync(t), let tok = (try? JSONSerialization.jsonObject(with: td) as? [String: Any])?["access_token"] as? String else { print("token failed"); exit(1) }
print("token: ok (\(ms(start)))")

func igdb(_ ep: String, _ body: String) -> [[String: Any]] {
    var r = URLRequest(url: URL(string: "https://api.igdb.com/v4/\(ep)")!)
    r.httpMethod = "POST"
    r.setValue(cid, forHTTPHeaderField: "Client-ID")
    r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
    r.httpBody = Data(body.utf8)
    Thread.sleep(forTimeInterval: 0.28)   // ≤ 4 req/s
    guard let (d, h) = sync(r) else { return [] }
    if h.statusCode != 200 { print("  HTTP \(h.statusCode): \(String(decoding: d.prefix(200), as: UTF8.self))") }
    return (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
}

let sf = "name,first_release_date,platforms.abbreviation,cover.image_id,genres.name,game_type,alternative_names.name"

start = Date()
let search = igdb("games", "search \"bloodborne\"; fields \(sf); limit 12;")
print("search 'bloodborne': \(search.count) results (\(ms(start))) → \(search.prefix(3).compactMap { $0["name"] as? String })")

let bbID = search.first(where: { ($0["name"] as? String) == "Bloodborne" })?["id"] as? Int ?? 7334
start = Date()
let full = igdb("games", "where id = (\(bbID)); fields \(sf),summary; limit 1;")
print("games(\(bbID)): \(full.count) (\(ms(start))) summary=\((full.first?["summary"] as? String)?.prefix(40) ?? "—")…")

start = Date()
let ttb = igdb("game_time_to_beats", "where game_id = (\(bbID)); fields game_id,hastily,normally,completely,count;")
print("time-to-beat(\(bbID)): \(ttb.count) rows (\(ms(start))) → \(ttb.first ?? [:])")

start = Date()
let members = igdb("games", "where bundles = (20196); fields name; limit 20;")
print("MGS Legacy bundle members (reverse): \(members.count) (\(ms(start))) → \(members.compactMap { $0["name"] as? String })")

// libretro listing
start = Date()
var gh = URLRequest(url: URL(string: "https://api.github.com/repos/libretro-thumbnails/Sega_-_Dreamcast/git/trees/master?recursive=1")!)
gh.setValue("VGN-smoke", forHTTPHeaderField: "User-Agent")
gh.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
if let (gd, gh2) = sync(gh), let obj = try? JSONSerialization.jsonObject(with: gd) as? [String: Any] {
    let tree = obj["tree"] as? [[String: Any]] ?? []
    let boxarts = tree.filter { ($0["type"] as? String) == "blob" && (($0["path"] as? String) ?? "").hasPrefix("Named_Boxarts/") }
    print("libretro Sega_-_Dreamcast tree: HTTP \(gh2.statusCode), \(boxarts.count) boxarts, truncated=\(obj["truncated"] ?? "?") (\(ms(start)))")

    // Download one libretro cover to a temp dir.
    if let sonic = boxarts.first(where: { (($0["path"] as? String) ?? "").contains("Sonic Adventure (USA).png") }),
       let path = sonic["path"] as? String {
        let enc = path.replacingOccurrences(of: "Named_Boxarts/", with: "")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let url = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/Sega_-_Dreamcast/master/Named_Boxarts/\(enc)")!
        start = Date()
        var dl = URLRequest(url: url); dl.setValue("VGN-smoke", forHTTPHeaderField: "User-Agent")
        if let (id, ih) = sync(dl) {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-smoke-sonic.png")
            try? id.write(to: out)
            print("cover download: HTTP \(ih.statusCode), \(id.count) bytes → \(out.path) (\(ms(start)))")
        }
    }
}

// Download one IGDB cover.
if let imageID = (search.first(where: { ($0["name"] as? String) == "Bloodborne" })?["cover"] as? [String: Any])?["image_id"] as? String {
    let url = URL(string: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/\(imageID).jpg")!
    start = Date()
    if let (id, ih) = sync(URLRequest(url: url)) {
        print("IGDB cover download: HTTP \(ih.statusCode), \(id.count) bytes (\(ms(start)))")
    }
}

print("\nsmoke: done")

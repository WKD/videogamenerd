#!/usr/bin/env swift
//
// record-libretro-fixture.swift — record a trimmed GitHub git-tree fixture for one
// small libretro-thumbnails repo, for the LibretroCoverProvider tests.
//
//   swift scripts/record-libretro-fixture.swift
//
// Fetches the real git-tree for a chosen repo, keeps a curated handful of famous
// Named_Boxarts entries (+ a couple of Named_Snaps blobs and the folder tree entries,
// so the parser's filtering is exercised), and writes a valid, compact git-tree JSON.
// No credentials involved; GitHub's public API only. Output is a response BODY.

import Foundation

let repo = "Sega_-_Dreamcast"
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let fixturesDir = scriptURL.deletingLastPathComponent().appendingPathComponent("VGNTests/Fixtures")

func syncData(_ request: URLRequest) -> (Data, HTTPURLResponse)? {
    let sem = DispatchSemaphore(value: 0)
    var out: (Data, HTTPURLResponse)?
    URLSession.shared.dataTask(with: request) { data, resp, _ in
        if let data, let http = resp as? HTTPURLResponse { out = (data, http) }
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

var req = URLRequest(url: URL(string: "https://api.github.com/repos/libretro-thumbnails/\(repo)/git/trees/master?recursive=1")!)
req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
req.setValue("VGN-fixture-recorder", forHTTPHeaderField: "User-Agent")

guard let (data, http) = syncData(req), http.statusCode == 200,
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tree = obj["tree"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("git-tree fetch failed (status \(String(describing: (try? JSONSerialization.jsonObject(with: (syncData(req)?.0 ?? Data())))))) \n".utf8))
    exit(1)
}
print("· fetched \(tree.count) tree entries for \(repo), truncated=\(obj["truncated"] ?? "?")")

func path(_ e: [String: Any]) -> String { (e["path"] as? String) ?? "" }
func type(_ e: [String: Any]) -> String { (e["type"] as? String) ?? "" }

// Curated famous franchises so the matching test has known titles.
let wanted = ["Sonic Adventure", "Shenmue", "Crazy Taxi", "Jet Grind Radio", "Jet Set Radio",
              "Soul Calibur", "Skies of Arcadia", "Resident Evil", "Power Stone", "Rez"]

let boxarts = tree.filter { type($0) == "blob" && path($0).hasPrefix("Named_Boxarts/") && path($0).lowercased().hasSuffix(".png") }
let curatedBoxarts = boxarts.filter { e in wanted.contains { path(e).contains($0) } }
let snaps = tree.filter { type($0) == "blob" && path($0).hasPrefix("Named_Snaps/") }.prefix(2)
let folderTrees = tree.filter { type($0) == "tree" }

// Rebuild a compact tree: the folder tree entries + curated boxarts + a couple of
// snaps (to prove the parser ignores non-boxart blobs).
var trimmed: [[String: Any]] = []
for e in folderTrees {
    trimmed.append(["path": path(e), "type": "tree", "sha": e["sha"] ?? "", "mode": e["mode"] ?? "040000"])
}
for e in curatedBoxarts.sorted(by: { path($0) < path($1) }) {
    trimmed.append(["path": path(e), "type": "blob", "sha": e["sha"] ?? "", "mode": "100644"])
}
for e in snaps {
    trimmed.append(["path": path(e), "type": "blob", "sha": e["sha"] ?? "", "mode": "100644"])
}

let out: [String: Any] = ["sha": obj["sha"] ?? "", "truncated": false, "tree": trimmed]
let pretty = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
let url = fixturesDir.appendingPathComponent("libretro-tree-dreamcast.json")
try! pretty.write(to: url)

print("· curated \(curatedBoxarts.count) boxarts:")
for e in curatedBoxarts.sorted(by: { path($0) < path($1) }) {
    print("    \(path(e).replacingOccurrences(of: "Named_Boxarts/", with: ""))")
}
print("· wrote \(url.lastPathComponent) (\(pretty.count) bytes)")

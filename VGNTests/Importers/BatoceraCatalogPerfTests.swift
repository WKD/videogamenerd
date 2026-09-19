import Foundation
import Testing
@testable import VGN

/// Performance smoke on synthetic data (PLAN §15 — "a full first read of ~11 000 entries in
/// a few seconds"). Asserts **correctness** and **prints** timings — never a wall-clock
/// assertion (flakes under parallel load, per the testing conventions).
struct BatoceraCatalogPerfTests {

    @Test(.timeLimit(.minutes(2)))
    func readFoldUpsertElevenThousandEntries() async throws {
        let n = 11_000
        var specs: [BatoceraTestSupport.GameSpec] = []
        specs.reserveCapacity(n)
        for i in 0..<n {
            // A handful get play data; a few are near-duplicates to exercise folding.
            let played = i % 137 == 0
            specs.append(.init(
                path: "./Game \(i) (USA).zip",
                name: "Synthetic Game \(i)",
                genre: i % 2 == 0 ? "Platform" : "Shoot'em Up / Vertical",
                family: i % 5 == 0 ? "Series \(i % 50)" : nil,
                developer: "Dev \(i % 100)",
                region: "us",
                releasedate: "199\(i % 10)0101T000000",
                gametime: played ? "3600" : nil))
        }

        let data = BatoceraTestSupport.data(specs)

        let readStart = Date()
        let games = try BatoceraGamelistReader().read(system: "snes", data: data)
        let readMS = Date().timeIntervalSince(readStart) * 1000
        #expect(games.count == n)

        let foldStart = Date()
        let folded = BatoceraFolding.fold(games)
        let foldMS = Date().timeIntervalSince(foldStart) * 1000
        #expect(folded.groups.count == n)      // all distinct here

        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let entries = folded.groups.map {
            RomCatalogEntry.make(from: $0.representative, platformID: "snes", libretroKey: $0.libretroKey)
        }
        let upsertStart = Date()
        let counts = try await store.syncSystem(system: "snes", entries: entries)
        let upsertMS = Date().timeIntervalSince(upsertStart) * 1000
        #expect(counts.added == n)

        let searchStart = Date()
        let hits = try await store.search("Synthetic", limit: 50)
        let searchMS = Date().timeIntervalSince(searchStart) * 1000
        #expect(!hits.isEmpty)

        print(String(format: "[BatoceraCatalogPerf] read %.0f ms · fold %.0f ms · upsert %.0f ms · search %.1f ms (n=\(n))",
                     readMS, foldMS, upsertMS, searchMS))
    }
}

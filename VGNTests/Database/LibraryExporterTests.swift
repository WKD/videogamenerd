import Foundation
import Testing
import GRDB
@testable import VGN

/// Library export (PLAN §9 Safety): a complete, re-importable JSON document and a
/// flat CSV.
@Suite struct LibraryExporterTests {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func jsonCapturesTheWholeGraphAndRoundTrips() async throws {
        let store = try await TestDB.makeStore()
        let rank = RankingStore(store.database)

        // A ranked, owned, played game with playtime + a genre + a trait.
        let a = try await store.addGame(GameDraft(
            title: "Alpha, Game", igdbID: 111, year: 2001,
            platformIDs: ["ps2"], owned: true, played: true, tierID: 1)).gameID
        try await store.setMyPlaytime(gameID: a, seconds: 3600 * 10)
        try await store.updateMetadata(gameID: a, MetadataPatch(
            genres: ["Action"], traits: [GameTrait(kind: .developer, value: "Studio A")]))
        try await rank.move(gameID: a, toTier: 1, atIndex: 0)   // place it (gets a rank_key)

        // A compilation of two members on PS3.
        let (productID, _) = try await store.addCompilation(
            product: ProductDraft(title: "Twin Pack", platformID: "ps3", format: .physical, source: .manual),
            members: [
                CompilationMemberDraft(title: "First", played: true, position: 0),
                CompilationMemberDraft(title: "Second", played: false, position: 1),
            ])

        let exporter = LibraryExporter(store.database)
        let data = try await exporter.exportJSON()
        let doc = try decoder().decode(LibraryExporter.Document.self, from: data)

        #expect(doc.format == LibraryExporter.formatIdentifier)
        #expect(doc.version == LibraryExporter.formatVersion)
        #expect(doc.tiers.count == 6)                       // seeded S…F
        #expect(doc.games.count == 3)                       // Alpha + 2 members

        let alpha = try #require(doc.games.first { $0.id == a })
        #expect(alpha.title == "Alpha, Game")
        #expect(alpha.igdbID == 111)
        #expect(alpha.tierID == 1)
        #expect(alpha.rankKey != nil)                       // placement recorded
        #expect(alpha.myPlaytimeS == 36000)
        #expect(alpha.genres == ["Action"])
        #expect(alpha.traits.contains { $0.kind == "developer" && $0.value == "Studio A" })
        #expect(alpha.platforms.contains { $0.platformID == "ps2" })

        // The compilation product carries its ordered members.
        let product = try #require(doc.products.first { $0.id == productID })
        #expect(product.kind == "compilation")
        #expect(product.members.count == 2)
        #expect(product.members.map(\.position) == [0, 1])
    }

    @Test func csvIsFlatQuotedAndCarriesDerivedScore() async throws {
        let store = try await TestDB.makeStore()
        let rank = RankingStore(store.database)
        let a = try await store.addGame(GameDraft(
            title: "Comma, Title", year: 1999, platformIDs: ["ps2"],
            owned: true, played: true, tierID: 1)).gameID
        try await rank.move(gameID: a, toTier: 1, atIndex: 0)
        _ = try await store.addGame(GameDraft(
            title: "Backlog Game", platformIDs: ["pc"], owned: true, played: false)).gameID

        let csv = try await LibraryExporter(store.database).exportCSV()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        #expect(lines.first == LibraryExporter.csvHeader.joined(separator: ","))
        #expect(lines.count == 3)                            // header + 2 games
        // The comma title is RFC-4180 quoted.
        #expect(csv.contains("\"Comma, Title\""))
        // The ranked game has an S-tier score in the 9.0–10.0 band and rank #1.
        let ranked = try #require(lines.first { $0.contains("Comma") })
        let cols = LibraryExporterTests.parseCSVLine(ranked)
        #expect(cols[5] == "")                               // status (played, no completion status)
        #expect(cols[6] == "no")                             // revisit (v15 column)
        #expect(cols[7] == "S")                              // tier
        #expect(cols[8] == "1")                              // overall_rank
        #expect((Double(cols[9]) ?? 0) >= 9.0)               // score in the S band
        // The backlog game is owned but not played, no tier.
        let backlog = try #require(lines.first { $0.contains("Backlog") })
        let bcols = LibraryExporterTests.parseCSVLine(backlog)
        #expect(bcols[3] == "yes")                           // owned
        #expect(bcols[4] == "no")                            // played
        #expect(bcols[6] == "no")                            // revisit
        #expect(bcols[7] == "")                              // no tier
    }

    /// Minimal RFC-4180 line splitter for the assertions above.
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { current.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { current.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}

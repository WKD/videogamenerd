import Foundation
import Testing
@testable import VGN

/// End-to-end pipeline with a stub recogniser + stub searcher: tiling a real fixture,
/// merging, platform-constrained matching, and the isInLibrary closure.
struct ScanPipelineTests {

    private func catalog() -> PlatformCatalog {
        PlatformCatalog(entries: [
            PlatformCatalogEntry(id: "ps4", name: "PlayStation 4", short: "PS4", manufacturer: "Sony", group: "Sony", kind: "console", generation: 8, igdbIDs: [48], libretroRepo: nil, sort: 2),
            PlatformCatalogEntry(id: "ps5", name: "PlayStation 5", short: "PS5", manufacturer: "Sony", group: "Sony", kind: "console", generation: 9, igdbIDs: [167], libretroRepo: nil, sort: 1),
            PlatformCatalogEntry(id: "ps3", name: "PlayStation 3", short: "PS3", manufacturer: "Sony", group: "Sony", kind: "console", generation: 7, igdbIDs: [9], libretroRepo: nil, sort: 3),
        ])
    }

    @Test("Tiles a fixture, merges, matches per platform, and flags library duplicates")
    func endToEnd() async throws {
        let detections = [
            RecognitionFixtures.anchored(id: 0, title: "Bloodborne", platform: "ps4", confidence: 0.95, x: 100),
            RecognitionFixtures.anchored(id: 1, title: "Elden Ring", platform: "ps5", confidence: 0.9, x: 900),
        ]
        let recognizer = StubShelfRecognizer(detections: detections)
        let searcher = StubIGDBSearcher { text, _ in
            let lower = text.lowercased()
            if lower.contains("bloodborne") { return [RecognitionFixtures.igdb(id: 1, name: "Bloodborne", platformSlugs: ["ps4"])] }
            if lower.contains("elden") { return [RecognitionFixtures.igdb(id: 2, name: "Elden Ring", platformSlugs: ["ps5"])] }
            return []
        }
        let pipeline = ScanPipeline(recognizer: recognizer, searcher: searcher, catalog: catalog())

        let url = try Fixtures.url("tile6_front_cover.jpg")
        let result = try await pipeline.scan(
            photoAt: url,
            photoName: "IMG_TEST",
            isInLibrary: { igdbID, _ in igdbID == 1 }   // Bloodborne already owned
        )

        #expect(result.tileCount >= 1)
        #expect(result.items.count == 2)

        let byTitle = Dictionary(uniqueKeysWithValues: result.items.map { ($0.printedTitle, $0) })
        let bloodborne = try #require(byTitle["Bloodborne"])
        #expect(bloodborne.match?.igdbID == 1)
        #expect(bloodborne.matchBucket == .confident)
        #expect(bloodborne.alreadyInLibrary == true)
        #expect(bloodborne.owned == true)
        #expect(bloodborne.physical == true)
        #expect(bloodborne.platformSlug == "ps4")

        let elden = try #require(byTitle["Elden Ring"])
        #expect(elden.match?.igdbID == 2)
        #expect(elden.alreadyInLibrary == false)
    }

    @Test("Platform-constrained search falls back to unconstrained when it finds nothing")
    func platformFallback() async {
        let searcher = StubIGDBSearcher { text, constrained in
            // Only the unconstrained call returns a hit.
            if constrained != nil { return [] }
            if text.lowercased().contains("catherine") { return [RecognitionFixtures.igdb(id: 7, name: "Catherine", platformSlugs: ["ps3"])] }
            return []
        }
        let pipeline = ScanPipeline(recognizer: StubShelfRecognizer(detections: []), searcher: searcher, catalog: catalog())
        let detection = MergedDetection(
            id: 0, printedTitle: "Catherine", normalizedTitle: nil, platform: "ps3",
            editionHints: [], isCompilation: false, confidence: 0.8,
            sourceRect: SourceRect(x: 0, y: 0, width: 100, height: 1200), tileID: 0,
            serialCode: nil, memberCount: 1
        )
        let items = await pipeline.matchDetections([detection], photo: "IMG")
        #expect(items.first?.match?.igdbID == 7)
        // Both a constrained and an unconstrained query were issued.
        #expect(searcher.queries.contains { $0.constrained })
        #expect(searcher.queries.contains { !$0.constrained })
    }

    @Test("A merged detection with no match yields an item bucketed none")
    func unmatchedItem() async {
        let searcher = StubIGDBSearcher { _, _ in [] }
        let pipeline = ScanPipeline(recognizer: StubShelfRecognizer(detections: []), searcher: searcher, catalog: catalog())
        let detection = MergedDetection(
            id: 0, printedTitle: "A Totally Unreadable Steelbook", normalizedTitle: nil, platform: "ps5",
            editionHints: [], isCompilation: false, confidence: 0.3,
            sourceRect: SourceRect(x: 0, y: 0, width: 100, height: 1200), tileID: 0,
            serialCode: nil, memberCount: 1
        )
        let items = await pipeline.matchDetections([detection], photo: "IMG")
        #expect(items.count == 1)
        #expect(items[0].match == nil)
        #expect(items[0].matchBucket == .none)
    }
}

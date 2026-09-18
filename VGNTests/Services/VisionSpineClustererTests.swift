import Foundation
import Testing
@testable import VGN

/// Clustering of OCR lines into spines, on a recorded real Vision fixture and on
/// synthetic lines; plus the Vision recognizer's line de-duplication and a lenient
/// end-to-end pass on a committed tile.
struct VisionSpineClustererTests {

    @Test("Clusters a recorded front-cover OCR fixture into a title spine")
    func recordedFixture() throws {
        let data = try Fixtures.data("recognition-vision-frontcover.json")
        let lines = try JSONDecoder().decode([VisionTextLine].self, from: data)
        let clusters = VisionSpineClusterer.cluster(lines, xTolerance: 95)
        // The stacked CLAIR / OBSCUR column merges into one spine (both words).
        let title = try #require(clusters.first(where: { $0.text.uppercased().contains("CLAIR") }))
        #expect(title.text.uppercased().contains("OBSCUR"))
        // The cover's title text is all present across the recognised spines.
        let all = clusters.map { $0.text.uppercased() }.joined(separator: " ")
        #expect(all.contains("EXPEDITIO"))
        // Deterministic.
        let again = VisionSpineClusterer.cluster(lines, xTolerance: 95)
        #expect(clusters.map(\.text) == again.map(\.text))
    }

    @Test("Same-column lines merge and order top→bottom; distant columns stay apart")
    func columnClustering() {
        let lines = [
            VisionTextLine(text: "ZODIAC", rect: SourceRect(x: 100, y: 300, width: 60, height: 40), confidence: 0.9),
            VisionTextLine(text: "FINAL", rect: SourceRect(x: 102, y: 100, width: 60, height: 40), confidence: 0.9),
            VisionTextLine(text: "FANTASY", rect: SourceRect(x: 98, y: 200, width: 60, height: 40), confidence: 0.9),
            VisionTextLine(text: "SEKIRO", rect: SourceRect(x: 600, y: 150, width: 60, height: 40), confidence: 0.8),
        ]
        let clusters = VisionSpineClusterer.cluster(lines, xTolerance: 40)
        #expect(clusters.count == 2)
        #expect(clusters[0].text == "FINAL FANTASY ZODIAC")   // top→bottom
        #expect(clusters[1].text == "SEKIRO")
    }

    @Test("A serial code in the clustered text is attached to the spine")
    func serialAttached() {
        let lines = [
            VisionTextLine(text: "SILENT HILL 2", rect: SourceRect(x: 200, y: 100, width: 80, height: 40), confidence: 0.9),
            VisionTextLine(text: "PPSA 04609", rect: SourceRect(x: 205, y: 800, width: 80, height: 20), confidence: 0.7),
        ]
        let clusters = VisionSpineClusterer.cluster(lines, xTolerance: 40)
        #expect(clusters.count == 1)
        #expect(clusters[0].serial?.platformSlug == "ps5")
        #expect(clusters[0].serial?.prefix == "PPSA")
    }

    @Test("De-duplicates the same line read at multiple orientations")
    @available(macOS 15.0, *)
    func deduplicate() {
        let lines = [
            VisionTextLine(text: "BLOODBORNE", rect: SourceRect(x: 100, y: 100, width: 90, height: 30), confidence: 0.95),
            VisionTextLine(text: "bloodborne", rect: SourceRect(x: 104, y: 98, width: 90, height: 30), confidence: 0.6),
            VisionTextLine(text: "SEKIRO", rect: SourceRect(x: 400, y: 100, width: 60, height: 30), confidence: 0.8),
        ]
        let deduped = VisionShelfRecognizer.deduplicate(lines)
        #expect(deduped.count == 2)
        #expect(deduped.contains { $0.text == "BLOODBORNE" })   // higher-confidence kept
    }

    @Test("Runs Apple Vision on a committed tile and reads the front cover")
    @available(macOS 15.0, *)
    func endToEndVision() async throws {
        let url = try Fixtures.url("tile6_front_cover.jpg")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vgn-vis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("t.jpg")
        try FileManager.default.copyItem(at: url, to: dest)

        let tile = ShelfTile(id: 0, fileURL: dest,
                             rect: SourceRect(x: 0, y: 0, width: 1560, height: 2000),
                             row: 0, sourceSize: ImagePixelSize(width: 1560, height: 2000))
        let detections = await VisionShelfRecognizer().recognize(tiles: [tile])
        #expect(!detections.isEmpty)
        let joined = detections.map { $0.printedTitle.uppercased() }.joined(separator: " | ")
        #expect(joined.contains("CLAIR") || joined.contains("OBSCUR") || joined.contains("EXPEDITIO"))
        // Vision confidence is honestly low (scaled down).
        #expect(detections.allSatisfy { $0.detection.confidence <= 1.0 })
    }
}

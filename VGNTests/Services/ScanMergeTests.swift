import Foundation
import Testing
@testable import VGN

/// Overlap merging on synthetic detections.
struct ScanMergeTests {

    @Test("Same spine seen in two overlapping tiles merges into one")
    func mergesDuplicate() {
        let a = RecognitionFixtures.anchored(id: 0, title: "Bloodborne", platform: "ps4", confidence: 0.8, x: 1000, tileID: 0)
        let b = RecognitionFixtures.anchored(id: 1, title: "BLOODBORNE", platform: "ps4", confidence: 0.95, x: 1030, tileID: 1)
        let merged = ScanMerge.merge([a, b])
        #expect(merged.count == 1)
        #expect(merged[0].memberCount == 2)
        #expect(merged[0].confidence == 0.95)   // highest-confidence representative
    }

    @Test("Two different copies side by side stay two")
    func keepsTwoCopies() {
        let a = RecognitionFixtures.anchored(id: 0, title: "God of War Collection", platform: "ps3", confidence: 0.9, x: 500)
        let b = RecognitionFixtures.anchored(id: 1, title: "God of War Collection", platform: "ps3", confidence: 0.9, x: 3000)
        let merged = ScanMerge.merge([a, b])
        #expect(merged.count == 2)
    }

    @Test("Different platforms at the same position do not merge")
    func platformSeparates() {
        let a = RecognitionFixtures.anchored(id: 0, title: "L.A. Noire", platform: "ps3", confidence: 0.9, x: 1000)
        let b = RecognitionFixtures.anchored(id: 1, title: "L.A. Noire", platform: "xbox360", confidence: 0.9, x: 1010)
        let merged = ScanMerge.merge([a, b])
        #expect(merged.count == 2)
    }

    @Test("An unknown platform merges with a known one at the same spine")
    func unknownPlatformCompatible() {
        let a = RecognitionFixtures.anchored(id: 0, title: "Sekiro", platform: nil, confidence: 0.7, x: 1000)
        let b = RecognitionFixtures.anchored(id: 1, title: "Sekiro", platform: "ps4", confidence: 0.9, x: 1010)
        let merged = ScanMerge.merge([a, b])
        #expect(merged.count == 1)
        #expect(merged[0].platform == "ps4")   // known platform preferred
    }

    @Test("Three overlapping reads of one spine collapse to a single item")
    func threeWayMerge() {
        let d = [
            RecognitionFixtures.anchored(id: 0, title: "Elden Ring", platform: "ps5", confidence: 0.7, x: 2000, tileID: 0),
            RecognitionFixtures.anchored(id: 1, title: "Elden Ring", platform: "ps5", confidence: 0.9, x: 2020, tileID: 1),
            RecognitionFixtures.anchored(id: 2, title: "ELDEN RING", platform: "ps5", confidence: 0.8, x: 2040, tileID: 2),
        ]
        let merged = ScanMerge.merge(d)
        #expect(merged.count == 1)
        #expect(merged[0].memberCount == 3)
    }

    @Test("fuseSerials attaches a positionally-overlapping serial and its platform")
    func fuseSerials() {
        let detection = MergedDetection(
            id: 0, printedTitle: "Silent Hill 2", normalizedTitle: nil, platform: nil,
            editionHints: [], isCompilation: false, confidence: 0.8,
            sourceRect: SourceRect(x: 1000, y: 0, width: 120, height: 1200), tileID: 0,
            serialCode: nil, memberCount: 1
        )
        let serialSource = AnchoredDetection(
            id: 5, detection: SpineDetection(printedTitle: "PPSA 04609", confidence: 0.5),
            tileID: 0, row: 0, sourceRect: SourceRect(x: 1040, y: 0, width: 60, height: 200),
            serialCode: SpineSerialCode.first(in: "PPSA 04609")
        )
        let fused = ScanMerge.fuseSerials(into: [detection], from: [serialSource])
        #expect(fused[0].serialCode?.prefix == "PPSA")
        #expect(fused[0].platform == "ps5")
    }

    @Test("Merge output is deterministic and ordered left→right")
    func deterministicOrder() {
        let d = [
            RecognitionFixtures.anchored(id: 0, title: "Returnal", platform: "ps5", confidence: 0.9, x: 3000),
            RecognitionFixtures.anchored(id: 1, title: "Demon's Souls", platform: "ps5", confidence: 0.9, x: 500),
        ]
        let merged = ScanMerge.merge(d)
        #expect(merged.map(\.printedTitle) == ["Demon's Souls", "Returnal"])
        #expect(merged.map(\.id) == [0, 1])
    }
}

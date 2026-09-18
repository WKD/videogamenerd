import Testing
@testable import VGN

struct DedupeTests {

    @Test("Same game across overlap tiles merges, keeping best confidence")
    func mergeOverlap() {
        let detections = [
            Dedupe.Detection(id: 1, title: "God of War", platform: "ps4", confidence: 0.7),
            Dedupe.Detection(id: 2, title: "God of War™", platform: "ps4", confidence: 0.95),
            Dedupe.Detection(id: 3, title: "Bloodborne", platform: "ps4", confidence: 0.9),
        ]
        let clusters = Dedupe.cluster(detections)
        #expect(clusters.count == 2)
        let gow = clusters.first { $0.representative.title.contains("God") }!
        #expect(gow.members.count == 2)
        #expect(gow.representative.id == 2)   // highest confidence
    }

    @Test("Same title on different platforms does NOT merge")
    func differentPlatforms() {
        let detections = [
            Dedupe.Detection(id: 1, title: "Resident Evil 4", platform: "ps4", confidence: 0.9),
            Dedupe.Detection(id: 2, title: "Resident Evil 4", platform: "switch", confidence: 0.9),
        ]
        #expect(Dedupe.cluster(detections).count == 2)
    }

    @Test("Distinct games on the same platform stay separate")
    func distinctGames() {
        let detections = [
            Dedupe.Detection(id: 1, title: "Final Fantasy X", platform: "ps2", confidence: 0.9),
            Dedupe.Detection(id: 2, title: "Final Fantasy X-2", platform: "ps2", confidence: 0.9),
        ]
        #expect(Dedupe.cluster(detections).count == 2)
    }

    @Test("Alternative names help merge a localized spine")
    func altNames() {
        let detections = [
            Dedupe.Detection(id: 1, title: "Broken Sword", platform: "ps1", confidence: 0.8,
                             alternativeNames: ["Les Chevaliers de Baphomet"]),
            Dedupe.Detection(id: 2, title: "Les Chevaliers de Baphomet", platform: "ps1", confidence: 0.85),
        ]
        let clusters = Dedupe.cluster(detections)
        #expect(clusters.count == 1)
        #expect(clusters[0].representative.id == 2)
    }

    @Test("Empty input yields no clusters; output order deterministic")
    func empties() {
        #expect(Dedupe.cluster([]).isEmpty)
        let detections = [
            Dedupe.Detection(id: 5, title: "A", platform: "p", confidence: 0.5),
            Dedupe.Detection(id: 2, title: "B", platform: "p", confidence: 0.5),
        ]
        let clusters = Dedupe.cluster(detections)
        #expect(clusters.map(\.representative.id) == [2, 5])
    }
}

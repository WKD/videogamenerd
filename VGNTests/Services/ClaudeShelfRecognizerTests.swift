import Foundation
import Testing
@testable import VGN

/// `ClaudeShelfRecognizer` against the stub runner: mapping, filtering, progress
/// events, partial-failure tolerance, bounded concurrency, determinism.
struct ClaudeShelfRecognizerTests {

    private func collectEvents() -> (handler: @Sendable (ShelfRecognitionEvent) -> Void, events: @Sendable () -> [ShelfRecognitionEvent]) {
        let box = EventBox()
        return ({ box.append($0) }, { box.snapshot() })
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ShelfRecognitionEvent] = []
        func append(_ e: ShelfRecognitionEvent) { lock.withLock { events.append(e) } }
        func snapshot() -> [ShelfRecognitionEvent] { lock.withLock { events } }
    }

    @Test("Maps items to source coordinates and drops non-games and empty titles")
    func mappingAndFiltering() async {
        let runner = StubShelfCLIRunner()
        let tile = RecognitionFixtures.tile(id: 0, fileName: "p-tile0.jpg",
                                            rect: SourceRect(x: 1000, y: 400, width: 1500, height: 1250))
        runner.setResponse(forFileName: "p-tile0.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "Bloodborne", platform: "ps4", confidence: 0.95, xStart: 0.0, xEnd: 0.2),
            SpineDetection(printedTitle: "My Dying Bride DVD", confidence: 0.3, isGame: false),
            SpineDetection(printedTitle: "   ", confidence: 0.1, isGame: true),
            SpineDetection(printedTitle: "Sekiro", platform: "ps4", confidence: 0.9, xStart: 0.8, xEnd: 1.0),
        ])))

        let recognizer = ClaudeShelfRecognizer(runner: runner)
        let detections = await recognizer.recognize(tiles: [tile])
        #expect(detections.map(\.printedTitle) == ["Bloodborne", "Sekiro"])
        // Source x for Bloodborne: 1000 + 0.0*1500 = 1000.
        #expect(detections[0].sourceRect.x == 1000)
        // Sekiro: 1000 + 0.8*1500 = 2200.
        #expect(detections[1].sourceRect.x == 2200)
        #expect(detections[0].sourceRect.y == 400)
        #expect(detections[0].sourceRect.height == 1250)
    }

    @Test("Emits queued → running → done per tile")
    func progressEvents() async {
        let runner = StubShelfCLIRunner()
        let tile = RecognitionFixtures.tile(id: 0, fileName: "p-tile0.jpg")
        runner.setResponse(forFileName: "p-tile0.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "Halo", platform: "xbox360", confidence: 0.8),
        ])))
        let (handler, events) = collectEvents()
        _ = await ClaudeShelfRecognizer(runner: runner).recognize(tiles: [tile], onEvent: handler)
        let seen = events()
        #expect(seen.contains(.queued(tileID: 0, total: 1)))
        #expect(seen.contains(.running(tileID: 0)))
        #expect(seen.contains(.done(tileID: 0, items: 1)))
    }

    @Test("A failed tile is tolerated: others still produce detections")
    func partialFailure() async {
        let runner = StubShelfCLIRunner()
        let t0 = RecognitionFixtures.tile(id: 0, fileName: "p-tile0.jpg")
        let t1 = RecognitionFixtures.tile(id: 1, fileName: "p-tile1.jpg")
        runner.setResponse(forFileName: "p-tile0.jpg", .init(error: .timedOut(after: 30)))
        runner.setResponse(forFileName: "p-tile1.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "Persona 5", platform: "ps4", confidence: 0.9),
        ])))
        let (handler, events) = collectEvents()
        let detections = await ClaudeShelfRecognizer(runner: runner).recognize(tiles: [t0, t1], onEvent: handler)
        #expect(detections.map(\.printedTitle) == ["Persona 5"])
        #expect(events().contains(where: { if case .failed(0, _) = $0 { return true } else { return false } }))
    }

    @Test("Concurrency is bounded by maxConcurrent")
    func boundedConcurrency() async {
        let runner = StubShelfCLIRunner(defaultJSON: #"{"items":[]}"#, delaySeconds: 0.15)
        let tiles = (0..<6).map { RecognitionFixtures.tile(id: $0, fileName: "p-tile\($0).jpg") }
        _ = await ClaudeShelfRecognizer(runner: runner, maxConcurrent: 2).recognize(tiles: tiles)
        #expect(runner.callCount == 6)
        #expect(runner.peakConcurrency <= 2)
    }

    @Test("Result order is deterministic (by tile, then within tile)")
    func deterministicOrder() async {
        let runner = StubShelfCLIRunner()
        let tiles = (0..<3).map { RecognitionFixtures.tile(id: $0, fileName: "p-tile\($0).jpg") }
        runner.setResponse(forFileName: "p-tile0.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "A", platform: "ps5", confidence: 0.9),
        ])))
        runner.setResponse(forFileName: "p-tile1.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "B", platform: "ps5", confidence: 0.9),
            SpineDetection(printedTitle: "C", platform: "ps5", confidence: 0.9),
        ])))
        runner.setResponse(forFileName: "p-tile2.jpg", .init(json: RecognitionFixtures.itemsJSON([
            SpineDetection(printedTitle: "D", platform: "ps5", confidence: 0.9),
        ])))
        let first = await ClaudeShelfRecognizer(runner: runner).recognize(tiles: tiles)
        let second = await ClaudeShelfRecognizer(runner: runner).recognize(tiles: tiles)
        #expect(first.map(\.printedTitle) == ["A", "B", "C", "D"])
        #expect(first.map(\.printedTitle) == second.map(\.printedTitle))
        #expect(first.map(\.id) == [0, 1, 2, 3])
    }
}

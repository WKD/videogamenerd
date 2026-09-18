import Foundation
@testable import VGN

// MARK: - Stub CLI runner for recognition

/// A `ClaudeCLIRunning` stub: routes canned structured JSON (or a typed error) by the
/// tile file's basename, tracks peak concurrency, and can add a delay so concurrency
/// bounds are observable. No process is ever spawned.
final class StubShelfCLIRunner: ClaudeCLIRunning, @unchecked Sendable {
    struct Response: Sendable {
        var json: String?
        var error: ClaudeCLIError?
        var delaySeconds: Double
        init(json: String? = nil, error: ClaudeCLIError? = nil, delaySeconds: Double = 0) {
            self.json = json; self.error = error; self.delaySeconds = delaySeconds
        }
    }

    private let lock = NSLock()
    private var byFileName: [String: Response] = [:]
    private var defaultResponse: Response
    private var active = 0
    private var _peak = 0
    private var _callCount = 0

    init(defaultJSON: String = #"{"items":[]}"#, delaySeconds: Double = 0) {
        self.defaultResponse = Response(json: defaultJSON, delaySeconds: delaySeconds)
    }

    func setResponse(forFileName name: String, _ response: Response) {
        lock.withLock { byFileName[name] = response }
    }

    var peakConcurrency: Int { lock.withLock { _peak } }
    var callCount: Int { lock.withLock { _callCount } }

    func runStructured<Value: Decodable & Sendable>(
        _ type: Value.Type,
        prompt: String,
        schema: String,
        allowedTools: [String],
        files: [URL],
        options: ClaudeRunOptions
    ) async throws -> ClaudeCLIResult<Value> {
        let name = files.first?.lastPathComponent ?? ""
        let response: Response = lock.withLock {
            _callCount += 1
            active += 1
            _peak = max(_peak, active)
            return byFileName[name] ?? defaultResponse
        }
        defer { lock.withLock { active -= 1 } }

        if response.delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(response.delaySeconds * 1_000_000_000))
        }
        if let error = response.error { throw error }
        let data = Data((response.json ?? "{}").utf8)
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            return ClaudeCLIResult(value: value, metrics: ClaudeRunMetrics(costUSD: 0.01, numTurns: 2, model: options.model))
        } catch {
            throw ClaudeCLIError.malformedOutput("stub decode: \(error)")
        }
    }

    func runText(prompt: String, options: ClaudeRunOptions) async throws -> ClaudeCLIResult<String> {
        ClaudeCLIResult(value: "", metrics: ClaudeRunMetrics())
    }

    func preflight() async throws -> URL { URL(fileURLWithPath: "/stub/claude") }
}

// MARK: - Builders

enum RecognitionFixtures {
    /// A `ShelfTile` with a controllable file name (its basename routes stub responses).
    static func tile(
        id: Int,
        fileName: String,
        rect: SourceRect = SourceRect(x: 0, y: 0, width: 1500, height: 1250),
        row: Int = 0,
        sourceSize: ImagePixelSize = ImagePixelSize(width: 5712, height: 4284)
    ) -> ShelfTile {
        ShelfTile(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(fileName)"),
            rect: rect,
            row: row,
            sourceSize: sourceSize
        )
    }

    /// Encode a `TileRecognitionResult` JSON string from detections.
    static func itemsJSON(_ items: [SpineDetection]) -> String {
        let data = try! JSONEncoder().encode(TileRecognitionResult(items: items))
        return String(decoding: data, as: UTF8.self)
    }

    /// An anchored detection at a given source position (for merge tests).
    static func anchored(
        id: Int,
        title: String,
        platform: String?,
        confidence: Double,
        x: Int,
        width: Int = 100,
        tileID: Int = 0,
        normalized: String? = nil,
        serial: SpineSerialCode? = nil
    ) -> AnchoredDetection {
        AnchoredDetection(
            id: id,
            detection: SpineDetection(printedTitle: title, normalizedTitle: normalized, platform: platform, confidence: confidence),
            tileID: tileID,
            row: 0,
            sourceRect: SourceRect(x: x, y: 0, width: width, height: 1200),
            serialCode: serial
        )
    }

    /// Build an `IGDBSearchResult` value for match tests.
    static func igdb(
        id: Int64,
        name: String,
        year: Int? = nil,
        cover: String? = nil,
        platformSlugs: [String] = [],
        alternativeNames: [String] = [],
        gameType: IGDBGameType = .mainGame
    ) -> IGDBSearchResult {
        IGDBSearchResult(
            id: id, name: name, releaseYear: year, coverImageID: cover,
            platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: platformSlugs,
            genres: [], alternativeNames: alternativeNames, gameType: gameType
        )
    }
}

// MARK: - Stubs for the pipeline

/// A `ShelfRecognizer` that returns fixed anchored detections regardless of tiles.
struct StubShelfRecognizer: ShelfRecognizer {
    let detections: [AnchoredDetection]
    func recognize(
        tiles: [ShelfTile],
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void
    ) async -> [AnchoredDetection] {
        for tile in tiles { onEvent(.queued(tileID: tile.id, total: tiles.count)) }
        onEvent(.running(tileID: tiles.first?.id ?? 0))
        onEvent(.done(tileID: tiles.first?.id ?? 0, items: detections.count))
        return detections
    }
}

/// An `IGDBGameSearching` stub: returns canned results, recording queries and whether
/// each was platform-constrained.
final class StubIGDBSearcher: IGDBGameSearching, @unchecked Sendable {
    private let lock = NSLock()
    private let responder: @Sendable (String, [Int]?) -> [IGDBSearchResult]
    private var _queries: [(text: String, constrained: Bool)] = []

    init(responder: @escaping @Sendable (String, [Int]?) -> [IGDBSearchResult]) {
        self.responder = responder
    }

    var queries: [(text: String, constrained: Bool)] { lock.withLock { _queries } }

    func searchGames(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult] {
        lock.withLock { _queries.append((text, platformIGDBIDs != nil)) }
        return responder(text, platformIGDBIDs)
    }
}

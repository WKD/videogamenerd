import Foundation

/// The Claude-vision recognition engine (PLAN §6.2 step 2): one isolated `claude -p`
/// call per tile, bounded parallelism, per-tile progress, partial failures tolerated.
/// Each tile is recognised in complete isolation — no shared context — which is what
/// prevents the cross-photo contamination documented in docs/ACCEPTANCE.md.
struct ClaudeShelfRecognizer: ShelfRecognizer {
    private let runner: ClaudeCLIRunning
    private let model: String?
    private let maxConcurrent: Int
    private let options: ClaudeRunOptions
    private let onMetrics: (@Sendable (Int, ClaudeRunMetrics) -> Void)?

    /// - Parameters:
    ///   - runner: the generic CLI runner (injectable stub for tests).
    ///   - model: model override, or nil for the CLI default (PLAN: default unless
    ///     clearly insufficient).
    ///   - maxConcurrent: bound on simultaneous CLI calls (default 3).
    ///   - onMetrics: optional per-tile cost/usage/timing sink (for a progress UI's
    ///     running cost display, and the accuracy harness).
    init(
        runner: ClaudeCLIRunning,
        model: String? = nil,
        maxConcurrent: Int = 3,
        options: ClaudeRunOptions = .imageRecognition,
        onMetrics: (@Sendable (Int, ClaudeRunMetrics) -> Void)? = nil
    ) {
        self.runner = runner
        self.model = model
        self.maxConcurrent = max(1, maxConcurrent)
        var options = options
        options.model = model
        self.options = options
        self.onMetrics = onMetrics
    }

    func recognize(
        tiles: [ShelfTile],
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void
    ) async -> [AnchoredDetection] {
        guard !tiles.isEmpty else { return [] }
        let total = tiles.count
        for tile in tiles { onEvent(.queued(tileID: tile.id, total: total)) }

        let semaphore = AsyncSemaphore(permits: maxConcurrent)

        // Recognise tiles concurrently (bounded); collect per-tile detection lists.
        let perTile: [(tileID: Int, detections: [AnchoredDetection])] = await withTaskGroup(
            of: (Int, [AnchoredDetection]).self
        ) { group in
            for tile in tiles {
                group.addTask {
                    let detections = await Self.recognizeOne(
                        tile: tile,
                        runner: runner,
                        schema: ShelfRecognitionPrompt.jsonSchema,
                        options: options,
                        semaphore: semaphore,
                        onEvent: onEvent,
                        onMetrics: onMetrics
                    )
                    return (tile.id, detections)
                }
            }
            var out: [(Int, [AnchoredDetection])] = []
            for await result in group { out.append(result) }
            return out
        }

        // Deterministic order: by tile id, then within-tile order. Reassign global ids.
        let ordered = perTile.sorted { $0.tileID < $1.tileID }.flatMap(\.detections)
        return Self.reindexed(ordered)
    }

    // MARK: - One tile

    private static func recognizeOne(
        tile: ShelfTile,
        runner: ClaudeCLIRunning,
        schema: String,
        options: ClaudeRunOptions,
        semaphore: AsyncSemaphore,
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void,
        onMetrics: (@Sendable (Int, ClaudeRunMetrics) -> Void)?
    ) async -> [AnchoredDetection] {
        do {
            return try await semaphore.withPermit {
                onEvent(.running(tileID: tile.id))
                let prompt = ShelfRecognitionPrompt.prompt(tileFileName: tile.fileName)
                let result = try await runner.runStructured(
                    TileRecognitionResult.self,
                    prompt: prompt,
                    schema: schema,
                    allowedTools: ["Read"],
                    files: [tile.fileURL],
                    options: options
                )
                onMetrics?(tile.id, result.metrics)
                let anchored = anchor(result.value.items, to: tile)
                onEvent(.done(tileID: tile.id, items: anchored.count))
                return anchored
            }
        } catch is CancellationError {
            onEvent(.failed(tileID: tile.id, reason: "cancelled"))
            return []
        } catch let error as ClaudeCLIError {
            onEvent(.failed(tileID: tile.id, reason: error.shortDescription))
            return []
        } catch {
            onEvent(.failed(tileID: tile.id, reason: "\(error)"))
            return []
        }
    }

    /// Map a tile's raw detections into source-image coordinates, dropping non-games
    /// and empty titles.
    static func anchor(_ items: [SpineDetection], to tile: ShelfTile) -> [AnchoredDetection] {
        var out: [AnchoredDetection] = []
        for detection in items {
            let title = detection.printedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard detection.isGame, !title.isEmpty else { continue }
            let x0 = clamp01(detection.xStart ?? 0)
            let x1 = max(x0, clamp01(detection.xEnd ?? 1))
            let sx = tile.rect.x + Int(x0 * Double(tile.rect.width))
            let sw = max(1, Int((x1 - x0) * Double(tile.rect.width)))
            let sourceRect = SourceRect(x: sx, y: tile.rect.y, width: min(sw, tile.rect.maxX - sx), height: tile.rect.height)
            out.append(AnchoredDetection(
                id: out.count,
                detection: detection,
                tileID: tile.id,
                row: tile.row,
                sourceRect: sourceRect,
                serialCode: nil
            ))
        }
        return out
    }

    private static func reindexed(_ detections: [AnchoredDetection]) -> [AnchoredDetection] {
        detections.enumerated().map { index, d in
            AnchoredDetection(
                id: index,
                detection: d.detection,
                tileID: d.tileID,
                row: d.row,
                sourceRect: d.sourceRect,
                serialCode: d.serialCode
            )
        }
    }

    private static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
}

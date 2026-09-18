import Foundation

/// Per-tile progress, surfaced to the review sheet as a row per tile (PLAN §6.2).
enum ShelfRecognitionEvent: Sendable, Equatable {
    case queued(tileID: Int, total: Int)
    case running(tileID: Int)
    case done(tileID: Int, items: Int)
    case failed(tileID: Int, reason: String)
}

/// The recognition engine seam (PLAN §6.2: "`ShelfRecognizer` protocol, two engines").
/// One call per tile, bounded parallelism, partial failures tolerated (a failed tile
/// contributes no detections but never aborts the run).
protocol ShelfRecognizer: Sendable {
    /// Recognise every tile, emitting progress via `onEvent`. Returns anchored
    /// detections (mapped back into source-image coordinates). Never throws — tile
    /// failures are reported as `.failed` events and omitted from the result.
    func recognize(
        tiles: [ShelfTile],
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void
    ) async -> [AnchoredDetection]
}

extension ShelfRecognizer {
    /// Convenience with no progress callback.
    func recognize(tiles: [ShelfTile]) async -> [AnchoredDetection] {
        await recognize(tiles: tiles, onEvent: { _ in })
    }

    /// Streaming convenience: an `AsyncStream` of progress events plus a `Task` that
    /// resolves to the detections. The UI lane can drive the progress rows off the
    /// stream and show results when the task completes.
    func recognizeStreaming(
        tiles: [ShelfTile]
    ) -> (events: AsyncStream<ShelfRecognitionEvent>, result: Task<[AnchoredDetection], Never>) {
        let (stream, continuation) = AsyncStream<ShelfRecognitionEvent>.makeStream()
        let task = Task { () -> [AnchoredDetection] in
            let detections = await recognize(tiles: tiles) { event in
                continuation.yield(event)
            }
            continuation.finish()
            return detections
        }
        return (stream, task)
    }
}

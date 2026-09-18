import Foundation
import Vision
import ImageIO
import CoreGraphics

/// The offline recognition engine (PLAN §6.2 step 3): Apple Vision `RecognizeTextRequest`
/// run on the upright tile plus both 90° rotations (spine text is rotated), clustered
/// into spines, producing the same `AnchoredDetection` type as the Claude engine —
/// with honest, low confidence — plus serial-code extraction as a platform booster.
@available(macOS 15.0, *)
struct VisionShelfRecognizer: ShelfRecognizer {
    /// OCR confidence is scaled by this because reading rotated, stylised spines is
    /// far less reliable than the vision model; the review sheet must treat Vision
    /// results as low-confidence hints.
    var confidenceScale: Double
    /// x-centre tolerance for clustering, as a fraction of tile width.
    var xToleranceFraction: Double
    var recognitionLanguages: [String]

    init(
        confidenceScale: Double = 0.6,
        xToleranceFraction: Double = 0.035,
        recognitionLanguages: [String] = ["en", "fr"]
    ) {
        self.confidenceScale = confidenceScale
        self.xToleranceFraction = xToleranceFraction
        self.recognitionLanguages = recognitionLanguages
    }

    func recognize(
        tiles: [ShelfTile],
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void
    ) async -> [AnchoredDetection] {
        guard !tiles.isEmpty else { return [] }
        for tile in tiles { onEvent(.queued(tileID: tile.id, total: tiles.count)) }

        var all: [AnchoredDetection] = []
        for tile in tiles {
            onEvent(.running(tileID: tile.id))
            do {
                let detections = try await recognizeTile(tile)
                all.append(contentsOf: detections)
                onEvent(.done(tileID: tile.id, items: detections.count))
            } catch {
                onEvent(.failed(tileID: tile.id, reason: "\(error)"))
            }
        }
        // Reassign global ids in tile order.
        return all.enumerated().map { index, d in
            AnchoredDetection(id: index, detection: d.detection, tileID: d.tileID,
                              row: d.row, sourceRect: d.sourceRect, serialCode: d.serialCode)
        }
    }

    // MARK: - One tile

    private func recognizeTile(_ tile: ShelfTile) async throws -> [AnchoredDetection] {
        guard let source = CGImageSourceCreateWithURL(tile.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }

        let lines = try await recognizeLines(in: image)
        let tolerance = max(20, Int(Double(image.width) * xToleranceFraction))
        let spines = VisionSpineClusterer.cluster(lines, xTolerance: tolerance)

        var out: [AnchoredDetection] = []
        for spine in spines {
            let title = spine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 3 else { continue }
            // Map the cluster rect (tile px) into source px.
            let sourceRect = SourceRect(
                x: tile.rect.x + spine.rect.x,
                y: tile.rect.y + spine.rect.y,
                width: spine.rect.width,
                height: spine.rect.height
            )
            let detection = SpineDetection(
                printedTitle: title,
                normalizedTitle: nil,
                platform: spine.serial?.platformSlug,   // Vision can't read banners; the serial is the only platform signal
                editionHints: [],
                isCompilation: false,
                confidence: min(1, spine.confidence * confidenceScale),
                spineIndex: nil,
                xStart: Double(spine.rect.x) / Double(max(1, tile.rect.width)),
                xEnd: Double(spine.rect.maxX) / Double(max(1, tile.rect.width)),
                isGame: true
            )
            out.append(AnchoredDetection(
                id: out.count, detection: detection, tileID: tile.id, row: tile.row,
                sourceRect: sourceRect, serialCode: spine.serial
            ))
        }
        return out
    }

    /// Run OCR on the image at three orientations and return de-duplicated lines in
    /// tile pixel space (Vision maps bounding boxes back to the un-oriented image, so
    /// `toImageCoordinates` with the tile size is correct for every orientation).
    func recognizeLines(in image: CGImage) async throws -> [VisionTextLine] {
        let size = CGSize(width: image.width, height: image.height)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages.map { Locale.Language(identifier: $0) }

        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left]
        var lines: [VisionTextLine] = []
        for orientation in orientations {
            let observations = try await request.perform(on: image, orientation: orientation)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let cg = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                let rect = SourceRect(
                    x: Int(cg.origin.x.rounded()),
                    y: Int(cg.origin.y.rounded()),
                    width: Int(cg.size.width.rounded()),
                    height: Int(cg.size.height.rounded())
                )
                lines.append(VisionTextLine(text: text, rect: rect, confidence: Double(candidate.confidence)))
            }
        }
        return Self.deduplicate(lines)
    }

    /// Drop near-duplicate lines (same text read at more than one orientation),
    /// keeping the higher-confidence one.
    static func deduplicate(_ lines: [VisionTextLine]) -> [VisionTextLine] {
        var kept: [VisionTextLine] = []
        for line in lines.sorted(by: { $0.confidence > $1.confidence }) {
            let key = line.text.lowercased()
            let dup = kept.contains { existing in
                existing.text.lowercased() == key && existing.rect.horizontalOverlap(with: line.rect) > 0
            }
            if !dup { kept.append(line) }
        }
        return kept
    }
}

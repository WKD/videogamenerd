import Foundation

/// One line of recognised text in a tile's pixel space (origin top-left). This is the
/// output of Apple Vision, recorded to a fixture so the clustering logic can be tested
/// without the framework.
struct VisionTextLine: Sendable, Equatable, Codable {
    var text: String
    var rect: SourceRect
    var confidence: Double
}

/// One clustered spine: the joined text of its lines, its bounding rect, an honest
/// (deliberately low) confidence, and any serial code found in the text.
struct ClusteredSpine: Sendable, Equatable {
    var text: String
    var lines: [String]
    var rect: SourceRect
    var confidence: Double
    var serial: SpineSerialCode?
}

/// Groups OCR lines into spines (PLAN §6.2 step 3: "cluster lines into spines").
/// Shelf spines are vertical columns, so a spine's stacked words share a horizontal
/// (x) position; lines are grouped by x-centre proximity and ordered top→bottom.
enum VisionSpineClusterer {

    /// Cluster `lines` by x-centre. `xTolerance` is the max centre distance (px) for
    /// two lines to be the same spine.
    static func cluster(_ lines: [VisionTextLine], xTolerance: Int) -> [ClusteredSpine] {
        let valid = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else { return [] }
        let sorted = valid.sorted { $0.rect.midX < $1.rect.midX }

        var clusters: [[VisionTextLine]] = []
        var runningCenters: [Double] = []
        for line in sorted {
            if let center = runningCenters.last, abs(line.rect.midX - center) <= Double(xTolerance) {
                clusters[clusters.count - 1].append(line)
                // Update running mean centre.
                let group = clusters[clusters.count - 1]
                runningCenters[runningCenters.count - 1] = group.reduce(0.0) { $0 + $1.rect.midX } / Double(group.count)
            } else {
                clusters.append([line])
                runningCenters.append(line.rect.midX)
            }
        }

        return clusters
            .map { group -> ClusteredSpine in
                let ordered = group.sorted { $0.rect.y < $1.rect.y }   // top → bottom
                let texts = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                let joined = texts.joined(separator: " ")
                let rect = boundingBox(of: ordered.map(\.rect))
                let confidence = ordered.reduce(0.0) { $0 + $1.confidence } / Double(ordered.count)
                return ClusteredSpine(
                    text: joined,
                    lines: texts,
                    rect: rect,
                    confidence: confidence,
                    serial: SpineSerialCode.first(in: joined)
                )
            }
            .sorted { $0.rect.x < $1.rect.x }
    }

    static func boundingBox(of rects: [SourceRect]) -> SourceRect {
        guard let first = rects.first else { return SourceRect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x); minY = min(minY, rect.y)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }
        return SourceRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

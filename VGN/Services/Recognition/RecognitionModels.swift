import Foundation

/// A size in image pixels.
struct ImagePixelSize: Sendable, Equatable, Codable {
    var width: Int
    var height: Int
    init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// An axis-aligned rectangle in the **source image's** pixel space (origin top-left).
struct SourceRect: Sendable, Equatable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var midX: Double { Double(x) + Double(width) / 2 }

    /// Horizontal overlap (in px) with another rect; 0 or negative → no overlap.
    func horizontalOverlap(with other: SourceRect) -> Int {
        max(0, min(maxX, other.maxX) - max(x, other.x))
    }
}

/// One JPEG tile written to a temp directory, tagged with where it came from in the
/// source image so detections can be mapped back onto the photo for the review sheet.
struct ShelfTile: Sendable, Equatable, Identifiable {
    /// 0-based index in scan order (row-major).
    let id: Int
    /// The on-disk JPEG (in a temp dir the pipeline owns).
    let fileURL: URL
    /// Where this tile sits in the source image (pixels).
    let rect: SourceRect
    /// Shelf-row band index this tile belongs to (0 = top).
    let row: Int
    /// The full source image size, for scaling detections.
    let sourceSize: ImagePixelSize

    var fileName: String { fileURL.lastPathComponent }
}

/// One item the recogniser read off a single tile (the structured CLI output shape,
/// PLAN §6.2 step 2). Positions are within the tile, normalised to 0…1.
struct SpineDetection: Codable, Sendable, Equatable {
    /// The title exactly as printed on the spine (may be a French/edition title).
    var printedTitle: String
    /// The model's guess at the canonical English/normalised title (nil if unsure).
    var normalizedTitle: String?
    /// VGN platform slug guessed from the spine banner (nil if unreadable).
    var platform: String?
    /// Edition markers seen ("Collector's", "GOTY", "Deluxe", "Steelbook"…).
    var editionHints: [String]
    /// The model's guess that this box is a compilation / bundle.
    var isCompilation: Bool
    /// Recognition confidence in 0…1.
    var confidence: Double
    /// Spine position index left→right within the tile (0-based), if known.
    var spineIndex: Int?
    /// Approximate horizontal span within the tile, normalised 0…1.
    var xStart: Double?
    var xEnd: Double?
    /// The model's assertion that this is a video game (non-games must be omitted;
    /// this is a defensive backstop).
    var isGame: Bool

    init(
        printedTitle: String,
        normalizedTitle: String? = nil,
        platform: String? = nil,
        editionHints: [String] = [],
        isCompilation: Bool = false,
        confidence: Double = 0,
        spineIndex: Int? = nil,
        xStart: Double? = nil,
        xEnd: Double? = nil,
        isGame: Bool = true
    ) {
        self.printedTitle = printedTitle
        self.normalizedTitle = normalizedTitle
        self.platform = platform
        self.editionHints = editionHints
        self.isCompilation = isCompilation
        self.confidence = confidence
        self.spineIndex = spineIndex
        self.xStart = xStart
        self.xEnd = xEnd
        self.isGame = isGame
    }
}

/// The structured result of one tile recognition call: a list of spine detections.
struct TileRecognitionResult: Codable, Sendable, Equatable {
    var items: [SpineDetection]
    init(items: [SpineDetection]) { self.items = items }
}

/// A detection anchored back to the source image (tile origin applied), carrying its
/// approximate source rect for the review sheet and for overlap merging.
struct AnchoredDetection: Sendable, Equatable, Identifiable {
    let id: Int
    let detection: SpineDetection
    /// The tile this came from.
    let tileID: Int
    let row: Int
    /// Approximate location in the source image (from the tile origin + the
    /// detection's normalised x-span, full tile height when the span is unknown).
    let sourceRect: SourceRect
    /// A best-effort serial code (CUSA/PPSA/BLES…) if Vision found one nearby.
    var serialCode: SpineSerialCode?

    /// The best title to search with: printed title (as boxed) is primary.
    var printedTitle: String { detection.printedTitle }
    var platform: String? { serialCode?.platformSlug ?? detection.platform }
}

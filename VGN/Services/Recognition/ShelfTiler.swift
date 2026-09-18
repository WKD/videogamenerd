import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Tiling parameters. Tiles are ~1500 px wide (PLAN §6.2: Claude's reader works best
/// under ~2000 px a side and does not reliably downscale a 5712×4284 original).
/// Overlap is sized so a spine is never cut in *every* tile that touches it.
struct ShelfTilerConfig: Sendable, Equatable {
    /// Target tile width in source pixels.
    var tileWidth: Int
    /// A row band taller than this is split vertically (rare; shelves are ~2000 px).
    var maxTileHeight: Int
    /// Overlap between adjacent tiles in px.
    var overlap: Int
    /// JPEG quality for written tiles.
    var jpegQuality: Double
    /// Try to align rows to shelves via a brightness heuristic before gridding.
    var rowAware: Bool
    /// Minimum band height accepted from row detection (else fall back to a grid).
    var minBandHeight: Int

    init(
        tileWidth: Int = 1500,
        maxTileHeight: Int = 2200,
        overlap: Int = 420,
        jpegQuality: Double = 0.8,
        rowAware: Bool = true,
        minBandHeight: Int = 600
    ) {
        self.tileWidth = tileWidth
        self.maxTileHeight = maxTileHeight
        self.overlap = overlap
        self.jpegQuality = jpegQuality
        self.rowAware = rowAware
        self.minBandHeight = minBandHeight
    }

    static let `default` = ShelfTilerConfig()
}

enum ShelfTilerError: Error, Sendable, Equatable {
    case cannotReadImage(String)
    case cropFailed(Int)
    case writeFailed(String)
}

/// Cuts a shelf photo into overlapping, full-resolution JPEG tiles (PLAN §6.2 step 1).
/// Deterministic. Honours EXIF orientation. Memory-sane: decodes the source once
/// (ImageIO applies orientation), then crops each tile from that image.
struct ShelfTiler: Sendable {
    var config: ShelfTilerConfig

    init(config: ShelfTilerConfig = .default) { self.config = config }

    // MARK: - Public

    /// Tile `url` into `directory`, naming tiles `<basename>-tileN.jpg`. Returns the
    /// tile metadata (origin rects in the source image) for mapping detections back.
    func tile(imageAt url: URL, into directory: URL, basename: String) throws -> [ShelfTile] {
        let (image, size) = try Self.loadOriented(url: url)
        let bands = rowBands(image: image, size: size)
        let placed = Self.tileRects(sourceSize: size, bands: bands, config: config)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tiles: [ShelfTile] = []
        tiles.reserveCapacity(placed.count)
        for (index, placement) in placed.enumerated() {
            let rect = placement.rect
            guard let crop = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            else { throw ShelfTilerError.cropFailed(index) }
            let out = directory.appendingPathComponent("\(basename)-tile\(index).jpg")
            try Self.writeJPEG(crop, to: out, quality: config.jpegQuality)
            tiles.append(ShelfTile(id: index, fileURL: out, rect: rect, row: placement.row, sourceSize: size))
        }
        return tiles
    }

    // MARK: - Geometry (pure, deterministic, unit-tested without ImageIO)

    /// Overlapping start offsets tiling an axis of `length` with tiles of size `tile`
    /// and `overlap`. The final start is flushed to the edge so coverage is complete.
    static func axisStarts(length: Int, tile: Int, overlap: Int) -> [Int] {
        guard length > tile else { return [0] }
        let step = max(1, tile - overlap)
        var starts: [Int] = []
        var s = 0
        while s + tile < length {
            starts.append(s)
            s += step
        }
        starts.append(length - tile)   // flush the final tile to the far edge
        // De-dupe while preserving order (the flush can equal the last interior start).
        var seen = Set<Int>()
        return starts.filter { seen.insert($0).inserted }
    }

    /// The full set of tile rects for `bands` (each a full-width horizontal strip),
    /// splitting horizontally by `tileWidth` and vertically by `maxTileHeight`.
    static func tileRects(
        sourceSize: ImagePixelSize,
        bands: [SourceRect],
        config: ShelfTilerConfig
    ) -> [(rect: SourceRect, row: Int)] {
        var result: [(SourceRect, Int)] = []
        for (rowIndex, band) in bands.enumerated() {
            let vStarts = axisStarts(length: band.height, tile: config.maxTileHeight, overlap: config.overlap)
            let hStarts = axisStarts(length: band.width, tile: config.tileWidth, overlap: config.overlap)
            for vy in vStarts {
                let h = min(config.maxTileHeight, band.height - vy)
                for hx in hStarts {
                    let w = min(config.tileWidth, band.width - hx)
                    result.append((SourceRect(x: band.x + hx, y: band.y + vy, width: w, height: h), rowIndex))
                }
            }
        }
        return result
    }

    /// A single full-image band (grid fallback: vertical splitting happens in
    /// `tileRects`).
    static func gridBands(sourceSize: ImagePixelSize) -> [SourceRect] {
        [SourceRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height)]
    }

    /// Convert brightness-valley boundaries (source-y) into full-width bands.
    static func bands(fromBoundaries boundaries: [Int], sourceSize: ImagePixelSize, minBandHeight: Int) -> [SourceRect] {
        var edges = [0] + boundaries.filter { $0 > 0 && $0 < sourceSize.height }.sorted() + [sourceSize.height]
        edges = Array(Set(edges)).sorted()
        var out: [SourceRect] = []
        for i in 0..<(edges.count - 1) {
            let y = edges[i], next = edges[i + 1]
            let height = next - y
            if height >= minBandHeight {
                out.append(SourceRect(x: 0, y: y, width: sourceSize.width, height: height))
            } else if var last = out.last {
                // Absorb a too-thin strip into the previous band.
                last.height += height
                out[out.count - 1] = last
            }
        }
        return out.isEmpty ? gridBands(sourceSize: sourceSize) : out
    }

    // MARK: - Row detection (brightness valleys)

    private func rowBands(image: CGImage, size: ImagePixelSize) -> [SourceRect] {
        guard config.rowAware else { return Self.gridBands(sourceSize: size) }
        guard let profile = Self.rowLumaProfile(image: image, sampleHeight: 400) else {
            return Self.gridBands(sourceSize: size)
        }
        let valleys = Self.darkValleys(in: profile)
        // Map thumbnail rows back to source y.
        let scale = Double(size.height) / Double(profile.count)
        let boundaries = valleys.map { Int(Double($0) * scale) }
        let detected = Self.bands(fromBoundaries: boundaries, sourceSize: size, minBandHeight: config.minBandHeight)
        // Require a confident multi-band split; otherwise grid.
        return detected.count >= 2 ? detected : Self.gridBands(sourceSize: size)
    }

    /// Average luma per row of a small grayscale thumbnail (0…1). nil on failure.
    static func rowLumaProfile(image: CGImage, sampleHeight: Int) -> [Double]? {
        let aspect = Double(image.width) / Double(max(1, image.height))
        let h = min(sampleHeight, image.height)
        let w = max(1, Int(Double(h) * aspect))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        var profile = [Double](repeating: 0, count: h)
        for row in 0..<h {
            var sum = 0
            for col in 0..<w { sum += Int(bytes[row * w + col]) }
            // CGContext origin is bottom-left; flip so index 0 = top of the image.
            profile[h - 1 - row] = Double(sum) / Double(w) / 255.0
        }
        return profile
    }

    /// Indices of dark horizontal seams (local minima well below the median).
    static func darkValleys(in profile: [Double]) -> [Int] {
        guard profile.count > 8 else { return [] }
        let sorted = profile.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = median * 0.62
        var valleys: [Int] = []
        var i = 1
        let n = profile.count
        while i < n - 1 {
            if profile[i] < threshold && profile[i] <= profile[i - 1] && profile[i] <= profile[i + 1] {
                // Skip to the end of this dark run to avoid duplicate boundaries.
                var j = i
                while j < n - 1 && profile[j] < threshold { j += 1 }
                valleys.append((i + j) / 2)
                i = j + 1
            } else {
                i += 1
            }
        }
        return valleys
    }

    // MARK: - ImageIO

    /// Load `url` as a full-resolution CGImage with EXIF orientation applied.
    static func loadOriented(url: URL) throws -> (CGImage, ImagePixelSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ShelfTilerError.cannotReadImage(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxDim = max(pixelWidth, pixelHeight, 1)
        // A "thumbnail" at the full long-side size, with the orientation transform
        // baked in — gives an oriented, full-res image without a manual redraw.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ShelfTilerError.cannotReadImage(url.lastPathComponent)
        }
        return (image, ImagePixelSize(width: image.width, height: image.height))
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ShelfTilerError.writeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ShelfTilerError.writeFailed(url.lastPathComponent)
        }
    }
}

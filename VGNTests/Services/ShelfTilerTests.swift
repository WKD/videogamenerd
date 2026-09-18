import Foundation
import Testing
import ImageIO
@testable import VGN

/// Tiler geometry (pure, deterministic) plus one real-image integration pass on a
/// committed fixture.
struct ShelfTilerTests {

    // MARK: - axisStarts

    @Test("A short axis yields a single tile at 0")
    func shortAxis() {
        #expect(ShelfTiler.axisStarts(length: 800, tile: 1500, overlap: 420) == [0])
        #expect(ShelfTiler.axisStarts(length: 1500, tile: 1500, overlap: 420) == [0])
    }

    @Test("Starts begin at 0, end flush to the edge, and always overlap")
    func startsCoverEdges() {
        let length = 5712, tile = 1500, overlap = 420
        let starts = ShelfTiler.axisStarts(length: length, tile: tile, overlap: overlap)
        #expect(starts.first == 0)
        #expect(starts.last == length - tile)
        // Consecutive tiles overlap (gap between starts < tile).
        for i in 1..<starts.count {
            #expect(starts[i] - starts[i - 1] < tile)
        }
    }

    // MARK: - tileRects coverage

    private func fullyCovers(_ rects: [SourceRect], size: ImagePixelSize, step: Int = 97) -> Bool {
        var y = 0
        while y < size.height {
            var x = 0
            while x < size.width {
                let px = x, py = y
                if !rects.contains(where: { px >= $0.x && px < $0.maxX && py >= $0.y && py < $0.maxY }) {
                    return false
                }
                x += step
            }
            y += step
        }
        return true
    }

    @Test("Tiles cover every pixel of a real-sized photo")
    func coverage() {
        let size = ImagePixelSize(width: 5712, height: 4284)
        let bands = ShelfTiler.gridBands(sourceSize: size)
        let placed = ShelfTiler.tileRects(sourceSize: size, bands: bands, config: .default)
        let rects = placed.map(\.rect)
        #expect(rects.isEmpty == false)
        #expect(fullyCovers(rects, size: size))
        // Every tile stays within bounds and within the ~2000 px guideline.
        for rect in rects {
            #expect(rect.maxX <= size.width)
            #expect(rect.maxY <= size.height)
            #expect(rect.width <= ShelfTilerConfig.default.tileWidth)
            #expect(rect.height <= ShelfTilerConfig.default.maxTileHeight)
        }
    }

    @Test("Adjacent horizontal tiles overlap so a spine is never cut in every tile")
    func horizontalOverlap() {
        let size = ImagePixelSize(width: 5712, height: 1800)
        let placed = ShelfTiler.tileRects(sourceSize: size, bands: ShelfTiler.gridBands(sourceSize: size), config: .default)
        // Same-row neighbours must share horizontal pixels.
        let sorted = placed.map(\.rect).sorted { $0.x < $1.x }
        var sawOverlap = false
        for i in 1..<sorted.count where sorted[i].y == sorted[i - 1].y {
            if sorted[i].horizontalOverlap(with: sorted[i - 1]) > 0 { sawOverlap = true }
        }
        #expect(sawOverlap)
    }

    @Test("Geometry is deterministic")
    func deterministic() {
        let size = ImagePixelSize(width: 4000, height: 3000)
        let a = ShelfTiler.tileRects(sourceSize: size, bands: ShelfTiler.gridBands(sourceSize: size), config: .default)
        let b = ShelfTiler.tileRects(sourceSize: size, bands: ShelfTiler.gridBands(sourceSize: size), config: .default)
        #expect(a.map(\.rect) == b.map(\.rect))
    }

    @Test("Detected bands from boundaries cover the height and drop thin strips")
    func bandsFromBoundaries() {
        let size = ImagePixelSize(width: 5000, height: 4200)
        let bands = ShelfTiler.bands(fromBoundaries: [2100], sourceSize: size, minBandHeight: 600)
        #expect(bands.count == 2)
        #expect(bands[0].y == 0)
        #expect(bands.last?.maxY == 4200)
        // A boundary that would create a sub-minimum strip is absorbed.
        let thin = ShelfTiler.bands(fromBoundaries: [4100], sourceSize: size, minBandHeight: 600)
        #expect(thin.count == 1)
        #expect(thin[0].height == 4200)
    }

    // MARK: - Integration on a committed fixture

    @Test("Tiles a committed shelf fixture into readable JPEGs with correct metadata")
    func realImageTiling() throws {
        let url = try Fixtures.url("tile2_ps4_row.jpg")   // ~1560×1250 full-res crop
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-tiler-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tiler = ShelfTiler(config: ShelfTilerConfig(tileWidth: 1000, maxTileHeight: 1000, overlap: 300, rowAware: false))
        let tiles = try tiler.tile(imageAt: url, into: dir, basename: "img")
        #expect(tiles.count >= 2)   // 1560×1250 with 1000-px tiles → a grid
        for tile in tiles {
            #expect(FileManager.default.fileExists(atPath: tile.fileURL.path))
            // Each written tile is a decodable image of the recorded size.
            let src = try #require(CGImageSourceCreateWithURL(tile.fileURL as CFURL, nil))
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect(img.width == tile.rect.width)
            #expect(img.height == tile.rect.height)
        }
        // The union of tile rects covers the source.
        let size = tiles[0].sourceSize
        let covered = fullyCovers(tiles.map(\.rect), size: size)
        #expect(covered)
    }
}

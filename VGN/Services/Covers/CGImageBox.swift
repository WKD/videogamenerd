import Foundation
import CoreGraphics
import ImageIO

/// A `Sendable` box around a `CGImage`.
///
/// `CGImage` is immutable once created and safe to read concurrently, but Core
/// Graphics does not annotate it `Sendable`. Wrapping it in a `final class` with
/// `@unchecked Sendable` lets it cross actor boundaries (from `CoverStore` to the
/// `@MainActor` UI) without copies. Safe because nothing ever mutates the wrapped
/// image — it is only ever read.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }

    /// Approximate decoded-bytes cost, for `NSCache` cost accounting.
    var cost: Int { image.height * image.bytesPerRow }
}

/// ImageIO downsampling (PLAN §3 "Done differently: ImageIO downsampling", §9). Never
/// decodes a full-resolution cover for a small cell.
enum ImageDownsampler {
    /// Produce a thumbnail of `source` no larger than `maxPixelSize` on its longest
    /// edge, using `CGImageSourceCreateThumbnailAtIndex` (decodes straight to the
    /// target size). Returns `nil` if the source cannot be read.
    static func thumbnail(fromFileAt url: URL, maxPixelSize: Int) -> CGImageBox? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return CGImageBox(image)
    }

    /// Same as ``thumbnail(fromFileAt:maxPixelSize:)`` but from in-memory `data` —
    /// used to preview a "Choose Cover…" candidate without ever writing it to disk
    /// (unchosen candidates must not pollute `covers/`/`thumbs/`, PLAN §5.2 step 4).
    static func thumbnail(fromData data: Data, maxPixelSize: Int) -> CGImageBox? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return CGImageBox(image)
    }
}

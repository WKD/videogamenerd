import CoreGraphics

/// The seam the grid loads cover thumbnails through (PLAN §9 image pipeline).
///
/// Next wave the services lane's `CoverStore` actor conforms to this: it
/// downsamples a stored cover to the cell's pixel size with
/// `CGImageSourceCreateThumbnailAtIndex`, de-dups in-flight requests and caches.
/// This wave the grid uses `NoopCoverLoader`, so every cell falls back to its
/// generated placeholder — which is the real day-one state anyway (a fresh
/// library has no covers).
///
/// `coverFile` is the file name inside the covers store (`GameSummary.coverFile`);
/// `pixelSize` is the cell's size in physical pixels (points × screen scale), so
/// the loader never decodes a 1000px cover for a 160pt cell.
protocol CoverLoading: Sendable {
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> sending CGImage?
}

/// The Wave 1 implementation: there is no cover pipeline yet, so nothing loads
/// and cells render their placeholder. Swapped for `CoverStore` next wave.
struct NoopCoverLoader: CoverLoading {
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> sending CGImage? {
        nil
    }
}

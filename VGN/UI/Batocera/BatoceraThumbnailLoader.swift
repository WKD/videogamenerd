import CoreGraphics
import Foundation

/// Decodes ROM box-art thumbnails **read from the Batocera share** (PLAN §15 phase 2), off
/// the main actor, into a small bounded in-memory cache. The share is read-only and may
/// vanish at any time, so every read degrades quietly to `nil` (the view shows a placeholder)
/// and **no image is ever copied** into the app's cover folder — a ROM's art is only imported
/// when it is promoted, through the normal enrichment path.
///
/// Keyed by absolute path + modification time + size bucket, so an edited scrape re-decodes
/// and browsing never evicts the library grid's own covers (this is a wholly separate cache).
actor BatoceraThumbnailLoader {
    /// The roms folder (`…/roms`) the entries' relative paths hang off. `nil` disables the
    /// loader (unconfigured / non-live) — every request returns `nil`.
    private let romsRoot: URL?
    private let cache = NSCache<NSString, CGImageBox>()
    private var inflight: [String: Task<CGImageBox?, Never>] = [:]

    init(romsRoot: URL?, memoryCostLimit: Int = 24 * 1024 * 1024) {
        self.romsRoot = romsRoot
        cache.totalCostLimit = memoryCostLimit
    }

    /// A decoded thumbnail for a catalogue entry, or `nil` (unmounted / missing / no art).
    /// Prefers the entry's `thumbnail` art, falling back to the full `image`.
    func thumbnail(system: String, thumbnailPath: String?, imagePath: String?,
                   maxPixelSize: Int = 256) async -> CGImage? {
        guard let romsRoot else { return nil }
        guard let relative = thumbnailPath ?? imagePath, !relative.isEmpty else { return nil }
        let fileURL = Self.resolve(romsRoot: romsRoot, system: system, relative: relative)

        // Read mtime + size once (a cheap stat); a missing file quietly yields nil.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let bucket = Self.bucket(for: maxPixelSize)
        let key = "\(fileURL.path)|\(mtime)|\(size)|\(bucket)"

        if let box = cache.object(forKey: key as NSString) { return box.image }
        if let task = inflight[key] { return await task.value?.image }

        let task = Task<CGImageBox?, Never>.detached(priority: .utility) {
            ImageDownsampler.thumbnail(fromFileAt: fileURL, maxPixelSize: bucket)
        }
        inflight[key] = task
        let box = await task.value
        inflight[key] = nil
        if let box { cache.setObject(box, forKey: key as NSString, cost: box.cost) }
        return box?.image
    }

    /// Resolve `<romsRoot>/<system>/<relative>` for a `./images/x-thumb.png`-style path.
    static func resolve(romsRoot: URL, system: String, relative: String) -> URL {
        var rel = relative
        if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
        return romsRoot.appendingPathComponent(system, isDirectory: true)
            .appendingPathComponent(rel)
    }

    /// Round a requested pixel size up to a small set of buckets so a scrolled grid does not
    /// decode dozens of near-identical sizes.
    static func bucket(for pixelSize: Int) -> Int {
        let buckets = [128, 192, 256, 384, 512]
        return buckets.first { $0 >= pixelSize } ?? buckets.last!
    }
}

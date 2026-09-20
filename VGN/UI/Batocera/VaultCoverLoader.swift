import CoreGraphics
import Foundation
import SwiftUI

/// Loads **remote** PS Plus cover art (a PS Store URL) into a small bounded **in-memory** cache
/// (PLAN §16), off the main actor. A Vault entry is not a library game, so its art is **never**
/// written to disk or the app's cover folder — it lives only in this cache for the session. Every
/// failure degrades quietly to nil (the view shows a placeholder). Keyed by URL + size bucket.
///
/// The fetch is injected (defaults to `URLSession.shared`) so tests never touch the network.
actor VaultCoverLoader {
    private let cache = NSCache<NSString, CGImageBox>()
    private var inflight: [String: Task<CGImageBox?, Never>] = [:]
    private let fetch: @Sendable (URL) async -> Data?

    init(memoryCostLimit: Int = 16 * 1024 * 1024,
         fetch: @escaping @Sendable (URL) async -> Data? = { url in
             try? await URLSession.shared.data(from: url).0
         }) {
        cache.totalCostLimit = memoryCostLimit
        self.fetch = fetch
    }

    /// A decoded cover for a remote URL string, or nil (no URL / unreachable / undecodable).
    func cover(urlString: String?, maxPixelSize: Int = 256) async -> CGImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let bucket = BatoceraThumbnailLoader.bucket(for: maxPixelSize)
        let key = "\(urlString)|\(bucket)"
        if let box = cache.object(forKey: key as NSString) { return box.image }
        if let task = inflight[key] { return await task.value?.image }

        let fetch = self.fetch
        let task = Task<CGImageBox?, Never>.detached(priority: .utility) {
            guard let data = await fetch(url) else { return nil }
            return ImageDownsampler.thumbnail(fromData: data, maxPixelSize: bucket)
        }
        inflight[key] = task
        let box = await task.value
        inflight[key] = nil
        if let box { cache.setObject(box, forKey: key as NSString, cost: box.cost) }
        return box?.image
    }
}

/// A PS Plus cover thumbnail loaded from a remote URL through ``VaultCoverLoader`` (PLAN §16).
/// Shows a placeholder while loading, when there is no URL, or when the fetch fails. Never
/// copies the image anywhere.
struct VaultCoverThumb: View {
    let entry: RomCatalogEntry
    let loader: VaultCoverLoader?
    var width: CGFloat = 44
    var height: CGFloat = 58

    @State private var image: CGImage?
    @State private var loadedKey: Int64 = -1

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    .overlay(Image(systemName: "playstation.logo").foregroundStyle(.secondary).font(.caption))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        guard entry.id != loadedKey else { return }
        image = nil
        guard let loader else { return }
        let decoded = await loader.cover(urlString: entry.coverURL, maxPixelSize: Int(max(width, height) * 2))
        if !Task.isCancelled { image = decoded; loadedKey = entry.id }
    }
}

import Foundation

/// A tiny key → decoded-image store for the `CoverStore`'s in-memory "Choose Cover…"
/// candidate previews.
///
/// Production is ``NSCachePreviewStore`` (an `NSCache`), which may evict any entry at
/// any time under memory pressure. That is exactly right for a preview — an unchosen
/// candidate is cheap to re-fetch, and the download still goes through the normal
/// rate-limited cover networking — but it makes "the second request is served from
/// memory" impossible to assert deterministically. Tests inject a non-evicting store
/// instead, so the flake (a real cache miss under the memory pressure of the full
/// parallel suite) cannot occur while the invariant it guards — an unchanged second
/// request costs no network — is still checked (wave 20).
protocol PreviewImageCache: AnyObject, Sendable {
    func object(forKey key: String) -> CGImageBox?
    func setObject(_ box: CGImageBox, forKey key: String, cost: Int)
}

/// The production preview cache: a cost-limited `NSCache`, thread-safe by contract, so
/// its own small cache means browsing candidates can't evict grid thumbnails and vice
/// versa. Eviction under memory pressure is desired here.
final class NSCachePreviewStore: PreviewImageCache, @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()

    init(costLimit: Int = 0) {
        // 0 means "no limit" to NSCache (it still evicts under memory pressure).
        cache.totalCostLimit = costLimit
    }

    func object(forKey key: String) -> CGImageBox? {
        cache.object(forKey: key as NSString)
    }

    func setObject(_ box: CGImageBox, forKey key: String, cost: Int) {
        cache.setObject(box, forKey: key as NSString, cost: cost)
    }
}

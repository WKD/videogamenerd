import Foundation

/// A short-lived, in-memory, per-session cache for IGDB *search* results (PLAN §6.1 /
/// §9, W19). Identical search / autocomplete queries within a session return the
/// previous result without a request, and N identical calls fired while one is still
/// running coalesce onto ONE network operation (in-flight de-duplication) rather than
/// firing N.
///
/// This exists purely to make the app faster and to avoid re-asking IGDB for what we
/// just fetched — never to get around IGDB's rate limit. A miss still runs the caller's
/// `produce` closure, which goes through the client's one `RateLimiter` unchanged; the
/// cache only ever *removes* requests, never adds, parallelises or accelerates them.
///
/// Not persisted: search results go stale and are ranking-dependent, so this lives for
/// the session only (≈15-min TTL, ≈200-query LRU cap). Empty results are cached (with
/// the same short TTL, so a no-hits query does not re-fire); errors and cancellations
/// are never cached.
actor IGDBSearchCache {
    /// Identifies a query: endpoint kind + normalised text + platform filter + limit.
    /// (A release year, when present, is embedded in the autocomplete text, so it is
    /// already part of `text`.)
    struct Key: Hashable, Sendable {
        let kind: String
        let text: String
        let platforms: [Int]
        let limit: Int

        init(kind: String, text: String, platforms: [Int]?, limit: Int) {
            self.kind = kind
            // Normalise: lowercased, whitespace-collapsed, trimmed — so "Bloodborne "
            // and "bloodborne" share one entry (they yield the same IGDB results).
            self.text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            self.platforms = (platforms ?? []).sorted()
            self.limit = limit
        }
    }

    private struct Cached {
        let results: [IGDBSearchResult]
        let expiry: TimeInterval
    }

    private var store: [Key: Cached] = [:]
    private var recency: [Key] = []                                   // LRU: oldest first
    private var inflight: [Key: Task<[IGDBSearchResult], Error>] = [:]
    private let capacity: Int
    private let ttl: TimeInterval
    private let clock: ServiceClock

    init(capacity: Int = 200, ttl: TimeInterval = 15 * 60, clock: ServiceClock = SystemClock()) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
        self.clock = clock
    }

    /// Serve `key` from the cache when fresh, coalesce onto an in-flight twin, or run
    /// `produce` (a network op through the rate limiter) and cache its success.
    /// `force` skips the read and any in-flight join, runs a fresh op, and overwrites
    /// the cached value (explicit "get new data" — PLAN §5.1 refresh/re-match).
    func value(
        for key: Key,
        force: Bool,
        produce: @Sendable @escaping () async throws -> [IGDBSearchResult]
    ) async throws -> [IGDBSearchResult] {
        if !force {
            if let hit = store[key], hit.expiry > clock.now {
                touch(key)
                return hit.results
            }
            if let running = inflight[key] {
                return try await running.value          // coalesce onto the twin in flight
            }
        }

        let task = Task { try await produce() }
        if !force { inflight[key] = task }              // only non-forced calls are joinable
        do {
            let results = try await task.value
            inflight[key] = nil
            insert(key, results)                         // cache success, including empty
            return results
        } catch {
            inflight[key] = nil                          // never cache an error / cancellation
            throw error
        }
    }

    /// Test hook: how many queries are cached right now.
    var cachedCount: Int { store.count }

    // MARK: - LRU bookkeeping

    private func insert(_ key: Key, _ results: [IGDBSearchResult]) {
        store[key] = Cached(results: results, expiry: clock.now + ttl)
        touch(key)
        while store.count > capacity, let evict = recency.first {
            recency.removeFirst()
            store[evict] = nil
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

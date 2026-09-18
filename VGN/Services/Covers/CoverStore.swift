import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// The cover pipeline actor (PLAN §5.2 / §9). Covers are **library assets**, not a
/// cache: originals are filed permanently under `covers/`, grid thumbnails are
/// pre-downsampled under `thumbs/`, decoded images are held in an `NSCache` with a
/// cost limit. Downloads are de-duplicated per game, capped at ≤ 6 concurrent, and
/// cancellation-safe; misses write a 7-day negative-cache sentinel so the grid never
/// re-hits the network every render.
///
/// The UI lane is defining a `CoverLoading` protocol concurrently, so — per the brief
/// — this type does *not* declare that name; the UI calls these methods directly.
actor CoverStore {
    private let chain: CoverProviderChain
    private let transport: HTTPTransport
    private let coversDirectory: URL
    private let thumbsDirectory: URL
    private let clock: ServiceClock
    /// Wall-clock seconds source for the on-disk negative sentinels. Must be
    /// wall-clock (persisted to a file mtime and compared across process launches),
    /// unlike ``clock`` which is monotonic and only valid within one run.
    private let sentinelClock: @Sendable () -> TimeInterval
    private let downloadLimiter: AsyncSemaphore
    private let negativeTTL: TimeInterval

    private let memoryCache = NSCache<NSString, CGImageBox>()
    private var inflightFetch: [Int64: Task<StoredCover?, Error>] = [:]
    private var inflightThumb: [String: Task<CGImageBox?, Never>] = [:]

    /// Thumbnail longest-edge buckets (px). The size slider maps to the nearest bucket
    /// so we never generate an unbounded number of thumbnail variants (PLAN §9).
    static let thumbnailBuckets = [128, 192, 256, 384, 512, 768]

    init(
        chain: CoverProviderChain,
        transport: HTTPTransport = URLSessionTransport(),
        coversDirectory: URL,
        thumbsDirectory: URL,
        clock: ServiceClock = SystemClock(),
        sentinelClock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        maxConcurrentDownloads: Int = 6,
        negativeTTL: TimeInterval = 7 * 24 * 60 * 60,
        memoryCostLimit: Int = 96 * 1024 * 1024
    ) {
        self.chain = chain
        self.transport = transport
        self.coversDirectory = coversDirectory
        self.thumbsDirectory = thumbsDirectory
        self.clock = clock
        self.sentinelClock = sentinelClock
        self.downloadLimiter = AsyncSemaphore(permits: maxConcurrentDownloads)
        self.negativeTTL = negativeTTL
        self.memoryCache.totalCostLimit = memoryCostLimit
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Thumbnails (UI read path)

    /// Decoded, downsampled thumbnail for a stored cover file at (roughly) `pixelSize`.
    /// Returns `nil` if the cover file is missing or unreadable. De-dups concurrent
    /// identical requests and caches the decoded image.
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> sending CGImage? {
        let bucket = Self.bucket(for: pixelSize)
        let key = "\(coverFile)@\(bucket)" as NSString

        if let cached = memoryCache.object(forKey: key) { return cached.image }
        if let inflight = inflightThumb[key as String] { return await inflight.value?.image }

        let task = Task<CGImageBox?, Never> { [self] in
            await makeThumbnail(coverFile: coverFile, bucket: bucket)
        }
        inflightThumb[key as String] = task
        let box = await task.value
        inflightThumb[key as String] = nil
        if let box { memoryCache.setObject(box, forKey: key, cost: box.cost) }
        return box?.image
    }

    private func makeThumbnail(coverFile: String, bucket: Int) async -> CGImageBox? {
        let originalURL = coversDirectory.appendingPathComponent(coverFile)
        guard FileManager.default.fileExists(atPath: originalURL.path) else { return nil }

        let thumbURL = thumbsDirectory.appendingPathComponent(Self.thumbName(coverFile: coverFile, bucket: bucket))
        // Reuse an on-disk thumbnail if present.
        if FileManager.default.fileExists(atPath: thumbURL.path),
           let box = ImageDownsampler.thumbnail(fromFileAt: thumbURL, maxPixelSize: bucket) {
            return box
        }
        guard let box = ImageDownsampler.thumbnail(fromFileAt: originalURL, maxPixelSize: bucket) else {
            return nil
        }
        writePNG(box.image, to: thumbURL)
        return box
    }

    // MARK: - Enrichment (fetch + store)

    /// Run the provider chain, download the best candidate, file it permanently, and
    /// return the stored cover (file name + provider + all candidates). Returns `nil`
    /// when nothing was found (and records a negative sentinel). Concurrent calls for
    /// the same `gameID` share one run/download.
    func fetchAndStoreCover(for query: CoverQuery, gameID: Int64) async throws -> StoredCover? {
        if isNegativeFresh(gameID: gameID) { return nil }
        if let inflight = inflightFetch[gameID] { return try await inflight.value }

        let task = Task<StoredCover?, Error> { [self] in
            try await runFetch(query: query, gameID: gameID)
        }
        inflightFetch[gameID] = task
        defer { inflightFetch[gameID] = nil }
        return try await task.value
    }

    private func runFetch(query: CoverQuery, gameID: Int64) async throws -> StoredCover? {
        let result = await chain.run(query)
        let ordered = orderedCandidates(result)
        guard !ordered.isEmpty else {
            // Providers ran and found nothing → a real miss worth caching. But if a
            // provider could not reach its source (transient), do NOT poison the
            // cache for 7 days over a momentary outage (PLAN §5.2 / §9).
            if !result.hadTransientFailure {
                writeNegativeSentinel(gameID: gameID)
            }
            return nil
        }

        var sawTransientError = false
        for candidate in ordered {
            do {
                let data = try await download(candidate.remoteURL)
                let coverFile = try storeOriginal(data, gameID: gameID, url: candidate.remoteURL)
                clearNegativeSentinel(gameID: gameID)
                return StoredCover(
                    coverFile: coverFile,
                    providerID: candidate.providerID,
                    candidates: result.allCandidates
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let status as HTTPStatusError where status.status == 404 {
                continue   // this candidate is gone; try the next
            } catch {
                sawTransientError = true
                continue
            }
        }
        // Every candidate 404'd → a real miss, poison briefly. A transient failure
        // must NOT poison the cache (PLAN: cancellation/transient errors don't poison).
        if !sawTransientError {
            writeNegativeSentinel(gameID: gameID)
        }
        return nil
    }

    /// Put the confident hit first, then the rest in chain order.
    private func orderedCandidates(_ result: CoverProviderChain.Result) -> [CoverCandidate] {
        guard let best = result.bestConfident else { return result.allCandidates }
        return [best] + result.allCandidates.filter { $0 != best }
    }

    // MARK: - Manual override / removal

    /// Import a user-supplied image file as the cover for a game (manual override /
    /// drag-drop, PLAN §5.2 point 4). Returns the stored cover.
    func importCover(from fileURL: URL, gameID: Int64) throws -> StoredCover {
        let data = try Data(contentsOf: fileURL)
        let coverFile = try storeOriginal(data, gameID: gameID, url: fileURL)
        clearNegativeSentinel(gameID: gameID)
        return StoredCover(coverFile: coverFile, providerID: "manual", candidates: [])
    }

    /// Remove a stored cover original and any thumbnails derived from it.
    func removeCover(_ coverFile: String) {
        try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(coverFile))
        for bucket in Self.thumbnailBuckets {
            let thumbURL = thumbsDirectory.appendingPathComponent(Self.thumbName(coverFile: coverFile, bucket: bucket))
            try? FileManager.default.removeItem(at: thumbURL)
            memoryCache.removeObject(forKey: "\(coverFile)@\(bucket)" as NSString)
        }
    }

    // MARK: - Download

    private func download(_ url: URL) async throws -> Data {
        try await downloadLimiter.withPermit {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("VGN", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await self.transport.data(for: request)
            guard (200...299).contains(response.statusCode) else {
                throw HTTPStatusError(status: response.statusCode, body: data, retryAfter: response.retryAfterSeconds)
            }
            return data
        }
    }

    // MARK: - Storage

    /// File an original permanently as `<gameID>-<hash8>.<ext>` and return the relative
    /// file name the DB stores in `games.cover_file`.
    private func storeOriginal(_ data: Data, gameID: Int64, url: URL) throws -> String {
        let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let ext = Self.fileExtension(for: url, data: data)
        let coverFile = "\(gameID)-\(hash).\(ext)"
        let destination = coversDirectory.appendingPathComponent(coverFile)
        try data.write(to: destination, options: .atomic)
        return coverFile
    }

    // MARK: - Negative sentinels

    private func sentinelURL(gameID: Int64) -> URL {
        coversDirectory.appendingPathComponent("\(gameID).missing")
    }

    private func isNegativeFresh(gameID: Int64) -> Bool {
        let url = sentinelURL(gameID: gameID)
        guard let stamp = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        // Wall-clock comparison: the sentinel's age must survive process restarts
        // (a monotonic clock resets at reboot and would make stale sentinels look
        // forever fresh, permanently suppressing the cover fetch).
        return sentinelClock() - stamp.timeIntervalSince1970 < negativeTTL
    }

    private func writeNegativeSentinel(gameID: Int64) {
        let url = sentinelURL(gameID: gameID)
        try? Data().write(to: url, options: .atomic)
        // Stamp with the wall clock so age is meaningful across launches (tests
        // inject a controllable wall clock to age it deterministically).
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sentinelClock())],
            ofItemAtPath: url.path
        )
    }

    private func clearNegativeSentinel(gameID: Int64) {
        try? FileManager.default.removeItem(at: sentinelURL(gameID: gameID))
    }

    /// Public "forget the miss": drop the negative sentinel for a game so the next
    /// enrichment pass re-runs the provider chain immediately (PLAN §5.2 — the
    /// inspector's "Remove custom cover" must be able to re-fetch at once, without
    /// waiting out the 7-day TTL). Safe to call when no sentinel exists.
    func clearNegativeCache(gameID: Int64) {
        clearNegativeSentinel(gameID: gameID)
    }

    // MARK: - Helpers

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Round a requested pixel size up to the nearest thumbnail bucket (longest edge).
    static func bucket(for pixelSize: CGSize) -> Int {
        let longest = Int(ceil(max(pixelSize.width, pixelSize.height)))
        return thumbnailBuckets.first(where: { $0 >= longest }) ?? (thumbnailBuckets.last ?? 512)
    }

    static func thumbName(coverFile: String, bucket: Int) -> String {
        let base = (coverFile as NSString).deletingPathExtension
        return "\(base)@\(bucket).png"
    }

    static func fileExtension(for url: URL, data: Data) -> String {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "webp"].contains(ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        // Sniff PNG magic; default to jpg (IGDB serves jpg).
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        return "jpg"
    }
}

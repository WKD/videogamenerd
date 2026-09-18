import Foundation

/// Decodes a GitHub git-trees API response.
private struct GitHubTreeResponse: Decodable {
    let tree: [Entry]
    let truncated: Bool
    struct Entry: Decodable {
        let path: String
        let type: String
        let sha: String
    }
}

/// Pure parsing of a GitHub tree JSON into libretro `Named_Boxarts` PNG filenames.
/// Kept free of I/O so it is trivially testable against a recorded fixture.
enum LibretroTreeParser {
    static let boxartPrefix = "Named_Boxarts/"

    struct Parsed: Equatable {
        /// Bare PNG file names inside `Named_Boxarts/` (no directory component).
        var filenames: [String]
        /// GitHub truncated the listing — the caller must walk the subtree by sha.
        var truncated: Bool
        /// SHA of the `Named_Boxarts` tree, when the response listed it (used to walk
        /// the subtree after a truncation).
        var boxartsSHA: String?
    }

    /// Parse a whole-repo tree (paths are repo-relative, e.g.
    /// `Named_Boxarts/Foo (USA).png`).
    static func parse(_ data: Data) throws -> Parsed {
        let response = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)
        var filenames: [String] = []
        var boxartsSHA: String? = nil
        for entry in response.tree {
            if entry.type == "tree", entry.path == "Named_Boxarts" {
                boxartsSHA = entry.sha
            } else if entry.type == "blob",
                      entry.path.hasPrefix(boxartPrefix),
                      entry.path.lowercased().hasSuffix(".png") {
                filenames.append(String(entry.path.dropFirst(boxartPrefix.count)))
            }
        }
        return Parsed(filenames: filenames, truncated: response.truncated, boxartsSHA: boxartsSHA)
    }

    /// Parse a `Named_Boxarts` subtree fetched by its own sha (paths are relative to
    /// that folder, so every PNG blob is a boxart).
    static func parseSubtree(_ data: Data) throws -> Parsed {
        let response = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)
        let files = response.tree
            .filter { $0.type == "blob" && $0.path.lowercased().hasSuffix(".png") }
            .map(\.path)
        return Parsed(filenames: files, truncated: response.truncated, boxartsSHA: nil)
    }
}

/// Fetches (once, then cached) the `Named_Boxarts` filename listing for a libretro
/// repo via the GitHub git-trees API (PLAN §5.2). Disk-caches each listing with an
/// ETag + age so a re-run costs at most one conditional request; refreshes after ~30
/// days; negative-caches failures briefly so a broken repo does not hammer the API.
/// Fails soft: every public path returns `nil` rather than throwing.
actor LibretroRepoListing {
    /// On-disk cache record (one JSON per repo).
    struct Cache: Codable, Sendable {
        var repo: String
        var branch: String
        var etag: String?
        var fetchedAt: Date
        var filenames: [String]
    }

    private let transport: HTTPTransport
    private let rateLimiter: RateLimiter
    private let clock: ServiceClock
    private let cacheDirectory: URL
    private let apiBase: URL
    /// Branch candidates to try, in order (libretro repos are mostly `master`).
    private let branchCandidates: [String]
    private let listingTTL: TimeInterval
    private let negativeTTL: TimeInterval

    /// A resolved repo listing: which branch served it and its box-art filenames.
    struct Listing: Sendable, Equatable {
        var branch: String
        var filenames: [String]
    }

    private var inflight: [String: Task<Listing?, Never>] = [:]
    private var memoryCache: [String: Listing] = [:]
    private var negativeCache: [String: TimeInterval] = [:]

    init(
        transport: HTTPTransport = URLSessionTransport(),
        cacheDirectory: URL,
        rateLimiter: RateLimiter? = nil,
        clock: ServiceClock = SystemClock(),
        apiBase: URL = URL(string: "https://api.github.com")!,
        branchCandidates: [String] = ["master", "main"],
        listingTTL: TimeInterval = 30 * 24 * 60 * 60,
        negativeTTL: TimeInterval = 10 * 60
    ) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        // GitHub unauthenticated is 60 req/s-ish per hour; keep politeness modest.
        self.rateLimiter = rateLimiter ?? RateLimiter(rate: 5, clock: clock)
        self.clock = clock
        self.apiBase = apiBase
        self.branchCandidates = branchCandidates
        self.listingTTL = listingTTL
        self.negativeTTL = negativeTTL
    }

    /// Box-art filenames for a repo, or `nil` if none could be obtained.
    func filenames(repo: String) async -> [String]? {
        await listing(repo: repo)?.filenames
    }

    /// Full listing (branch + filenames) for a repo, or `nil`. Concurrent callers for
    /// the same repo share one fetch.
    func listing(repo: String) async -> Listing? {
        if let cached = memoryCache[repo] { return cached }
        if let inflight = inflight[repo] { return await inflight.value }

        let task = Task<Listing?, Never> { [weak self] in
            await self?.resolve(repo: repo) ?? nil
        }
        inflight[repo] = task
        let result = await task.value
        inflight[repo] = nil
        if let result { memoryCache[repo] = result }
        return result
    }

    // MARK: - Resolution

    private func resolve(repo: String) async -> Listing? {
        let now = clock.now

        // Fresh disk cache?
        if let disk = readCache(repo: repo) {
            if now - disk.fetchedAt.timeIntervalSince1970 < listingTTL {
                return Listing(branch: disk.branch, filenames: disk.filenames)
            }
            // Stale: try a conditional refresh, but keep the stale copy as a fallback.
            if let refreshed = await fetch(repo: repo, knownETag: disk.etag, fallbackBranch: disk.branch) {
                return refreshed
            }
            return Listing(branch: disk.branch, filenames: disk.filenames)
        }

        // Recent failure? Back off briefly.
        if let failedAt = negativeCache[repo], now - failedAt < negativeTTL {
            return nil
        }

        if let fetched = await fetch(repo: repo, knownETag: nil, fallbackBranch: nil) {
            return fetched
        }
        negativeCache[repo] = now
        return nil
    }

    /// Fetch the listing over the network, trying branch candidates and handling
    /// truncation. Returns a listing on success, `nil` on hard failure.
    private func fetch(repo: String, knownETag: String?, fallbackBranch: String?) async -> Listing? {
        let branches: [String]
        if let fallbackBranch {
            branches = [fallbackBranch] + branchCandidates.filter { $0 != fallbackBranch }
        } else {
            branches = branchCandidates
        }
        for branch in branches {
            switch await fetchBranch(repo: repo, branch: branch, knownETag: knownETag) {
            case .success(let filenames, let etag):
                writeCache(Cache(
                    repo: repo,
                    branch: branch,
                    etag: etag,
                    fetchedAt: Date(timeIntervalSince1970: clock.now),
                    filenames: filenames
                ))
                return Listing(branch: branch, filenames: filenames)
            case .notModified:
                // Cache still valid; refresh its stamp and return its filenames.
                if var disk = readCache(repo: repo) {
                    disk.fetchedAt = Date(timeIntervalSince1970: clock.now)
                    writeCache(disk)
                    return Listing(branch: disk.branch, filenames: disk.filenames)
                }
                return nil
            case .notFound:
                continue   // try the next branch
            case .failed:
                return nil
            }
        }
        return nil
    }

    private enum BranchResult {
        case success(filenames: [String], etag: String?)
        case notModified
        case notFound
        case failed
    }

    private func fetchBranch(repo: String, branch: String, knownETag: String?) async -> BranchResult {
        guard let treeData = await get(
            path: "/repos/libretro-thumbnails/\(repo)/git/trees/\(branch)",
            query: [URLQueryItem(name: "recursive", value: "1")],
            etag: knownETag
        ) else { return .failed }

        switch treeData {
        case .notModified:
            return .notModified
        case .notFound:
            return .notFound
        case .ok(let data, let etag):
            guard let parsed = try? LibretroTreeParser.parse(data) else { return .failed }
            if parsed.truncated, let sha = parsed.boxartsSHA {
                // Walk just the Named_Boxarts subtree by sha (smaller, avoids the
                // Snaps/Titles folders that bloat the recursive root listing).
                if let subtree = await getSubtree(repo: repo, sha: sha) {
                    return .success(filenames: subtree, etag: etag)
                }
            }
            return .success(filenames: parsed.filenames, etag: etag)
        }
    }

    private func getSubtree(repo: String, sha: String) async -> [String]? {
        guard let result = await get(
            path: "/repos/libretro-thumbnails/\(repo)/git/trees/\(sha)",
            query: [URLQueryItem(name: "recursive", value: "1")],
            etag: nil
        ), case .ok(let data, _) = result else { return nil }
        return (try? LibretroTreeParser.parseSubtree(data))?.filenames
    }

    private enum GetResult {
        case ok(Data, etag: String?)
        case notModified
        case notFound
    }

    private func get(path: String, query: [URLQueryItem], etag: String?) async -> GetResult? {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VGN", forHTTPHeaderField: "User-Agent")   // GitHub requires one
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        do {
            try await rateLimiter.acquire()
            try Task.checkCancellation()
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200:
                return .ok(data, etag: response.value(forHTTPHeaderField: "Etag"))
            case 304:
                return .notModified
            case 404:
                return .notFound
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - Disk cache

    private func cacheURL(repo: String) -> URL {
        cacheDirectory.appendingPathComponent("\(repo).json")
    }

    private func readCache(repo: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL(repo: repo)) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func writeCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL(repo: cache.repo), options: .atomic)
    }
}

import Foundation
@testable import VGN

// MARK: - Fakes for the PhotoScanEnvironment seams

/// A `ShelfScanning` fake: emits queued/running/done events + per-tile metrics for a
/// configurable tile count, then returns a canned `PhotoScanResult` (or throws / delays
/// for cancellation tests). No process, no network.
final class FakePhotoScanner: ShelfScanning, @unchecked Sendable {
    struct Plan: Sendable {
        var tileCount: Int = 2
        var items: [ScannedItem] = []
        var costPerTile: Double = 0.01
        var error: ClaudeCLIError?
        var delay: Duration?
    }

    private let lock = NSLock()
    var preflightResult: Result<URL, ClaudeCLIError>
    private var plans: [String: Plan] = [:]
    var defaultPlan: Plan
    private var _enginesUsed: [ActiveScanEngine] = []
    private var _preflightCount = 0

    init(
        preflight: Result<URL, ClaudeCLIError> = .success(URL(fileURLWithPath: "/stub/claude")),
        defaultPlan: Plan = Plan()
    ) {
        self.preflightResult = preflight
        self.defaultPlan = defaultPlan
    }

    var enginesUsed: [ActiveScanEngine] { lock.withLock { _enginesUsed } }
    var preflightCount: Int { lock.withLock { _preflightCount } }

    func setPlan(_ plan: Plan, for photoName: String) { lock.withLock { plans[photoName] = plan } }

    func preflight() async throws -> URL {
        lock.withLock { _preflightCount += 1 }
        switch preflightResult {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    func scan(
        photoAt url: URL,
        photoName: String,
        engine: ActiveScanEngine,
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool,
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void,
        onMetrics: @escaping @Sendable (Int, ClaudeRunMetrics) -> Void
    ) async throws -> PhotoScanResult {
        lock.withLock { _enginesUsed.append(engine) }
        let plan = lock.withLock { plans[photoName] ?? defaultPlan }
        for id in 0..<plan.tileCount { onEvent(.queued(tileID: id, total: plan.tileCount)) }
        if let delay = plan.delay { try await Task.sleep(for: delay) }
        for id in 0..<plan.tileCount {
            onEvent(.running(tileID: id))
            onMetrics(id, ClaudeRunMetrics(costUSD: plan.costPerTile))
            onEvent(.done(tileID: id, items: 0))
        }
        if let error = plan.error { throw error }
        let items = plan.items.map { item -> ScannedItem in
            guard let match = item.match else { return item }
            var updated = item
            updated.alreadyInLibrary = isInLibrary(match.igdbID, item.platformSlug)
            return updated
        }
        return PhotoScanResult(photo: photoName, items: items, tileCount: plan.tileCount, failedTileIDs: [])
    }
}

/// A `PhotoScanCommitting` fake: records what it was asked to commit and can be made to
/// fail, so the model's commit flow / summary / rollback signalling can be asserted
/// without a database.
final class FakeCommitter: PhotoScanCommitting, @unchecked Sendable {
    private let lock = NSLock()
    var error: Error?
    var outcomes: [AddOutcome]?
    private var _singles: [GameDraft] = []
    private var _compilations: [ScanCompilationDraft] = []

    var recordedSingles: [GameDraft] { lock.withLock { _singles } }
    var recordedCompilations: [ScanCompilationDraft] { lock.withLock { _compilations } }

    func commit(singles: [GameDraft], compilations: [ScanCompilationDraft]) async throws -> [AddOutcome] {
        lock.withLock { _singles = singles; _compilations = compilations }
        if let error { throw error }
        if let outcomes { return outcomes }
        // Default: every single/member becomes a created game.
        var out: [AddOutcome] = compilations.flatMap { $0.members.enumerated().map { .created(gameID: Int64($0.offset + 100)) } }
        out += singles.enumerated().map { .created(gameID: Int64($0.offset + 1)) }
        return out
    }
}

/// A `PhotoScanSearching` fake.
struct FakeScanSearcher: PhotoScanSearching {
    var results: [IGDBSearchResult] = []
    var members: [IGDBSearchResult] = []
    func search(_ text: String, platformSlug: String?) async throws -> [IGDBSearchResult] { results }
    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult { BundleMemberResult(members: members) }
}

// MARK: - Builders

enum ImportFixtures {
    /// A `ScannedItem`, with its match/bucket derived from `bucket`.
    static func item(
        id: Int,
        photo: String,
        title: String,
        platform: String?,
        igdbID: Int64?,
        bucket: ScanConfidenceBucket,
        alreadyInLibrary: Bool = false,
        compilation: Bool = false,
        x: Int = 1000,
        alternatives: [ScanMatch] = []
    ) -> ScannedItem {
        let score: Double
        switch bucket {
        case .confident: score = 0.95
        case .plausible: score = 0.80
        case .none: score = 0.30
        }
        let match: ScanMatch? = (bucket == .none || igdbID == nil) ? nil : ScanMatch(
            igdbID: igdbID!, name: title, releaseYear: 2020, coverImageID: "cover\(id)",
            platformSlugs: platform.map { [$0] } ?? [], score: score, matchedName: title
        )
        return ScannedItem(
            id: id, sourcePhoto: photo,
            tileRect: SourceRect(x: x, y: 0, width: 120, height: 1200), tileID: 0,
            printedTitle: title, normalizedGuess: nil, platformSlug: platform,
            editionHints: [], isCompilationGuess: compilation, serialCode: nil,
            recognitionConfidence: score, match: match, alternatives: alternatives,
            matchBucket: bucket, alreadyInLibrary: alreadyInLibrary
        )
    }

    static func searchResult(id: Int64, name: String, platform: String? = "ps4", bundle: Bool = false, altNames: [String] = []) -> IGDBSearchResult {
        IGDBSearchResult(
            id: id, name: name, releaseYear: 2021, coverImageID: "c\(id)",
            platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: platform.map { [$0] } ?? [],
            genres: [], alternativeNames: altNames, gameType: bundle ? .bundle : .mainGame
        )
    }

    /// A photo result carrying the given items.
    static func result(photo: String, items: [ScannedItem], tileCount: Int = 2) -> PhotoScanResult {
        PhotoScanResult(photo: photo, items: items, tileCount: tileCount, failedTileIDs: [])
    }
}

// MARK: - Wiring

@MainActor
enum ImportEnv {
    static func make(
        scanner: any ShelfScanning = FakePhotoScanner(),
        committer: any PhotoScanCommitting = FakeCommitter(),
        searcher: any PhotoScanSearching = FakeScanSearcher(),
        preferences: any PhotoScanPreferenceStoring = InMemoryPhotoScanPreferences(),
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool = { _, _ in false },
        onLibraryChanged: @escaping () -> Void = {},
        onQuickAdd: @escaping (String) -> Void = { _ in },
        onShowInLibrary: @escaping (Int64) -> Void = { _ in }
    ) -> PhotoScanEnvironment {
        PhotoScanEnvironment(
            scanner: scanner, committer: committer, searcher: searcher,
            preferences: preferences, isInLibrary: isInLibrary,
            onLibraryChanged: onLibraryChanged, onQuickAdd: onQuickAdd, onShowInLibrary: onShowInLibrary
        )
    }
}

/// Poll `condition` on the main actor until true or `timeout`.
@MainActor
func waitFor(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let start = ContinuousClock.now
    while !condition() {
        if ContinuousClock.now - start > timeout { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

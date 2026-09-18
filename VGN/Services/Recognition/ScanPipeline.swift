import Foundation

/// The end-to-end photo-scan engine (PLAN §6.2): tile → recognise (per tile, isolated)
/// → merge overlap duplicates → match against IGDB → review-sheet items. No DB access;
/// "already in library?" is a caller-supplied closure. No UI.
struct ScanPipeline: Sendable {
    var tiler: ShelfTiler
    var recognizer: ShelfRecognizer
    var searcher: IGDBGameSearching
    var catalog: PlatformCatalog
    var searchLimit: Int
    var tempRoot: URL

    init(
        recognizer: ShelfRecognizer,
        searcher: IGDBGameSearching,
        catalog: PlatformCatalog,
        tiler: ShelfTiler = ShelfTiler(),
        searchLimit: Int = 12,
        tempRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.recognizer = recognizer
        self.searcher = searcher
        self.catalog = catalog
        self.tiler = tiler
        self.searchLimit = searchLimit
        self.tempRoot = tempRoot
    }

    /// Scan one photo. `isInLibrary(igdbID, platformSlug)` lets the caller grey out
    /// duplicates without giving the pipeline DB access.
    func scan(
        photoAt url: URL,
        photoName: String,
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool = { _, _ in false },
        onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void = { _ in }
    ) async throws -> PhotoScanResult {
        let dir = tempRoot.appendingPathComponent("vgn-scan-\(photoName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tiles = try tiler.tile(imageAt: url, into: dir, basename: photoName)

        let failed = FailedTiles()
        let detections = await recognizer.recognize(tiles: tiles) { event in
            if case .failed(let id, _) = event { failed.add(id) }
            onEvent(event)
        }

        let merged = ScanMerge.merge(detections)
        var items = [ScannedItem]()
        items.reserveCapacity(merged.count)
        for (index, detection) in merged.enumerated() {
            let outcome = await match(detection)
            let already = outcome.best.map { isInLibrary($0.igdbID, detection.platform) } ?? false
            items.append(scannedItem(index: index, photo: photoName, detection: detection, outcome: outcome, alreadyInLibrary: already))
        }

        return PhotoScanResult(photo: photoName, items: items, tileCount: tiles.count, failedTileIDs: failed.snapshot())
    }

    /// Recognise + merge + match a set of already-cut tiles (used by the accuracy
    /// harness, which owns tiling so it can report per-tile timing).
    func matchDetections(
        _ merged: [MergedDetection],
        photo: String,
        isInLibrary: @escaping @Sendable (Int64, String?) -> Bool = { _, _ in false }
    ) async -> [ScannedItem] {
        var items = [ScannedItem]()
        for (index, detection) in merged.enumerated() {
            let outcome = await match(detection)
            let already = outcome.best.map { isInLibrary($0.igdbID, detection.platform) } ?? false
            items.append(scannedItem(index: index, photo: photo, detection: detection, outcome: outcome, alreadyInLibrary: already))
        }
        return items
    }

    // MARK: - Matching

    /// Match one merged detection: platform-constrained IGDB search across the query
    /// ladder, falling back to unconstrained when constrained finds nothing, then
    /// fuzzy-score with `ScanMatching`.
    func match(_ detection: MergedDetection) async -> ScanMatchOutcome {
        let platformIDs = detection.platform.flatMap { catalog.entry(forSlug: $0)?.igdbIDs }
        let queries = ScanMatching.queries(printedTitle: detection.printedTitle, normalizedGuess: detection.normalizedTitle)

        var candidates = await search(queries: queries, platformIGDBIDs: platformIDs)
        if candidates.isEmpty, platformIDs != nil {
            candidates = await search(queries: queries, platformIGDBIDs: nil)   // platform fallback
        }
        return ScanMatching.rank(
            printedTitle: detection.printedTitle,
            normalizedGuess: detection.normalizedTitle,
            platformSlug: detection.platform,
            candidates: candidates
        )
    }

    private func search(queries: [String], platformIGDBIDs: [Int]?) async -> [IGDBSearchResult] {
        var out: [IGDBSearchResult] = []
        var seen = Set<Int64>()
        for query in queries {
            let results = (try? await searcher.searchGames(query, platformIGDBIDs: platformIGDBIDs, limit: searchLimit)) ?? []
            for result in results where seen.insert(result.id).inserted { out.append(result) }
        }
        return out
    }

    private func scannedItem(
        index: Int,
        photo: String,
        detection: MergedDetection,
        outcome: ScanMatchOutcome,
        alreadyInLibrary: Bool
    ) -> ScannedItem {
        ScannedItem(
            id: index,
            sourcePhoto: photo,
            tileRect: detection.sourceRect,
            tileID: detection.tileID,
            printedTitle: detection.printedTitle,
            normalizedGuess: detection.normalizedTitle,
            platformSlug: detection.platform,
            editionHints: detection.editionHints,
            isCompilationGuess: detection.isCompilation,
            serialCode: detection.serialCode,
            recognitionConfidence: detection.confidence,
            match: outcome.best,
            alternatives: outcome.alternatives,
            matchBucket: outcome.bucket,
            alreadyInLibrary: alreadyInLibrary
        )
    }
}

/// Thread-safe collector for failed tile ids during a run.
private final class FailedTiles: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    func add(_ id: Int) { lock.withLock { _ = ids.insert(id) } }
    func snapshot() -> [Int] { lock.withLock { ids.sorted() } }
}

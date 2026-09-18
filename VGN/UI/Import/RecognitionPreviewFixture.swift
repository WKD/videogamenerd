#if DEBUG
import Foundation

/// Recorded/synthesised photo-scan results for the review-sheet, progress and settings
/// previews (PLAN §6.2). Synthesised from the owner-verified accuracy report
/// (`docs/recognition-accuracy.md`, IMG_3684): its confident matches, one French spine
/// (Les Chevaliers de Baphomet → Broken Sword), and the edge-cut fragments that land in
/// the "no match" bucket. No live Claude/IGDB calls.
@MainActor
enum PhotoScanPreview {

    static func reviewModel() -> PhotoScanModel {
        let model = environment().makeModel()
        model.previewSeedReview([sampleResult()])
        return model
    }

    static func runningModel() -> PhotoScanModel {
        let model = environment().makeModel()
        var job1 = PhotoScanJob(url: URL(fileURLWithPath: "/tmp/IMG_3684.jpg"))
        job1.phase = .recognizing
        job1.tileTotal = 8
        job1.startedAt = Date().addingTimeInterval(-40)
        job1.costUSD = 0.12
        job1.tiles = (0..<8).map { id in
            ScanTileProgress(id: id, state: id < 5 ? .done(items: 3) : (id == 5 ? .running : .queued))
        }
        var job2 = PhotoScanJob(url: URL(fileURLWithPath: "/tmp/IMG_3687.jpg"))
        job2.phase = .queued
        job2.tileTotal = 8
        model.previewSeedRunning([job1, job2], engine: .claude)
        return model
    }

    nonisolated static func sampleResult() -> PhotoScanResult {
        var items: [ScannedItem] = []
        func add(_ title: String, platform: String?, igdbID: Int64?, bucket: ScanConfidenceBucket,
                 printed: String? = nil, compilation: Bool = false, already: Bool = false, hints: [String] = []) {
            let x = 300 + items.count * 340
            let score: Double = bucket == .confident ? 0.96 : (bucket == .plausible ? 0.79 : 0.3)
            let match: ScanMatch? = (bucket == .none || igdbID == nil) ? nil : ScanMatch(
                igdbID: igdbID!, name: title, releaseYear: 2011, coverImageID: "co\(igdbID!)",
                platformSlugs: platform.map { [$0] } ?? [], score: score, matchedName: title)
            items.append(ScannedItem(
                id: items.count, sourcePhoto: "IMG_3684",
                tileRect: SourceRect(x: x, y: 400, width: 300, height: 2600), tileID: items.count / 3,
                printedTitle: printed ?? title, normalizedGuess: nil, platformSlug: platform,
                editionHints: hints, isCompilationGuess: compilation, serialCode: nil,
                recognitionConfidence: score, match: match, alternatives: [], matchBucket: bucket,
                alreadyInLibrary: already))
        }
        add("God of War III", platform: "ps3", igdbID: 1, bucket: .confident)
        add("The Last of Us", platform: "ps3", igdbID: 2, bucket: .confident)
        add("Uncharted 3: Drake's Deception", platform: "ps3", igdbID: 3, bucket: .confident, hints: ["GOTY"])
        add("Red Dead Redemption", platform: "xbox360", igdbID: 4, bucket: .confident)
        add("Halo 3", platform: "xbox360", igdbID: 5, bucket: .confident, already: true)
        add("Broken Sword", platform: "ps3", igdbID: 6, bucket: .plausible, printed: "Les Chevaliers de Baphomet")
        add("Ni no Kuni", platform: "ps3", igdbID: 7, bucket: .plausible)
        add("God of W…", platform: "ps3", igdbID: nil, bucket: .none)
        add("Tomb Raider", platform: "ps3", igdbID: nil, bucket: .none)
        add("DA…", platform: nil, igdbID: nil, bucket: .none)
        return PhotoScanResult(photo: "IMG_3684", items: items, tileCount: 8, failedTileIDs: [])
    }

    static func environment() -> PhotoScanEnvironment {
        PhotoScanEnvironment(
            scanner: PreviewScanner(),
            committer: PreviewCommitter(),
            searcher: PreviewSearcher(),
            preferences: InMemoryPhotoScanPreferences()
        )
    }
}

// MARK: - Preview stubs (app-target visible)

private struct PreviewScanner: ShelfScanning {
    func preflight() async throws -> URL { URL(fileURLWithPath: "/usr/local/bin/claude") }
    func scan(photoAt url: URL, photoName: String, engine: ActiveScanEngine,
              isInLibrary: @escaping @Sendable (Int64, String?) -> Bool,
              onEvent: @escaping @Sendable (ShelfRecognitionEvent) -> Void,
              onMetrics: @escaping @Sendable (Int, ClaudeRunMetrics) -> Void) async throws -> PhotoScanResult {
        PhotoScanPreview.sampleResult()
    }
}

private struct PreviewCommitter: PhotoScanCommitting {
    func commit(singles: [GameDraft], compilations: [ScanCompilationDraft]) async throws -> [AddOutcome] {
        singles.enumerated().map { .created(gameID: Int64($0.offset + 1)) }
    }
}

private struct PreviewSearcher: PhotoScanSearching {
    func search(_ text: String, platformSlug: String?) async throws -> [IGDBSearchResult] { [] }
    func bundleMembers(bundleIGDBID: Int64) async throws -> [IGDBSearchResult] { [] }
}
#endif

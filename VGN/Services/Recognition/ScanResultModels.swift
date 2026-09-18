import Foundation

/// Everything the review sheet needs for one scanned spine (PLAN §6.2 step 5): where
/// it is on the photo, what was read, the IGDB match + alternatives, platform, edition
/// / compilation hints, confidence, and the default owned/physical flags.
struct ScannedItem: Sendable, Identifiable, Equatable {
    let id: Int
    /// Source photo name (e.g. "IMG_3687").
    var sourcePhoto: String
    /// Where the spine sits on the source photo (for the review-sheet overlay).
    var tileRect: SourceRect
    /// The tile this came from.
    var tileID: Int

    // What was read
    var printedTitle: String
    var normalizedGuess: String?
    var platformSlug: String?
    var editionHints: [String]
    var isCompilationGuess: Bool
    var serialCode: SpineSerialCode?
    /// Recognition confidence (0…1) from the engine.
    var recognitionConfidence: Double

    // Match
    var match: ScanMatch?
    var alternatives: [ScanMatch]
    var matchBucket: ScanConfidenceBucket
    /// Whether the matched game+platform is already in the library (caller-supplied).
    var alreadyInLibrary: Bool

    // Defaults for the review sheet (it's on my shelf).
    var owned: Bool
    var physical: Bool

    init(
        id: Int,
        sourcePhoto: String,
        tileRect: SourceRect,
        tileID: Int,
        printedTitle: String,
        normalizedGuess: String?,
        platformSlug: String?,
        editionHints: [String],
        isCompilationGuess: Bool,
        serialCode: SpineSerialCode?,
        recognitionConfidence: Double,
        match: ScanMatch?,
        alternatives: [ScanMatch],
        matchBucket: ScanConfidenceBucket,
        alreadyInLibrary: Bool,
        owned: Bool = true,
        physical: Bool = true
    ) {
        self.id = id
        self.sourcePhoto = sourcePhoto
        self.tileRect = tileRect
        self.tileID = tileID
        self.printedTitle = printedTitle
        self.normalizedGuess = normalizedGuess
        self.platformSlug = platformSlug
        self.editionHints = editionHints
        self.isCompilationGuess = isCompilationGuess
        self.serialCode = serialCode
        self.recognitionConfidence = recognitionConfidence
        self.match = match
        self.alternatives = alternatives
        self.matchBucket = matchBucket
        self.alreadyInLibrary = alreadyInLibrary
        self.owned = owned
        self.physical = physical
    }
}

/// The result of scanning one photo: the items plus a little run metadata for the
/// progress UI / accuracy report.
struct PhotoScanResult: Sendable, Equatable {
    var photo: String
    var items: [ScannedItem]
    var tileCount: Int
    var failedTileIDs: [Int]
}

/// The IGDB search seam the pipeline depends on (so it is testable with a stub and the
/// accuracy harness can supply an inline searcher). `IGDBClient` conforms directly.
protocol IGDBGameSearching: Sendable {
    func searchGames(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult]
}

extension IGDBClient: IGDBGameSearching {}

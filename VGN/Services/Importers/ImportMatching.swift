import Foundation

/// One title to match against the library (PLAN §14.3). The `releaseYear` is the
/// tie-breaker the IGDB autocomplete already supports (`release_dates.y`).
struct ImportMatchRequest: Sendable, Equatable {
    var title: String
    var platformSlug: String?
    var releaseYear: Int?
}

/// The photo-scan matching ladder, abstracted so the coordinator's tests use a fake
/// and never touch IGDB (PLAN §14.3 / §14.4). The production implementation
/// (``IGDBImportMatcher``) reuses the exact ladder the photo scan uses: platform-
/// constrained IGDB autocomplete → ``ScanMatching`` fuzzy buckets → alternatives.
protocol ImportMatcher: Sendable {
    func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome
}

/// Production matcher: runs the platform-constrained IGDB autocomplete used by Quick
/// Add and the photo scan, then the pure ``ScanMatching`` ranker. The slug → IGDB-ids
/// resolver is injected (the wiring lane builds it from the platform store), so this
/// file stays free of any DB dependency.
struct IGDBImportMatcher: ImportMatcher {
    let client: IGDBClient
    /// Maps a VGN platform slug (`pc` / `mac`) to its IGDB platform ids.
    let platformIGDBIDs: @Sendable (String) -> [Int]

    init(client: IGDBClient, platformIGDBIDs: @Sendable @escaping (String) -> [Int]) {
        self.client = client
        self.platformIGDBIDs = platformIGDBIDs
    }

    func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
        let ids = request.platformSlug.map(platformIGDBIDs) ?? []
        // The autocomplete parses a trailing year, so pass "Title YYYY" as the tie-breaker.
        let query = request.releaseYear.map { "\(request.title) \($0)" } ?? request.title
        let candidates = try await client.autocomplete(query, platformIGDBIDs: ids.isEmpty ? nil : ids)
        return ScanMatching.rank(
            printedTitle: request.title, normalizedGuess: nil,
            platformSlug: request.platformSlug, candidates: candidates)
    }
}

/// A matcher that finds nothing — the safe default when IGDB is not configured, so a
/// sync still stages every title for manual review.
struct NoMatchImportMatcher: ImportMatcher {
    func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
        ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
    }
}

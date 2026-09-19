import Foundation

/// Ties the frail HLTB search (``HLTBSearching``) to the pure ``HLTBMatcher``
/// (PLAN §5.3): search a title, then decide confident / ambiguous / not-found. The
/// DB write is separate (``LibraryStore/applyHLTBTimes(gameID:candidate:)``) so the
/// ambiguous flow can pause for the user's pick. `Sendable`; the search actor does
/// all the I/O.
struct HLTBFillService: Sendable {
    let search: any HLTBSearching

    init(search: any HLTBSearching) { self.search = search }

    /// Search + match for one game. Throws ``ImportError`` on the first unexpected
    /// response (the caller stops the run and surfaces it).
    func resolve(title: String, year: Int?) async throws -> HLTBMatchOutcome {
        let candidates = try await search.search(title: title)
        return HLTBMatcher.match(title: title, year: year, candidates: candidates)
    }
}

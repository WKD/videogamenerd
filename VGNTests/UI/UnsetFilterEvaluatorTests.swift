import Testing
@testable import VGN

/// The in-memory filter evaluator (`LibraryFilterEvaluator`, used by
/// `PreviewLibraryDataSource`) mirrors the SQL for the "Unrated" / "Not Played" /
/// "No Status" / "Not Owned" facets: OR within a kind, AND across kinds.
struct UnsetFilterEvaluatorTests {
    // A tiny fixed library covering the played/tier/status/owned cross-product.
    private let games: [GameSummary] = [
        // played, tier S, finished, owned.
        GameSummary(id: 1, title: "Ranked",     tierID: 1, played: true, owned: true, status: .finished),
        // played, no tier, no status, owned  → Unrated, No Status.
        GameSummary(id: 2, title: "Unrated",    tierID: nil, played: true, owned: true, status: nil),
        // not played, no tier, no status, owned → Not Played (a backlog game).
        GameSummary(id: 3, title: "Backlog",    tierID: nil, played: false, owned: true, status: nil),
        // played, no tier, completed, NOT owned → Unrated, Not Owned.
        GameSummary(id: 4, title: "PlayedOnly", tierID: nil, played: true, owned: false, status: .completed),
    ]

    private func titles(_ filter: LibraryFilter) -> Set<String> {
        Set(LibraryFilterEvaluator.apply(filter, to: games).map(\.title))
    }

    @Test func unratedIsPlayedAndUntiered() {
        #expect(titles(LibraryFilter(includeUnrated: true)) == ["Unrated", "PlayedOnly"])
    }

    @Test func unratedORsWithSelectedTiers() {
        #expect(titles(LibraryFilter(tierIDs: [1], includeUnrated: true)) ==
                ["Ranked", "Unrated", "PlayedOnly"])
    }

    @Test func notPlayedMatchesOnlyUnplayed() {
        #expect(titles(LibraryFilter(includeNotPlayed: true)) == ["Backlog"])
    }

    @Test func noStatusIsPlayedButStatusLess() {
        // "Backlog" also has no status but is not played, so it is excluded here.
        #expect(titles(LibraryFilter(includeNoStatus: true)) == ["Unrated"])
    }

    @Test func completionFacetORsStatusesNotPlayedAndNoStatus() {
        #expect(titles(LibraryFilter(statuses: [.finished], includeNotPlayed: true, includeNoStatus: true)) ==
                ["Ranked", "Backlog", "Unrated"])
    }

    @Test func notOwnedMatchesOnlyUnowned() {
        #expect(titles(LibraryFilter(includeNotOwned: true)) == ["PlayedOnly"])
    }

    @Test func facetsANDAcrossKinds() {
        // Unrated AND Not Owned = the intersection (played, untiered, unowned).
        #expect(titles(LibraryFilter(includeUnrated: true, includeNotOwned: true)) == ["PlayedOnly"])
    }

    @Test func noConstraintWhenAllOff() {
        #expect(titles(LibraryFilter(scope: .all)).count == games.count)
    }
}

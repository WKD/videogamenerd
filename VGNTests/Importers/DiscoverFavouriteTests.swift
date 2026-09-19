import Foundation
import Testing
@testable import VGN

/// Pinned favourites in the Batocera "Discover" row (PLAN §15): a never-played ★ favourite is
/// pinned at the head, ordered among favourites by taste, exempt from the weekly rotation
/// jitter, capped at "half the visible cards", carries the "★ your favourite" reason first, and
/// still obeys "Not Interested". Pure scorer — no DB.
struct DiscoverFavouriteTests {

    private func mkRanked(_ id: Int64, score: Double, traits: [GameTrait]) -> RankedGame {
        RankedGame(id: id, igdbID: nil, score: score, traits: traits)
    }

    private func entry(_ id: Int64, name: String, system: String = "snes", genre: String? = nil,
                       rating: Double? = nil, favourite: Bool = false) -> RomCatalogEntry {
        RomCatalogEntry(id: id, source: "batocera", system: system, platformID: system,
                        relativePath: "./\(name).zip", name: name,
                        genre: genre, rating: rating, isFavorite: favourite)
    }

    /// A neutral library so scores sit near the mean and the crowd rating can dominate.
    private func neutralLibrary() -> [RankedGame] {
        (0..<10).map { mkRanked(Int64($0 + 1), score: 0.5, traits: [GameTrait(kind: .keyword, value: "misc")]) }
    }

    @Test func favouriteIsPinnedAheadOfAHigherScoringNonFavourite() {
        let ranked = neutralLibrary()
        // A plain game the crowd loves vs a favourite the crowd is lukewarm on.
        let star = entry(1, name: "MyPick", genre: "Platform", rating: 0.4, favourite: true)
        let loud = entry(2, name: "CrowdHit", genre: "Platform", rating: 0.99)
        let scored = DiscoverScorer.score(entries: [star, loud], ranked: ranked)
        #expect(scored.first?.entry.id == star.id, "the favourite is pinned above the higher-scoring game")
    }

    @Test func atMostHalfTheVisibleCardsArePinned() {
        let ranked = neutralLibrary()
        // Four favourites + two plain games; cap = 2 pinned.
        let favs = (1...4).map { entry(Int64($0), name: "Fav\($0)", genre: "Platform",
                                       rating: Double($0) / 10, favourite: true) }
        let plain = [entry(10, name: "P1", genre: "Platform", rating: 0.95),
                     entry(11, name: "P2", genre: "Platform", rating: 0.9)]
        let scored = DiscoverScorer.score(entries: favs + plain, ranked: ranked,
                                          options: .init(seed: 0, maxPinnedFavourites: 2))
        // The first two are favourites (pinned, best taste first); position 3+ mixes the
        // remaining favourites with the plain games by score — not all favourites up front.
        let head = Array(scored.prefix(2))
        #expect(head.allSatisfy { $0.entry.isFavorite })
        #expect(!scored[2].entry.isFavorite || !scored[3].entry.isFavorite,
                "beyond the cap, favourites compete like anything else")
    }

    @Test func pinnedFavouritesLeadWithTheFavouriteReason() {
        let ranked = neutralLibrary()
        let star = entry(1, name: "MyPick", genre: "Platform", favourite: true)
        let scored = DiscoverScorer.score(entries: [star], ranked: ranked)
        #expect(scored.first?.reasons.first == .batoceraFavouritePinned)
        #expect(PlayNextReasonFormatter.sentence(for: .batoceraFavouritePinned, exemplars: [:],
                                                 bracket: TimeBracket(shelf: .evening)) == "★ your favourite")
    }

    @Test func favouritesAreExemptFromRotation() {
        let ranked = neutralLibrary()
        // Two favourites with slightly different taste (genre affinity) so they have a stable
        // taste order; a non-favourite twin pair that rotation can swap.
        let favA = entry(1, name: "FavA", genre: "Platform", rating: 0.6, favourite: true)
        let favB = entry(2, name: "FavB", genre: "Platform", rating: 0.5, favourite: true)
        var favOrders = Set<[Int64]>()
        for seed: UInt64 in 0..<40 {
            let scored = DiscoverScorer.score(entries: [favA, favB], ranked: ranked,
                                              options: .init(seed: seed))
            favOrders.insert(scored.map(\.entry.id))
        }
        #expect(favOrders.count == 1, "favourite order never changes with the rotation seed")
    }

    @Test func notInterestedFavouriteIsExcluded() {
        let ranked = neutralLibrary()
        var hidden = entry(1, name: "Hidden", genre: "Platform", favourite: true)
        hidden.notInterested = true
        let visible = entry(2, name: "Visible", genre: "Platform", favourite: true)
        let scored = DiscoverScorer.score(entries: [hidden, visible], ranked: ranked)
        #expect(scored.map(\.entry.id) == [visible.id])
    }
}

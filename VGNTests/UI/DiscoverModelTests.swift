import Foundation
import Testing
@testable import VGN

/// The Discover row model (PLAN §15): visibility rules (hidden with no ranked games / empty
/// pool), loading + scoring through a fake backend, and "Not Interested" removing a card.
@MainActor
@Suite(.serialized)
struct DiscoverModelTests {

    private func entry(_ id: Int64, name: String, genre: String) -> RomCatalogEntry {
        RomCatalogEntry(id: id, source: "batocera", system: "snes", platformID: "snes",
                        relativePath: "./\(name).zip", name: name, genre: genre)
    }
    private func ranked(_ id: Int64) -> RankedGame {
        RankedGame(id: id, igdbID: nil, score: 0.8, traits: [GameTrait(kind: .genre, value: "Platform")])
    }

    @Test(.timeLimit(.minutes(1)))
    func hiddenWhenNoRankedGames() async {
        let backend = FakeDiscoverBackend(ranked: [], pool: [entry(1, name: "A", genre: "Platform")])
        let model = DiscoverModel(backend: backend)
        model.load()
        await waitUntil { model.hasLoaded }
        #expect(model.isVisible == false)
        #expect(model.rankedCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func hiddenWhenPoolEmpty() async {
        let backend = FakeDiscoverBackend(ranked: [ranked(1)], pool: [])
        let model = DiscoverModel(backend: backend)
        model.load()
        await waitUntil { model.hasLoaded }
        #expect(model.isVisible == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func visibleWithRankedAndPool() async {
        let pool = (1...5).map { entry(Int64($0), name: "Game\($0)", genre: "Platform") }
        let backend = FakeDiscoverBackend(ranked: (1...10).map(ranked), pool: pool)
        let model = DiscoverModel(backend: backend, cardCount: 3)
        model.load()
        await waitUntil { model.hasLoaded && !model.items.isEmpty }
        #expect(model.isVisible)
        #expect(model.items.count == 3)          // capped to cardCount
        #expect(model.rankedCount == 10)
    }

    @Test(.timeLimit(.minutes(1)))
    func notInterestedRemovesCardAndCallsBackend() async {
        let pool = (1...4).map { entry(Int64($0), name: "Game\($0)", genre: "Platform") }
        let backend = FakeDiscoverBackend(ranked: (1...10).map(ranked), pool: pool)
        let model = DiscoverModel(backend: backend)
        model.load()
        await waitUntil { model.hasLoaded && !model.items.isEmpty }
        let victim = model.items.first!.entry
        model.notInterested(victim)
        #expect(!model.items.contains { $0.entry.id == victim.id })
        await waitUntil { !backend.notInterestedCalls.isEmpty }
        #expect(backend.notInterestedCalls.contains(victim.id))
    }
}

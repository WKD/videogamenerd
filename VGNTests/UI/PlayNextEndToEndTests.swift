import Foundation
import Testing
@testable import VGN

/// End-to-end (PLAN §7b): persist a slice of the recorded 12-game IGDB corpus into
/// an in-memory database with a hand-written FromSoftware/action-fan ranking, drive
/// the live ``PlayNextModel`` over ``LivePlayNextBackend``, and assert the hero and
/// its reason sentences are sensible. `@MainActor`, serialized, hard-timeout.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PlayNextEndToEndTests {

    // Tier ids from the seed: S=1, A=2, B=3, C=4, D=5, F=6.

    private func corpus() async throws -> [String: IGDBGameMetadata] {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200, body: Data(#"{"access_token":"t","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data("igdb-games-corpus.json")))
        let client = IGDBClient(transport: transport,
                                credentials: { IGDBCredentials(clientID: "c", secret: "s") },
                                catalog: TestCatalog.catalog)
        let games = try await client.games(ids: [7334])
        return Dictionary(uniqueKeysWithValues: games.map { ($0.name, $0) })
    }

    @Test func heroAndSentencesAreSensible() async throws {
        let corpus = try await corpus()
        func meta(_ name: String) throws -> IGDBGameMetadata { try #require(corpus[name]) }

        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)

        // Persist a corpus game with a chosen role.
        @discardableResult
        func add(_ name: String, tier: Int64? = nil, owned: Bool = false,
                 estimateHours: Double? = nil, platform: String = "ps4") async throws -> Int64 {
            let m = try meta(name)
            let id = try await lib.addGame(GameDraft(
                title: m.name, igdbID: m.id, year: m.releaseYear,
                platformIDs: [platform], owned: owned, played: tier != nil, tierID: tier,
                format: .digital)).gameID
            try await lib.updateMetadata(gameID: id, MetadataPatch(
                genres: m.genres,
                ttbNormallyS: estimateHours.map { Int($0 * 3600) },
                traits: m.traits,
                igdbRating: m.igdbRating, igdbRatingCount: m.igdbRatingCount))
            return id
        }

        // A FromSoftware / action fan's tier list: both Souls games top the chart,
        // everything else sits clearly lower — a strong, consistent taste signal.
        _ = try await add("Bloodborne", tier: 1)               // S
        _ = try await add("Dark Souls III", tier: 1)           // S
        _ = try await add("Uncharted 4: A Thief's End", tier: 3)   // B
        _ = try await add("The Last of Us", tier: 3, platform: "ps4")
        _ = try await add("Yakuza 0", tier: 4)                 // C
        _ = try await add("Persona 5", tier: 4)
        _ = try await add("Heavy Rain", tier: 6)               // F — didn't click

        // Unplayed, owned backlog (candidates). Elden Ring is the FromSoftware one.
        let elden = try await add("Elden Ring", owned: true, estimateHours: 53, platform: "ps5")
        _ = try await add("Hollow Knight", owned: true, estimateHours: 45, platform: "pc")
        _ = try await add("Super Mario Odyssey", owned: true, estimateHours: 45, platform: "ps4")
        _ = try await add("Resident Evil 2", owned: true, estimateHours: 42, platform: "ps4")

        // Drive the live model.
        let backend = LivePlayNextBackend(recommendation: RecommendationStore(db), library: lib)
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: UserDefaults(suiteName: "playnext.e2e.\(UUID())")!,
                                  recomputeDebounce: .milliseconds(1))
        model.selectPreset(.longHaul)
        await model.start()

        let deadline = ContinuousClock.now + .seconds(5)
        while model.result?.hero == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let hero = try #require(model.result?.hero)
        #expect(hero.id == elden)                              // the FromSoftware backlog game is crowned

        // Its reasons cite a FromSoftware signal, and the sentences render it.
        let sentences = model.reasonSentences(for: hero)
        #expect(!sentences.isEmpty)
        let citesFromSoft = sentences.contains {
            $0.contains("FromSoftware") || $0.contains("Bloodborne") || $0.contains("Dark Souls")
        }
        #expect(citesFromSoft, "reasons should cite a FromSoftware exemplar; got \(sentences)")
        #expect(sentences.count <= 3)

        // The second-opinion request built from this result carries the tier list.
        let request = try await backend.secondOpinionRequest(for: model.result!)
        #expect(request.topRanked.contains { $0.title == "Bloodborne" })
        #expect(request.shortlist.contains { $0.id == elden })
    }
}

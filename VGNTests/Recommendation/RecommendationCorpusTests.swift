import Foundation
import Testing
@testable import VGN

/// The engine on the recorded real-games corpus (`igdb-games-corpus.json`) with a
/// hand-written, plausible ranking (a FromSoftware / action fan). Sanity: the
/// unplayed FromSoftware game is crowned and the reasons cite the right exemplars.
struct RecommendationCorpusTests {

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

    private func rankedGame(_ meta: IGDBGameMetadata, score: Double) -> RankedGame {
        RankedGame(id: meta.id, igdbID: meta.id, score: score, traits: meta.traits)
    }

    private func candidate(_ meta: IGDBGameMetadata, estimateHours: Double) -> Candidate {
        Candidate(id: meta.id, igdbID: meta.id, traits: meta.traits,
                  estimateSeconds: Int(estimateHours * 3600),
                  status: .backlog, igdbRating: meta.igdbRating, ratingCount: meta.igdbRatingCount,
                  hasMetadata: true, title: meta.name)
    }

    @Test func fromSoftwareFanGetsEldenRing() async throws {
        let c = try await corpus()
        func meta(_ name: String) throws -> IGDBGameMetadata { try #require(c[name]) }

        // A FromSoftware / action fan's plausible ranking (played games).
        let ranked: [RankedGame] = [
            rankedGame(try meta("Bloodborne"), score: 0.97),
            rankedGame(try meta("Dark Souls III"), score: 0.92),
            rankedGame(try meta("Uncharted 4: A Thief's End"), score: 0.80),
            rankedGame(try meta("The Last of Us"), score: 0.78),
            rankedGame(try meta("Yakuza 0"), score: 0.62),
            rankedGame(try meta("Final Fantasy X"), score: 0.55),
            rankedGame(try meta("Persona 5"), score: 0.50),
            rankedGame(try meta("Heavy Rain"), score: 0.12),   // didn't click
        ]
        // Unplayed backlog (candidates). Elden Ring is FromSoftware; the others aren't.
        let candidates: [Candidate] = [
            candidate(try meta("Elden Ring"), estimateHours: 53),
            candidate(try meta("Hollow Knight"), estimateHours: 45),
            candidate(try meta("Super Mario Odyssey"), estimateHours: 45),
            candidate(try meta("Resident Evil 2"), estimateHours: 42),
        ]
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: TimeBracket(shelf: .epic),
            options: RecommendationOptions(seed: 0)))

        let elden = try meta("Elden Ring")
        #expect(result.hero?.id == elden.id)

        // Reasons cite a FromSoftware signal — either the developer link/affinity or
        // a similar-games link to a souls exemplar (Bloodborne / Dark Souls III).
        let reasons = try #require(result.hero?.reasons)
        let bloodborne = try meta("Bloodborne").id
        let darkSouls = try meta("Dark Souls III").id
        let citesFrom = reasons.contains {
            switch $0 {
            case let .sameDeveloper(name, _): return name == "FromSoftware"
            case let .traitAffinity(kind, value, lift): return kind == .developer && value == "FromSoftware" && lift > 0
            case let .similarTo(id): return id == bloodborne || id == darkSouls
            default: return false
            }
        }
        #expect(citesFrom)
    }
}

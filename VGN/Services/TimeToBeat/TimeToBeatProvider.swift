import Foundation

/// Average completion times for a game, in seconds (PLAN §5.3 / §6.4). Any field may
/// be absent when the source has no data.
struct TimeToBeat: Sendable, Equatable {
    /// The provider's own game id (IGDB id for the IGDB provider).
    var gameID: Int64
    var hastily: Int?
    var normally: Int?
    var completely: Int?
    /// Number of submissions behind the averages, when the source exposes it.
    var count: Int?
    /// A short source tag for the UI ("igdb", "hltb").
    var source: String
}

/// PLAN §5.3: the seam behind which IGDB time-to-beat is the default and an
/// experimental HLTB provider *could* live later (out of scope this run). Providers
/// fail soft: they return what they have and never block the app.
protocol TimeToBeatProvider: Sendable {
    /// A short identifier for the provider ("igdb").
    var id: String { get }
    /// Batched lookup by game id. Missing ids simply do not appear in the result.
    func times(forGameIDs ids: [Int64]) async throws -> [TimeToBeat]
}

/// IGDB-backed provider (PLAN §5.3 default). Thin adapter over `IGDBClient`.
struct IGDBTimeToBeatProvider: TimeToBeatProvider {
    let id = "igdb"
    private let client: IGDBClient

    init(client: IGDBClient) {
        self.client = client
    }

    func times(forGameIDs ids: [Int64]) async throws -> [TimeToBeat] {
        let rows = try await client.timeToBeat(gameIDs: ids)
        return rows.map {
            TimeToBeat(
                gameID: $0.gameID,
                hastily: $0.hastily,
                normally: $0.normally,
                completely: $0.completely,
                count: $0.count,
                source: id
            )
        }
    }
}

import CoreGraphics
import GRDB
import SwiftUI

/// The dependency bundle the ranking destinations need, injected through the
/// SwiftUI environment so this lane never edits the app's container
/// (`VGNApp` / `AppEnvironment`). The orchestrator adds the single line
///
/// ```swift
/// .environment(\.rankingEnvironment,
///              RankingEnvironment(ranking: RankingStore(db),
///                                 library: libraryStore,
///                                 coverLoader: coverStore))
/// ```
///
/// at merge time; until then `RankingDestinationView` renders a clear
/// "ranking unavailable" state.
@MainActor
final class RankingEnvironment {
    let ranking: RankingStore
    let library: LibraryStore
    let coverLoader: any CoverLoading

    init(ranking: RankingStore, library: LibraryStore, coverLoader: any CoverLoading) {
        self.ranking = ranking
        self.library = library
        self.coverLoader = coverLoader
    }

    /// The seam the models read/write through.
    var backend: any RankingBackend {
        LiveRankingBackend(ranking: ranking, library: library, coverLoader: coverLoader)
    }

    #if DEBUG
    /// A ready-to-use environment over a fresh in-memory database, for previews
    /// and the end-to-end test. Optionally seeds a set of played games.
    static func inMemory(seed: [GameDraft] = []) async throws -> RankingEnvironment {
        let db = try await PreviewRankingSeed.database(seed: seed)
        return RankingEnvironment(ranking: RankingStore(db),
                                  library: LibraryStore(db),
                                  coverLoader: NoopCoverLoader())
    }
    #endif
}

// MARK: - Environment key

private struct RankingEnvironmentKey: EnvironmentKey {
    static let defaultValue: RankingEnvironment? = nil
}

extension EnvironmentValues {
    /// The injected ranking dependencies, or `nil` before the container wires them.
    var rankingEnvironment: RankingEnvironment? {
        get { self[RankingEnvironmentKey.self] }
        set { self[RankingEnvironmentKey.self] = newValue }
    }
}

// MARK: - Live backend

/// Forwards the ``RankingBackend`` seam to the real `RankingStore` /
/// `LibraryStore` / cover pipeline. A `Sendable` value (both stores are).
struct LiveRankingBackend: RankingBackend {
    let ranking: RankingStore
    let library: LibraryStore
    let coverLoader: any CoverLoading

    // Duel flow
    func currentDuel() async throws -> DuelPrompt? { try await ranking.currentDuel() }
    func answer(winner: Int64) async throws -> DuelOutcome { try await ranking.answer(winner: winner) }
    func skip() async throws { try await ranking.skip() }
    func undo() async throws -> Bool { try await ranking.undo() }
    func acceptBorderSuggestion(_ s: BorderSuggestion) async throws { try await ranking.acceptBorderSuggestion(s) }
    func dismissBorderSuggestion(_ s: BorderSuggestion) async throws { try await ranking.dismissBorderSuggestion(s) }
    func rePlace(_ gameID: Int64) async throws { try await ranking.rePlace(gameID) }

    // Tiering
    func setTier(_ ids: [Int64], tierID: Int64?) async throws -> SetTierOutcome {
        try await ranking.setTier(ids, tierID: tierID)
    }

    // Drag / drop overrides
    func move(gameID: Int64, toTier: Int64, atIndex: Int?) async throws {
        try await ranking.move(gameID: gameID, toTier: toTier, atIndex: atIndex)
    }
    func moveBatch(_ moves: [RankMove]) async throws {
        try await ranking.move(moves.map { (gameID: $0.gameID, toTier: $0.toTier, atIndex: $0.atIndex) })
    }
    func clearTier(_ gameID: Int64) async throws { try await ranking.clearTier(gameID) }
    func moveDivider(between upperTierID: Int64, and lowerTierID: Int64, by k: Int) async throws -> DividerMoveOutcome {
        try await ranking.moveDivider(between: upperTierID, and: lowerTierID, by: k)
    }

    // Reads
    func gameDetail(id: Int64) async throws -> GameDetail? { try await library.gameDetail(id: id) }
    func tiers() async throws -> [TierInfo] { try await library.tiers() }
    func tierBoardOnce() async throws -> [TierBoardRow] { try await ranking.tierBoardOnce() }
    func theTopOnce(filter: LibraryFilter) async throws -> [TopRow] {
        try await ranking.theTopOnce(filter: filter)
    }
    func derivedScores() async throws -> [Int64: DerivedScoreValue] { try await ranking.allDerivedScores() }
    func unrankedPlayedGames() async throws -> [GameSummary] {
        try await library.gamesOnce(filter: LibraryFilter(scope: .unranked, sort: .dateAdded, ascending: true))
    }
    func duelQueueCountOnce() async throws -> Int { try await ranking.duelQueueCountOnce() }
    func rankingStatsOnce() async throws -> RankingStats { try await ranking.rankingStatsOnce() }
    func contradictions() async throws -> [Consistency.Dispute] { try await ranking.contradictions() }

    // Live counts — bridge the GRDB observations to plain AsyncStreams.
    func duelQueueCountStream() -> AsyncStream<Int> { Self.bridge(ranking.duelQueueCount()) }
    func rankingStatsStream() -> AsyncStream<RankingStats> { Self.bridge(ranking.rankingStats()) }
    func unrankedGamesStream() -> AsyncStream<[GameSummary]> {
        Self.bridge(library.games(filter: LibraryFilter(scope: .unranked, sort: .dateAdded, ascending: true)))
    }
    func tierBoardStream() -> AsyncStream<[TierBoardRow]> { Self.bridge(ranking.tierBoard()) }
    func theTopStream(filter: LibraryFilter) -> AsyncStream<[TopRow]> {
        Self.bridge(ranking.theTop(filter: filter))
    }

    // Covers
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> CGImage? {
        await coverLoader.thumbnail(for: coverFile, pixelSize: pixelSize)
    }

    /// Republish a GRDB `ValueObservation` async sequence as a non-throwing
    /// `AsyncStream` (same pattern as `GRDBLibraryDataSource.bridge`). Cancelling
    /// the stream ends the observation.
    private static func bridge<Element: Sendable>(
        _ observation: AsyncValueObservation<Element>
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch {
                    // Observation ended (e.g. cancelled) — finish quietly.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import CoreGraphics
import GRDB
import SwiftUI

/// The dependency bundle the Play Next screen needs (PLAN §7b), injected through the
/// SwiftUI environment so this lane never edits the app container. The orchestrator
/// adds, at merge time, the single line
///
/// ```swift
/// .environment(\.playNextEnvironment,
///     PlayNextEnvironment(recommendation: RecommendationStore(db),
///                         library: libraryStore,
///                         ranking: RankingStore(db),
///                         coverLoader: coverStore,
///                         secondOpinion: ClaudeSecondOpinionProvider(
///                             runner: ClaudeProcessRunner(binaryOverride: settings.claudeBinaryPath),
///                             model: nil),
///                         inspect: { id in vm.selectOnly(id); vm.showInspector() }))
/// ```
///
/// and swaps the sidebar's Play Next destination to `PlayNextView`. Until then
/// `PlayNextView` renders a clear "unavailable" state.
@MainActor
final class PlayNextEnvironment {
    let recommendation: RecommendationStore
    let library: LibraryStore
    /// Kept for rank-derived scores (PLAN §7 "Scores are derived"); candidates are
    /// unranked, so the view leans on match strength, but the seam is here.
    let ranking: RankingStore
    let coverLoader: any CoverLoading
    let secondOpinion: any SecondOpinionProviding
    /// Reveal a game in the library inspector (`⌘I` / `space`).
    let inspect: (@MainActor (Int64) -> Void)?

    init(
        recommendation: RecommendationStore,
        library: LibraryStore,
        ranking: RankingStore,
        coverLoader: any CoverLoading,
        secondOpinion: any SecondOpinionProviding,
        inspect: (@MainActor (Int64) -> Void)? = nil
    ) {
        self.recommendation = recommendation
        self.library = library
        self.ranking = ranking
        self.coverLoader = coverLoader
        self.secondOpinion = secondOpinion
        self.inspect = inspect
    }

    /// The data seam the model reads/writes through.
    var backend: any PlayNextBackend {
        LivePlayNextBackend(recommendation: recommendation, library: library)
    }

    #if DEBUG
    /// A ready-to-use environment over a fresh in-memory database (for the
    /// end-to-end path / a live-data preview). Optionally seeds games.
    static func inMemory(
        seed: [GameDraft] = [],
        secondOpinion: any SecondOpinionProviding = StubSecondOpinionProvider()
    ) async throws -> PlayNextEnvironment {
        let db = try await PreviewRankingSeed.database(seed: seed)
        return PlayNextEnvironment(
            recommendation: RecommendationStore(db),
            library: LibraryStore(db),
            ranking: RankingStore(db),
            coverLoader: NoopCoverLoader(),
            secondOpinion: secondOpinion)
    }
    #endif
}

// MARK: - Environment key

private struct PlayNextEnvironmentKey: EnvironmentKey {
    static let defaultValue: PlayNextEnvironment? = nil
}

extension EnvironmentValues {
    /// The injected Play Next dependencies, or `nil` before the container wires them.
    var playNextEnvironment: PlayNextEnvironment? {
        get { self[PlayNextEnvironmentKey.self] }
        set { self[PlayNextEnvironmentKey.self] = newValue }
    }
}

// MARK: - Backend seam

/// The data operations the ``PlayNextModel`` needs, behind a protocol so the model
/// is unit-tested against a fake with no database. A `Sendable` value.
protocol PlayNextBackend: Sendable {
    func recommend(bracket: TimeBracket, options: RecommendationOptions) async throws -> PlayNextResult
    func backtest() async throws -> TasteBacktestResult
    func snooze(gameID: Int64) async throws
    func never(gameID: Int64) async throws
    /// Marks the game playing and returns a token to undo exactly that (PLAN §7b).
    func startPlaying(gameID: Int64) async throws -> StartPlayingUndo
    /// Reverses a previous ``startPlaying(gameID:)`` (may refuse — see the outcome).
    func undoStartPlaying(_ undo: StartPlayingUndo) async throws -> StartPlayingUndoOutcome
    func secondOpinionRequest(for result: PlayNextResult) async throws -> SecondOpinionRequest
    /// Title + tier for each cited exemplar id, for the reason sentences.
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo]
    func inputsSignatureOnce() async throws -> RecommendationInputsSignature
    func inputsChangedStream() -> AsyncStream<RecommendationInputsSignature>
}

// MARK: - Live backend

/// Forwards the ``PlayNextBackend`` seam to the real stores. A `Sendable` value
/// (both stores are).
struct LivePlayNextBackend: PlayNextBackend {
    let recommendation: RecommendationStore
    let library: LibraryStore

    func recommend(bracket: TimeBracket, options: RecommendationOptions) async throws -> PlayNextResult {
        try await recommendation.recommend(bracket: bracket, options: options)
    }
    func backtest() async throws -> TasteBacktestResult { try await recommendation.backtest() }
    func snooze(gameID: Int64) async throws { try await recommendation.snooze(gameID: gameID) }
    func never(gameID: Int64) async throws { try await recommendation.never(gameID: gameID) }
    func startPlaying(gameID: Int64) async throws -> StartPlayingUndo {
        try await recommendation.startPlayingCapturingUndo(gameID: gameID)
    }
    func undoStartPlaying(_ undo: StartPlayingUndo) async throws -> StartPlayingUndoOutcome {
        try await recommendation.undoStartPlaying(undo)
    }
    func secondOpinionRequest(for result: PlayNextResult) async throws -> SecondOpinionRequest {
        try await recommendation.secondOpinionRequest(for: result)
    }

    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ExemplarInfo] = [:]
        for id in Set(ids) {
            if let detail = try await library.gameDetail(id: id) {
                out[id] = ExemplarInfo(title: detail.title, tierLetter: detail.tierLetter)
            }
        }
        return out
    }

    func inputsSignatureOnce() async throws -> RecommendationInputsSignature {
        try await recommendation.inputsSignatureOnce()
    }

    func inputsChangedStream() -> AsyncStream<RecommendationInputsSignature> {
        Self.bridge(recommendation.inputsChanged())
    }

    /// Republish a GRDB observation as a non-throwing `AsyncStream` (same pattern as
    /// `LiveRankingBackend.bridge`). Cancelling the stream ends the observation.
    private static func bridge<Element: Sendable>(
        _ observation: AsyncValueObservation<Element>
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch { /* observation ended */ }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

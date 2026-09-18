import CoreGraphics
import Foundation

/// The narrow seam the ranking UI models (Duel / Triage) read and write through
/// (PLAN §7). Everything the `@Observable` models need — duel flow, tier writes,
/// display reads and live counts — expressed in plain `VGN/Model` value types so
/// the models are testable against a fake with no database at all.
///
/// The live implementation (`LiveRankingBackend`) forwards to `RankingStore` +
/// `LibraryStore` + a `CoverLoading`; tests supply a hand-driven fake.
protocol RankingBackend: Sendable {
    // MARK: Duel flow (PLAN §7 — two covers, ←/→ pick, ↓ skip, ⌘Z undo)
    func currentDuel() async throws -> DuelPrompt?
    @discardableResult func answer(winner: Int64) async throws -> DuelOutcome
    func skip() async throws
    @discardableResult func undo() async throws -> Bool
    func acceptBorderSuggestion(_ suggestion: BorderSuggestion) async throws
    func dismissBorderSuggestion(_ suggestion: BorderSuggestion) async throws
    func rePlace(_ gameID: Int64) async throws

    // MARK: Tiering (Triage `S A B C D F`, `0` clears — PLAN §7)
    @discardableResult func setTier(_ gameIDs: [Int64], tierID: Int64?) async throws -> SetTierOutcome

    // MARK: Drag / drop overrides (Tier Board + The Top — PLAN §7)
    /// Move a game to `toTier` at an exact position (0 = top). `atIndex == nil`
    /// drops it into the unplaced tail (tier set, key cleared, re-queued).
    func move(gameID: Int64, toTier: Int64, atIndex: Int?) async throws
    /// Clear a game's tier entirely (the `0` key on the board).
    func clearTier(_ gameID: Int64) async throws

    // MARK: Reads for display
    func gameDetail(id: Int64) async throws -> GameDetail?
    func tiers() async throws -> [TierInfo]
    func tierBoardOnce() async throws -> [TierBoardRow]
    func theTopOnce(filter: LibraryFilter) async throws -> [TopRow]
    func unrankedPlayedGames() async throws -> [GameSummary]
    func duelQueueCountOnce() async throws -> Int
    func rankingStatsOnce() async throws -> RankingStats
    func contradictions() async throws -> [Consistency.Dispute]

    // MARK: Live counts (external library changes reflect while the view is open)
    func duelQueueCountStream() -> AsyncStream<Int>
    func rankingStatsStream() -> AsyncStream<RankingStats>
    func unrankedGamesStream() -> AsyncStream<[GameSummary]>
    /// Live Tier Board rows (external edits reflect while the board is open).
    func tierBoardStream() -> AsyncStream<[TierBoardRow]>
    /// Live numbered chart for a filter.
    func theTopStream(filter: LibraryFilter) -> AsyncStream<[TopRow]>

    // MARK: Covers (PLAN §9 image pipeline seam)
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> CGImage?
}

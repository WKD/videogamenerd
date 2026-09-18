import Foundation
import GRDB

/// The data side of Play Next (PLAN §7b). Loads the pure engine's inputs from SQL,
/// runs the engine off the main actor, persists "not this one" feedback, and hands
/// the UI a ``PlayNextResult`` plus a change observation. A thin `Sendable` value
/// over ``AppDatabase`` — the mirror of ``LibraryStore`` / ``RankingStore``.
///
/// Taste inputs reuse ``RankingStore/loadSnapshot(_:)`` + ``GlobalRank`` so the
/// scores are exactly the ranking's own order; candidates come from ownership
/// (products, incl. compilation members and ROM copies).
struct RecommendationStore: Sendable {
    let database: AppDatabase
    var dbWriter: any DatabaseWriter { database.dbWriter }
    var dbReader: any DatabaseReader { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    // MARK: - Recommend

    /// Compute the recommendation for a bracket (PLAN §7b). Reads the inputs in a
    /// single DB read, then runs the pure engine on the current (non-main) executor.
    func recommend(
        bracket: TimeBracket,
        options: RecommendationOptions = RecommendationOptions(),
        weights: RecommendationWeights = RecommendationWeights()
    ) async throws -> PlayNextResult {
        let input = try await dbReader.read { db in
            try Self.loadInput(bracket: bracket, options: options, weights: weights, db: db)
        }
        return RecommendationEngine.recommend(input)
    }

    /// The leave-one-out taste backtest over the ranked games (PLAN §7b).
    func backtest(weights: RecommendationWeights = RecommendationWeights()) async throws -> TasteBacktestResult {
        let ranked = try await dbReader.read { db in try Self.loadRankedGames(db: db) }
        return TasteBacktest.run(ranked: ranked, weights: weights)
    }

    // MARK: - Feedback (rec_feedback)

    /// "Not this one" — snooze a game for a few weeks (PLAN §7b). Stored as a
    /// timestamped `snooze` row; the loader derives snoozed-until from it +
    /// ``RecommendationWeights/snoozeWindow``.
    func snooze(gameID: Int64) async throws { try await logFeedback(gameID: gameID, action: "snooze") }

    /// "Never" — remove a game from Play Next for good (PLAN §7b).
    func never(gameID: Int64) async throws { try await logFeedback(gameID: gameID, action: "never") }

    /// Record that a game was picked (rotation memory).
    func picked(gameID: Int64) async throws { try await logFeedback(gameID: gameID, action: "picked") }

    private func logFeedback(gameID: Int64, action: String) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "INSERT INTO rec_feedback (game_id, action, created_at) VALUES (?, ?, ?)",
                           arguments: [gameID, action, Date()])
        }
    }

    /// "Start playing" (PLAN §7b action): status = playing (implies played) and log
    /// a `picked` rotation memory, in one transaction.
    func startPlaying(gameID: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET status = 'playing', played = 1, updated_at = ? WHERE id = ?",
                           arguments: [Date(), gameID])
            try db.execute(sql: "INSERT INTO rec_feedback (game_id, action, created_at) VALUES (?, 'picked', ?)",
                           arguments: [gameID, Date()])
        }
    }

    // MARK: - Change observation

    /// Emits whenever the Play Next inputs change (rankings, ownership, status,
    /// playtime, traits, rating, or feedback), so the view can re-`recommend`.
    func inputsChanged() -> AsyncValueObservation<RecommendationInputsSignature> {
        ValueObservation.tracking { db in try Self.signature(db) }.values(in: dbReader)
    }

    func inputsSignatureOnce() async throws -> RecommendationInputsSignature {
        try await dbReader.read { db in try Self.signature(db) }
    }

    static func signature(_ db: Database) throws -> RecommendationInputsSignature {
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
        let ranked = try count("SELECT COUNT(*) FROM games WHERE played = 1 AND tier_id IS NOT NULL")
        let owned = try count("SELECT COUNT(*) FROM product_games")
        let traits = try count("SELECT COUNT(*) FROM game_traits")
        let feedback = try count("SELECT COUNT(*) FROM rec_feedback")
        let updated = try Double.fetchOne(db, sql:
            "SELECT COALESCE(MAX(strftime('%s', updated_at)), 0) FROM games") ?? 0
        return RecommendationInputsSignature(ranked: ranked, owned: owned, traits: traits,
                                             feedback: feedback, latestUpdate: updated)
    }

    // MARK: - Second-opinion export

    /// The plain, minimal payload that may leave the app for "Ask Claude"
    /// (PLAN §7b). No library dump: the top-ranked tier list (~60), the D–F
    /// "didn't click" titles, the shortlisted candidates, and the engine ordering.
    func secondOpinionRequest(
        for result: PlayNextResult, topRankedLimit: Int = 60
    ) async throws -> SecondOpinionRequest {
        try await dbReader.read { db in
            try Self.buildSecondOpinion(result: result, topRankedLimit: topRankedLimit, db: db)
        }
    }
}

/// A cheap fingerprint of the recommendation inputs — the observation emits a new
/// value whenever any of these change, prompting a refresh.
struct RecommendationInputsSignature: Hashable, Sendable {
    var ranked: Int
    var owned: Int
    var traits: Int
    var feedback: Int
    var latestUpdate: Double
}

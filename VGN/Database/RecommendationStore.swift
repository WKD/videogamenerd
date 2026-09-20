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

    /// The user's ranked games as the pure taste profile (`id`, igdb id, 0…1 derived score,
    /// traits) — reused by the Batocera "Discover" scorer (PLAN §15) without re-querying.
    func rankedGames() async throws -> [RankedGame] {
        try await dbReader.read { db in try Self.loadRankedGames(db: db) }
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
        _ = try await startPlayingCapturingUndo(gameID: gameID)
    }

    /// Like ``startPlaying(gameID:)`` but captures the game's exact prior state (and
    /// the id of the inserted `picked` row) **in the same transaction**, so the
    /// action can be undone precisely (PLAN §7b). Returns a token for
    /// ``undoStartPlaying(_:)``.
    func startPlayingCapturingUndo(gameID: Int64) async throws -> StartPlayingUndo {
        try await dbWriter.write { db in
            guard let prior = try Row.fetchOne(
                db, sql: "SELECT status, played, revisit, updated_at FROM games WHERE id = ?",
                arguments: [gameID])
            else { throw StartPlayingError.gameNotFound }
            let undo = StartPlayingUndo(
                gameID: gameID,
                previousStatus: prior["status"],
                previousPlayed: (prior["played"] as Int64) == 1,
                previousRevisit: (prior["revisit"] as Int64) == 1,
                previousUpdatedAt: prior["updated_at"],
                pickedFeedbackID: 0)   // filled below
            // Setting Playing clears the revisit flag (a Playing game is not "To Revisit").
            // Undo restores the exact prior status *and* flag, so "To Revisit" comes back.
            try db.execute(sql: "UPDATE games SET status = 'playing', played = 1, revisit = 0, updated_at = ? WHERE id = ?",
                           arguments: [Date(), gameID])
            try db.execute(sql: "INSERT INTO rec_feedback (game_id, action, created_at) VALUES (?, 'picked', ?)",
                           arguments: [gameID, Date()])
            return undo.withPickedFeedbackID(db.lastInsertedRowID)
        }
    }

    /// Reverse a ``startPlayingCapturingUndo(gameID:)`` exactly (PLAN §7b): restore
    /// the prior status / played / updated_at and delete the `picked` row this
    /// action inserted — all in one transaction. It **refuses** rather than damage
    /// data the user changed since:
    ///  - `.refusedRanked` — the game was given a tier after it started playing;
    ///    un-playing it would strip a valid ranking, so undo leaves everything intact.
    ///  - `.refusedWouldOrphan` — restoring `played = 0` would leave a game that is
    ///    neither played nor owned (guarded even though Play Next candidates are
    ///    owned by construction).
    ///  - `.gameGone` — the game no longer exists (its feedback cascaded away).
    func undoStartPlaying(_ undo: StartPlayingUndo) async throws -> StartPlayingUndoOutcome {
        try await dbWriter.write { db in
            guard let current = try Row.fetchOne(
                db, sql: "SELECT tier_id FROM games WHERE id = ?", arguments: [undo.gameID])
            else { return .gameGone }

            // Only relevant when the game was unplayed before starting: restoring
            // played = 0 must not violate the tier/rank or played-or-owned invariants.
            if !undo.previousPlayed {
                if (current["tier_id"] as Int64?) != nil { return .refusedRanked }
                let owned = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM product_games WHERE game_id = ?",
                    arguments: [undo.gameID]) ?? 0
                if owned == 0 { return .refusedWouldOrphan }
            }

            try db.execute(sql: "UPDATE games SET status = ?, played = ?, revisit = ?, updated_at = ? WHERE id = ?",
                           arguments: [undo.previousStatus, undo.previousPlayed ? 1 : 0,
                                       undo.previousRevisit ? 1 : 0,
                                       undo.previousUpdatedAt, undo.gameID])
            try db.execute(sql: "DELETE FROM rec_feedback WHERE id = ?", arguments: [undo.pickedFeedbackID])
            return .restored
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

/// The exact prior state captured when "Start playing" runs, so it can be undone
/// precisely (PLAN §7b). All fields are the DB's own values (played as a flag, the
/// `updated_at` text verbatim), plus the id of the `picked` feedback row inserted.
struct StartPlayingUndo: Sendable, Equatable {
    var gameID: Int64
    var previousStatus: String?
    var previousPlayed: Bool
    /// The prior `games.revisit` flag, so undoing a "Start playing" restores a
    /// "To Revisit" game to exactly that (v15).
    var previousRevisit: Bool
    var previousUpdatedAt: String?
    var pickedFeedbackID: Int64

    func withPickedFeedbackID(_ id: Int64) -> StartPlayingUndo {
        var copy = self
        copy.pickedFeedbackID = id
        return copy
    }
}

/// Result of ``RecommendationStore/undoStartPlaying(_:)``.
enum StartPlayingUndoOutcome: Sendable, Equatable {
    case restored
    case refusedRanked
    case refusedWouldOrphan
    case gameGone
}

enum StartPlayingError: Error, Sendable { case gameNotFound }

/// A cheap fingerprint of the recommendation inputs — the observation emits a new
/// value whenever any of these change, prompting a refresh.
struct RecommendationInputsSignature: Hashable, Sendable {
    var ranked: Int
    var owned: Int
    var traits: Int
    var feedback: Int
    var latestUpdate: Double
}

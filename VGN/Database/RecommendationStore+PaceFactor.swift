import Foundation
import GRDB

// MARK: - Personal pace factor (PLAN §7b "Scheduled 2026-09-25", §8)

extension RecommendationStore {

    /// The finished / 100 % games with a known effective play time, as pure
    /// ``PaceFactor/Sample``s. One scan; the pure rule decides which qualify (a main
    /// estimate, not suspicious). Read-only — the factor is never stored.
    static func fetchPaceSamples(_ db: Database) throws -> [PaceFactor.Sample] {
        let dismissed = try LibraryStore.readDismissedEstimateIDs(db)
        // Each finished game's genres, for the per-genre factors (PLAN §7b "Per-genre pace").
        var genresByGame: [Int64: [PaceFactor.GenreRef]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT gg.game_id, ge.id, ge.name
            FROM game_genres gg
            JOIN genres ge ON ge.id = gg.genre_id
            JOIN games g ON g.id = gg.game_id
            WHERE g.status IN ('finished', 'completed')
            ORDER BY gg.game_id, ge.id
            """) {
            genresByGame[row[0], default: []].append(PaceFactor.GenreRef(id: row[1], name: row[2]))
        }
        return try Row.fetchAll(db, sql: """
            SELECT g.id, g.status, \(LibraryQuery.effectivePlaytimeSQL()) AS played_s,
                   g.ttb_hastily_s, g.ttb_normally_s, g.ttb_completely_s, g.ttb_source
            FROM games g
            WHERE g.status IN ('finished', 'completed')
              AND \(LibraryQuery.effectivePlaytimeSQL()) > 0
            """).map { row in
            PaceFactor.Sample(
                playedSeconds: row["played_s"],
                rushedSeconds: row["ttb_hastily_s"],
                mainSeconds: row["ttb_normally_s"],
                completionistSeconds: row["ttb_completely_s"],
                completed100: (row["status"] as String?) == "completed",
                sourceIsHLTB: (row["ttb_source"] as String?) == HLTBSource.id,
                dismissed: dismissed.contains(row["id"]),
                genres: genresByGame[row["id"]] ?? [])
        }
    }

    /// The measured pace factor for the library in `db`.
    static func fetchPaceFactor(_ db: Database) throws -> PaceFactor {
        PaceFactor.compute(samples: try fetchPaceSamples(db))
    }

    /// One-shot measurement.
    func paceFactor() async throws -> PaceFactor {
        try await dbReader.read { db in try Self.fetchPaceFactor(db) }
    }

    /// A live measurement: re-emits when a finished game's play time / estimate / status
    /// changes, or its genres do (GRDB tracks the read `games`, `game_genres`, `genres` +
    /// `app_state` tables), deduplicated so an
    /// unrelated write that leaves the factor unchanged does not ripple.
    func paceFactorObservation() -> AsyncValueObservation<PaceFactor> {
        ValueObservation.tracking { db in try Self.fetchPaceFactor(db) }
            .removeDuplicates()
            .values(in: dbReader)
    }
}

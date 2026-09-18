import Foundation
import GRDB

/// Read helpers the UI's filter menus need but the base store doesn't expose:
/// the set of genres and decades that actually occur in the library, so the
/// Genre ▾ and Decade ▾ toolbar menus (PLAN §8) list only meaningful choices and
/// update live as the library changes.
///
/// Owned by the UI lane (added under `Database/` because it needs `Database`'s
/// GRDB access); it only reads, never mutates the schema.
extension LibraryStore {
    /// Genre names present on at least one game, alphabetically. Live.
    func genresInUse() -> AsyncValueObservation<[String]> {
        ValueObservation.tracking { db in try Self.fetchGenresInUse(db) }
            .values(in: dbReader)
    }

    /// One-shot in-use genres.
    func genresInUseOnce() async throws -> [String] {
        try await dbReader.read { db in try Self.fetchGenresInUse(db) }
    }

    static func fetchGenresInUse(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT ge.name FROM genres ge
            JOIN game_genres gg ON gg.genre_id = ge.id
            ORDER BY ge.name COLLATE NOCASE
            """)
    }

    /// Decades (e.g. 1990, 2000) present on at least one game, ascending. Live.
    func decadesInUse() -> AsyncValueObservation<[Int]> {
        ValueObservation.tracking { db in try Self.fetchDecadesInUse(db) }
            .values(in: dbReader)
    }

    /// One-shot in-use decades.
    func decadesInUseOnce() async throws -> [Int] {
        try await dbReader.read { db in try Self.fetchDecadesInUse(db) }
    }

    static func fetchDecadesInUse(_ db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            SELECT DISTINCT decade FROM games
            WHERE decade IS NOT NULL
            ORDER BY decade
            """)
    }
}

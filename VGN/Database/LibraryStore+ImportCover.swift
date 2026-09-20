import Foundation
import GRDB

/// Cover-side helpers for a file importer that carries its own box art (Delicious,
/// PLAN §5.5). A Delicious cover is applied only where a game has **no** cover and is
/// **not** marked user-chosen, so a later, better cover from enrichment may still replace
/// it — unlike ``LibraryStore/setUserCover(gameID:coverFile:)`` which locks it.
extension LibraryStore {

    /// Set `cover_file` only if the game currently has none, without touching the
    /// `user_edited` marker, and mark it **provisional** (`cover_provisional = 1`, v14) so
    /// the background cover job still runs and may upgrade it to a provider-found cover
    /// (owner request — a Delicious box-art cover must not stick when a better one exists).
    /// Returns true if it wrote.
    @discardableResult
    func setImportedCoverIfEmpty(gameID: Int64, coverFile: String) async throws -> Bool {
        try await dbWriter.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT cover_file FROM games WHERE id = ?", arguments: [gameID])
            guard (current ?? "").isEmpty else { return false }
            try db.execute(
                sql: "UPDATE games SET cover_file = ?, cover_provisional = 1, updated_at = ? WHERE id = ?",
                arguments: [coverFile, Date(), gameID])
            return true
        }
    }

    /// Replace a game's cover with one the provider chain found, clearing the
    /// **provisional** marker (v14) — used by background enrichment to upgrade an
    /// importer-supplied cover. Does **not** mark the cover `user_edited` (a provider
    /// cover, unlike a hand-picked one, may itself be replaced by a later refresh).
    /// Returns the file it replaced (so the caller can delete the now-orphaned original),
    /// or `nil` when nothing changed.
    @discardableResult
    func setProviderCover(gameID: Int64, coverFile: String) async throws -> String? {
        try await dbWriter.write { db in
            let previous = try String.fetchOne(
                db, sql: "SELECT cover_file FROM games WHERE id = ?", arguments: [gameID])
            try db.execute(
                sql: "UPDATE games SET cover_file = ?, cover_provisional = 0, updated_at = ? WHERE id = ?",
                arguments: [coverFile, Date(), gameID])
            let old = (previous ?? "")
            return (old.isEmpty || old == coverFile) ? nil : old
        }
    }

    /// For the given games, the import `external_id` of their `source` product where the
    /// game still has no cover — the set that a source-cover fallback should fill.
    func coverFallbackTargets(gameIDs: [Int64], source: String) async throws -> [(gameID: Int64, externalID: String)] {
        guard !gameIDs.isEmpty else { return [] }
        return try await dbWriter.read { db in
            let placeholders = databaseQuestionMarks(count: gameIDs.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT pg.game_id AS game_id, p.external_id AS external_id
                FROM products p
                JOIN product_games pg ON pg.product_id = p.id
                JOIN games g ON g.id = pg.game_id
                WHERE p.source = ? AND p.external_id IS NOT NULL
                  AND pg.game_id IN (\(placeholders))
                  AND (g.cover_file IS NULL OR g.cover_file = '')
                """, arguments: StatementArguments([source] + gameIDs.map { $0 as DatabaseValueConvertible }))
            return rows.map { (gameID: $0["game_id"], externalID: $0["external_id"]) }
        }
    }
}

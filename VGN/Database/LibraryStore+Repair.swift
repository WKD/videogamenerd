import Foundation
import GRDB

/// One-shot, launch-time data repairs — each guarded by an `app_state` flag so it runs
/// exactly once per library and is a no-op on every later launch. No schema change.
extension LibraryStore {

    /// `app_state` key marking the copy-only platform-row repair as done (bug 2026-09-20).
    static let copyOnlyPlatformsRepairKey = "repair.copyOnlyPlatforms.v1"

    /// Apply the ``pruneCopyOnlyPlatforms(gameIDs:db:)`` rule to the **whole** library once,
    /// to clean up stale `game_platforms` rows left by copy deletions from before the fix
    /// (e.g. the "Mac" pill that never went away when the Mac copy of a Mac+PC game was
    /// removed). Conservative by construction — rules (a)–(c) never touch a played-on row,
    /// a platform still backed by a copy, or a game's last platform. One transaction; the
    /// flag makes a second run a no-op. Returns the number of rows removed (0 when already
    /// done). Safe to call from `AppEnvironment.bootstrap` — never from a view builder.
    @discardableResult
    func repairCopyOnlyPlatforms() async throws -> Int {
        try await dbWriter.write { db in
            let alreadyDone = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM app_state WHERE key = ?)",
                arguments: [Self.copyOnlyPlatformsRepairKey]) ?? false
            guard !alreadyDone else { return 0 }

            let gameIDs = try Int64.fetchAll(db, sql: "SELECT id FROM games")
            let removed = try Self.pruneCopyOnlyPlatforms(gameIDs: gameIDs, db: db)

            try db.execute(sql: """
                INSERT INTO app_state (key, json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
                """, arguments: [Self.copyOnlyPlatformsRepairKey, "{\"removed\":\(removed)}", Date()])
            return removed
        }
    }
}

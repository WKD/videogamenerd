import Foundation
import GRDB

// MARK: - v17 — Batocera play time gets its own column (PLAN §7b "Scheduled 2026-09-25", §15)

extension Migrations {

    /// The v17 SQL, one statement per step, exposed so tests can re-run it and prove the
    /// data move is idempotent (running the steps twice changes nothing more).
    ///
    /// **Explicit owner-requested one-shot data move** (2026-09-25 — the exception to PLAN §4
    /// inv. 5, because the owner asked for it). Until v17 the Batocera promotion stored the
    /// box's `gametime` in `psn_playtime_s` (the interim); v17 gives it a column of its own.
    ///
    /// A game is **tied to Batocera** when it has a `batocera` copy or a promoted Batocera
    /// catalogue row; it is **tied to PSN** when it has a `psn` copy, a PSN import row matched
    /// to it, or a promoted PS Plus Vault row. Only Batocera-tied, not-PSN-tied games move.
    /// `my_playtime_s` is never touched.
    static let v17Steps: [String] = [
        // 1. The column.
        """
        ALTER TABLE games ADD COLUMN batocera_playtime_s INTEGER
            CHECK (batocera_playtime_s IS NULL OR batocera_playtime_s >= 0);
        """,
        v17MoveSQL,
        v17CatalogueFillSQL,
    ]

    /// Step 2 — move the interim value: Batocera-only games' `psn_playtime_s` →
    /// `batocera_playtime_s` (SQLite evaluates every SET right-hand side on the old row).
    static let v17MoveSQL = """
        UPDATE games
           SET batocera_playtime_s = psn_playtime_s,
               psn_playtime_s = NULL
         WHERE psn_playtime_s IS NOT NULL
           AND (EXISTS (SELECT 1 FROM product_games pg JOIN products p ON p.id = pg.product_id
                         WHERE pg.game_id = games.id AND p.source = 'batocera')
                OR EXISTS (SELECT 1 FROM rom_catalog rc
                            WHERE rc.promoted_game_id = games.id AND rc.source = 'batocera'))
           AND NOT EXISTS (SELECT 1 FROM product_games pg JOIN products p ON p.id = pg.product_id
                            WHERE pg.game_id = games.id AND p.source = 'psn')
           AND NOT EXISTS (SELECT 1 FROM import_titles it
                            WHERE it.source = 'psn' AND it.matched_game_id = games.id)
           AND NOT EXISTS (SELECT 1 FROM rom_catalog rc
                            WHERE rc.promoted_game_id = games.id AND rc.source = 'psn');
        """

    /// Step 3 — every game with a promoted Batocera catalogue row gets the largest catalogue
    /// `game_time_s` (> 0) when its Batocera time is still unset (fills the games that also
    /// have a PSN time, whose `psn_playtime_s` stays PSN's).
    static let v17CatalogueFillSQL = """
        UPDATE games
           SET batocera_playtime_s = (
                SELECT MAX(rc.game_time_s) FROM rom_catalog rc
                 WHERE rc.promoted_game_id = games.id AND rc.source = 'batocera')
         WHERE batocera_playtime_s IS NULL
           AND (SELECT MAX(rc.game_time_s) FROM rom_catalog rc
                 WHERE rc.promoted_game_id = games.id AND rc.source = 'batocera') > 0;
        """

    /// v17 adds `games.batocera_playtime_s` (nullable, ≥ 0) — Batocera's own play-time
    /// column, written monotonically by the Batocera promotion / favourites auto-add
    /// (`LibraryStore.setBatoceraPlaytime`) — and performs the one-shot move above. Read
    /// side: effective play time = manual, else MAX(PSN, Batocera), never summed
    /// (`LibraryQuery.effectivePlaytimeSQL` / `EffectivePlaytime`).
    ///
    /// NOTE(merge): registered after v16 (W21-A) in `AppDatabase.migrator`.
    static func registerV17(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { db in
            for sql in v17Steps { try db.execute(sql: sql) }
        }
    }
}

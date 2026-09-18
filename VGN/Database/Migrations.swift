import Foundation
import GRDB

/// VGN schema migrations — one closure per version, lane A owned.
///
/// v1 is the ENTIRE PLAN §4 data model plus the operational tables the plan
/// needs elsewhere: the persisted enrichment job queue (§9), the generic
/// `app_state` blob store (holds resumable ranking/placement sessions, §7), the
/// FTS5 search mirror with sync triggers, and the default tier seed.
enum Migrations {
    static func registerV1(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try createPlatforms(db)
            try createTiers(db)
            try createGenres(db)
            try createGames(db)
            try createGamePlatforms(db)
            try createGameGenres(db)
            try createProducts(db)
            try createProductGames(db)
            try createComparisons(db)
            try createImportTitles(db)
            try createCatalogCache(db)
            try createEnrichmentJobs(db)
            try createAppState(db)
            try createGamesFTS(db)
            try seedTiers(db)
        }
    }

    // MARK: - v2 — search depth + sort_title shape

    /// v2 deepens search and refreshes sort keys (Data lane, wave 2):
    ///  - recompute `sort_title` for every existing game to the new
    ///    ``SortTitle`` shape (article/numeral-normalised, zero-padded), since the
    ///    stored value's shape changed;
    ///  - rebuild `games_fts` with a **diacritics-insensitive** tokenizer
    ///    (`unicode61 remove_diacritics 2`) so "pokemon" finds "Pokémon"
    ///    (PLAN §8). Rebuilding the FTS table requires re-creating it and its
    ///    triggers, then repopulating from the content table.
    static func registerV2(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2") { db in
            // (a) Recompute sort_title (shape changed). This fires games_au, which
            // is harmless — the FTS is rebuilt from scratch just below anyway.
            for row in try Row.fetchAll(db, sql: "SELECT id, title FROM games") {
                let id: Int64 = row["id"]
                let title: String = row["title"]
                try db.execute(sql: "UPDATE games SET sort_title = ? WHERE id = ?",
                               arguments: [SortTitle.make(from: title), id])
            }

            // (b) Rebuild games_fts with the diacritics-insensitive tokenizer.
            try db.execute(sql: "DROP TRIGGER IF EXISTS games_ai;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS games_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS games_au;")
            try db.execute(sql: "DROP TABLE IF EXISTS games_fts;")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE games_fts USING fts5(
                    title,
                    alt_titles,
                    content='games',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
            try createGamesFTSTriggers(db)
            // Repopulate from the external content table.
            try db.execute(sql: "INSERT INTO games_fts(games_fts) VALUES('rebuild');")
        }
    }

    // MARK: - v3 — ownership format ROM

    /// v3 widens `products.format` to allow `rom` (PLAN §4 — a ROM is a
    /// first-class, manually-entered way to own a game). SQLite cannot ALTER a
    /// CHECK constraint, so the table is rebuilt the standard way (create new,
    /// copy, drop, rename), preserving the `ON DELETE RESTRICT` on `platform_id`,
    /// the platform index, and `product_games`' foreign key / cascade. Runs with
    /// deferred foreign-key checks (GRDB's documented table-recreation pattern).
    static func registerV3(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3", foreignKeyChecks: .deferred) { db in
            try db.execute(sql: """
                CREATE TABLE products_new (
                    id              INTEGER PRIMARY KEY,
                    title           TEXT,
                    platform_id     TEXT    NOT NULL REFERENCES platforms(id) ON DELETE RESTRICT,
                    kind            TEXT    NOT NULL CHECK (kind   IN ('single','compilation')),
                    format          TEXT    NOT NULL CHECK (format IN ('physical','digital','rom')),
                    edition         TEXT,
                    region          TEXT,
                    igdb_id         INTEGER,
                    cover_file      TEXT,
                    source          TEXT    NOT NULL CHECK (source IN ('manual','photo','psn')),
                    psn_entitlement TEXT,
                    acquired_at     DATETIME,
                    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """)
            try db.execute(sql: """
                INSERT INTO products_new
                    (id, title, platform_id, kind, format, edition, region, igdb_id,
                     cover_file, source, psn_entitlement, acquired_at, created_at, updated_at)
                SELECT
                    id, title, platform_id, kind, format, edition, region, igdb_id,
                    cover_file, source, psn_entitlement, acquired_at, created_at, updated_at
                FROM products;
                """)
            try db.execute(sql: "DROP TABLE products;")
            try db.execute(sql: "ALTER TABLE products_new RENAME TO products;")
            try db.execute(sql: "CREATE INDEX products_platform_idx ON products(platform_id);")
        }
    }

    // MARK: - Reference / lookup tables

    private static func createPlatforms(_ db: Database) throws {
        // Data-driven (PLAN §5.6). Upserted from bundled platforms.json every
        // launch; `id` is the slug. `group_name` is the sidebar section
        // (avoids the SQL reserved word `group`). `igdb_ids` is a JSON array of
        // IGDB platform ids; `libretro_repo` feeds the cover provider.
        try db.execute(sql: """
            CREATE TABLE platforms (
                id            TEXT    NOT NULL PRIMARY KEY,
                name          TEXT    NOT NULL,
                short         TEXT    NOT NULL,
                manufacturer  TEXT    NOT NULL,
                group_name    TEXT    NOT NULL,
                kind          TEXT    NOT NULL CHECK (kind IN ('console','handheld','computer','arcade')),
                generation    INTEGER,
                igdb_ids      TEXT    NOT NULL DEFAULT '[]',
                libretro_repo TEXT,
                sort          INTEGER NOT NULL DEFAULT 0
            );
            """)
    }

    private static func createTiers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE tiers (
                id     INTEGER PRIMARY KEY,
                letter TEXT    NOT NULL,
                label  TEXT    NOT NULL,
                color  TEXT    NOT NULL,
                sort   INTEGER NOT NULL
            );
            """)
    }

    private static func createGenres(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE genres (
                id   INTEGER PRIMARY KEY,
                name TEXT    NOT NULL UNIQUE
            );
            """)
    }

    // MARK: - Games

    private static func createGames(_ db: Database) throws {
        // `decade` is a generated column so the decade filter / index is free
        // and always consistent with `year`. Invariant 2 (only played games can
        // carry a tier/rank) and "rank requires tier" are enforced at the DB
        // level by CHECK constraints, on top of the LibraryStore logic.
        try db.execute(sql: """
            CREATE TABLE games (
                id                  INTEGER PRIMARY KEY,
                igdb_id             INTEGER UNIQUE,
                title               TEXT    NOT NULL,
                sort_title          TEXT    NOT NULL DEFAULT '',
                alt_titles          TEXT    NOT NULL DEFAULT '',
                summary             TEXT,
                release_date        DATETIME,
                year                INTEGER,
                decade              INTEGER GENERATED ALWAYS AS
                                        (CASE WHEN year IS NULL THEN NULL ELSE (year / 10) * 10 END) VIRTUAL,
                played              INTEGER NOT NULL DEFAULT 0 CHECK (played IN (0, 1)),
                status              TEXT    CHECK (status IN ('playing','finished','completed','abandoned')),
                tier_id             INTEGER REFERENCES tiers(id) ON DELETE SET NULL,
                rank_key            INTEGER,
                my_playtime_s       INTEGER,
                psn_playtime_s      INTEGER,
                ttb_hastily_s       INTEGER,
                ttb_normally_s      INTEGER,
                ttb_completely_s    INTEGER,
                ttb_source          TEXT,
                igdb_cover_image_id TEXT,
                cover_file          TEXT,
                added_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                CHECK (tier_id  IS NULL OR played = 1),
                CHECK (rank_key IS NULL OR tier_id IS NOT NULL)
            );
            """)
        try db.execute(sql: "CREATE INDEX games_tier_rank_idx ON games(tier_id, rank_key);")
        try db.execute(sql: "CREATE INDEX games_decade_idx     ON games(decade);")
        try db.execute(sql: "CREATE INDEX games_played_idx     ON games(played);")
        try db.execute(sql: "CREATE INDEX games_sort_title_idx ON games(sort_title);")
        try db.execute(sql: "CREATE INDEX games_status_idx     ON games(status);")
    }

    private static func createGamePlatforms(_ db: Database) throws {
        // Where a game exists / was played. Contributes to platform membership
        // together with products (a game "counts" for a platform via either).
        try db.execute(sql: """
            CREATE TABLE game_platforms (
                game_id     INTEGER NOT NULL REFERENCES games(id)     ON DELETE CASCADE,
                platform_id TEXT    NOT NULL REFERENCES platforms(id) ON DELETE CASCADE,
                played      INTEGER NOT NULL DEFAULT 0 CHECK (played IN (0, 1)),
                PRIMARY KEY (game_id, platform_id)
            );
            """)
        try db.execute(sql: "CREATE INDEX game_platforms_platform_idx ON game_platforms(platform_id);")
    }

    private static func createGameGenres(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE game_genres (
                game_id  INTEGER NOT NULL REFERENCES games(id)  ON DELETE CASCADE,
                genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
                PRIMARY KEY (game_id, genre_id)
            );
            """)
        try db.execute(sql: "CREATE INDEX game_genres_genre_idx ON game_genres(genre_id);")
    }

    // MARK: - Products (ownership)

    private static func createProducts(_ db: Database) throws {
        // A product is a thing you own on one platform: a single game or a
        // compilation of many. `platform_id` uses ON DELETE RESTRICT so a
        // platform that still has owned copies can never be deleted.
        try db.execute(sql: """
            CREATE TABLE products (
                id              INTEGER PRIMARY KEY,
                title           TEXT,
                platform_id     TEXT    NOT NULL REFERENCES platforms(id) ON DELETE RESTRICT,
                kind            TEXT    NOT NULL CHECK (kind   IN ('single','compilation')),
                format          TEXT    NOT NULL CHECK (format IN ('physical','digital')),
                edition         TEXT,
                region          TEXT,
                igdb_id         INTEGER,
                cover_file      TEXT,
                source          TEXT    NOT NULL CHECK (source IN ('manual','photo','psn')),
                psn_entitlement TEXT,
                acquired_at     DATETIME,
                created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """)
        try db.execute(sql: "CREATE INDEX products_platform_idx ON products(platform_id);")
    }

    private static func createProductGames(_ db: Database) throws {
        // The bridge that makes ownership all-or-nothing by construction:
        // deleting a product cascades away every member link at once.
        try db.execute(sql: """
            CREATE TABLE product_games (
                product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
                game_id    INTEGER NOT NULL REFERENCES games(id)    ON DELETE CASCADE,
                position   INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (product_id, game_id)
            );
            """)
        try db.execute(sql: "CREATE INDEX product_games_game_idx ON product_games(game_id);")
    }

    // MARK: - Ranking log

    private static func createComparisons(_ db: Database) throws {
        // Full duel log, never deleted (PLAN §7 — feeds contradiction
        // detection later). RankStore (Wave 3) writes here.
        try db.execute(sql: """
            CREATE TABLE comparisons (
                id         INTEGER PRIMARY KEY,
                winner_id  INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                loser_id   INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                context    TEXT    NOT NULL CHECK (context IN ('placement','refine')),
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """)
        try db.execute(sql: "CREATE INDEX comparisons_winner_idx ON comparisons(winner_id);")
        try db.execute(sql: "CREATE INDEX comparisons_loser_idx  ON comparisons(loser_id);")
    }

    // MARK: - Import staging

    private static func createImportTitles(_ db: Database) throws {
        // Generic staging table for every importer (PSN, GOG, …). Re-sync is
        // idempotent on (source, external_id); mappings persist. No trophy
        // details are ever stored.
        try db.execute(sql: """
            CREATE TABLE import_titles (
                id              INTEGER PRIMARY KEY,
                source          TEXT    NOT NULL,
                external_id     TEXT    NOT NULL,
                name            TEXT    NOT NULL,
                platform        TEXT,
                signals         TEXT,
                play_duration_s INTEGER,
                first_played_at DATETIME,
                last_played_at  DATETIME,
                matched_game_id INTEGER REFERENCES games(id) ON DELETE SET NULL,
                ignored         INTEGER NOT NULL DEFAULT 0 CHECK (ignored IN (0, 1)),
                UNIQUE (source, external_id)
            );
            """)
    }

    // MARK: - Caches / operational tables

    private static func createCatalogCache(_ db: Database) throws {
        // Makes repeat IGDB autocomplete instant/offline (PLAN §4/§9).
        try db.execute(sql: """
            CREATE TABLE catalog_cache (
                igdb_id    INTEGER PRIMARY KEY,
                json       TEXT     NOT NULL,
                fetched_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """)
    }

    private static func createEnrichmentJobs(_ db: Database) throws {
        // Persisted background job queue (PLAN §9): survives relaunch, retries
        // with backoff. One live job per (kind, game).
        try db.execute(sql: """
            CREATE TABLE enrichment_jobs (
                id              INTEGER PRIMARY KEY,
                kind            TEXT    NOT NULL CHECK (kind  IN ('metadata','cover','timeToBeat')),
                game_id         INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                state           TEXT    NOT NULL DEFAULT 'pending'
                                    CHECK (state IN ('pending','running','failed','done')),
                attempts        INTEGER NOT NULL DEFAULT 0,
                next_attempt_at DATETIME,
                last_error      TEXT,
                created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE (kind, game_id)
            );
            """)
        try db.execute(sql: "CREATE INDEX enrichment_jobs_ready_idx ON enrichment_jobs(state, next_attempt_at);")
    }

    private static func createAppState(_ db: Database) throws {
        // Generic key → JSON blob store. Holds the Codable resumable
        // placement/ranking session (PLAN §7 "Resumable, state lives in the
        // DB") and any other small app-scoped state.
        try db.execute(sql: """
            CREATE TABLE app_state (
                key        TEXT    NOT NULL PRIMARY KEY,
                json       TEXT    NOT NULL,
                updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """)
    }

    // MARK: - Full-text search

    private static func createGamesFTS(_ db: Database) throws {
        // External-content FTS5 over games(title, alt_titles). Kept in sync by
        // the triggers below so "Baphomet" finds "Broken Sword" via alt_titles.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE games_fts USING fts5(
                title,
                alt_titles,
                content='games',
                content_rowid='id'
            );
            """)
        try createGamesFTSTriggers(db)
    }

    /// The three sync triggers that keep `games_fts` in step with `games`. Shared
    /// by v1 and by v2's FTS rebuild so both produce identical triggers.
    private static func createGamesFTSTriggers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER games_ai AFTER INSERT ON games BEGIN
                INSERT INTO games_fts(rowid, title, alt_titles)
                VALUES (new.id, new.title, new.alt_titles);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER games_ad AFTER DELETE ON games BEGIN
                INSERT INTO games_fts(games_fts, rowid, title, alt_titles)
                VALUES ('delete', old.id, old.title, old.alt_titles);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER games_au AFTER UPDATE ON games BEGIN
                INSERT INTO games_fts(games_fts, rowid, title, alt_titles)
                VALUES ('delete', old.id, old.title, old.alt_titles);
                INSERT INTO games_fts(rowid, title, alt_titles)
                VALUES (new.id, new.title, new.alt_titles);
            END;
            """)
    }

    // MARK: - Seeds

    /// Default tier ladder S…F (PLAN §1/§7), classic tier-list palette, ordered
    /// best (0) to worst. Labels/colours are user-editable later. Idempotent via
    /// `INSERT OR IGNORE` on the fixed ids.
    static func seedTiers(_ db: Database) throws {
        let rows: [(Int64, String, String, String, Int)] = [
            (1, "S", "Masterpiece", "#FF7F7F", 0),
            (2, "A", "Excellent",   "#FFBF7F", 1),
            (3, "B", "Good",        "#FFDF7F", 2),
            (4, "C", "Average",     "#FFFF7F", 3),
            (5, "D", "Bad",         "#BFFF7F", 4),
            (6, "F", "Awful",       "#7FFF7F", 5),
        ]
        for (id, letter, label, color, sort) in rows {
            try db.execute(
                sql: "INSERT OR IGNORE INTO tiers (id, letter, label, color, sort) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, letter, label, color, sort]
            )
        }
    }
}

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

    // MARK: - v4 — Play Next: traits, IGDB rating, feedback, user-edited marker

    /// v4 adds the §7b recommendation schema (PLAN §4/§7b):
    ///  - `game_traits` — generic taste features (franchise / series / developer /
    ///    theme / mode / perspective / keyword / similar), filled by enrichment.
    ///    `similar` values are IGDB game ids as strings. Indexed on `(kind, value)`
    ///    for the affinity/direct-link lookups.
    ///  - `games.igdb_rating` / `igdb_rating_count` — the crowd prior for unranked
    ///    candidates.
    ///  - `rec_feedback` — the "not this one" memory (snooze / never / picked).
    ///  - `games.user_edited` — a compact text set of user-edited field names
    ///    (e.g. `"cover,summary"`) so enrichment can refresh untouched fields while
    ///    never overwriting an edited one (requested by the enrichment lane).
    ///
    /// Pure `ALTER TABLE ADD COLUMN` + `CREATE TABLE`, so no table rebuild and no
    /// deferred foreign-key checks are needed.
    static func registerV4(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE game_traits (
                    game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    kind    TEXT    NOT NULL CHECK (kind IN
                                ('franchise','series','developer','theme',
                                 'mode','perspective','keyword','similar')),
                    value   TEXT    NOT NULL,
                    PRIMARY KEY (game_id, kind, value)
                );
                """)
            try db.execute(sql: "CREATE INDEX game_traits_kind_value_idx ON game_traits(kind, value);")

            try db.execute(sql: "ALTER TABLE games ADD COLUMN igdb_rating REAL;")
            try db.execute(sql: "ALTER TABLE games ADD COLUMN igdb_rating_count INTEGER;")
            try db.execute(sql: "ALTER TABLE games ADD COLUMN user_edited TEXT NOT NULL DEFAULT '';")

            try db.execute(sql: """
                CREATE TABLE rec_feedback (
                    id         INTEGER PRIMARY KEY,
                    game_id    INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    action     TEXT    NOT NULL CHECK (action IN ('snooze','never','picked')),
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """)
            try db.execute(sql: "CREATE INDEX rec_feedback_game_idx ON rec_feedback(game_id, created_at);")
        }
    }

    // MARK: - v5 — shared importer cache + product idempotency (PLAN §14.2 / §14.3)

    /// v5 lays the schema for the shared importer machinery (GOG first, PSN next):
    ///
    ///  - `import_cache` — the §14.2 30-day response cache, one implementation for
    ///    every importer. Composite PK `(source, key)`, index on `(source, expires_at)`
    ///    for the "what is fresh / what is stale" sweep and for `wipe(source:)`.
    ///  - `import_cache_rejects` — the last 50 bogus responses per source, kept for
    ///    diagnostics with 4 KB excerpts (tokens / user ids / e-mail redacted **before**
    ///    they reach here — see ``ImportRedactor``). Pruned to 50/source by
    ///    ``ImportResponseCacheStore``, indexed on `(source, received_at)` for the prune.
    ///  - `products.external_id` + a **partial unique** index `(source, external_id)
    ///    WHERE external_id IS NOT NULL` — so a committed import Product is idempotent:
    ///    re-committing the same GOG/PSN product id creates nothing new (§14.3). The
    ///    `source` CHECK is widened to admit `'gog'` (it already allowed `'psn'`).
    ///
    /// Adding `external_id` and widening the CHECK both require rebuilding `products`
    /// (SQLite cannot ALTER a CHECK), done the standard create-copy-drop-rename way
    /// with deferred foreign-key checks so `product_games`' ON DELETE CASCADE does not
    /// fire while the old table is dropped (the v3 pattern).
    static func registerV5(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5", foreignKeyChecks: .deferred) { db in
            // (a) Rebuild products: + external_id, widened source CHECK.
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
                    source          TEXT    NOT NULL CHECK (source IN ('manual','photo','psn','gog')),
                    psn_entitlement TEXT,
                    external_id     TEXT,
                    acquired_at     DATETIME,
                    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """)
            try db.execute(sql: """
                INSERT INTO products_new
                    (id, title, platform_id, kind, format, edition, region, igdb_id,
                     cover_file, source, psn_entitlement, external_id, acquired_at,
                     created_at, updated_at)
                SELECT
                    id, title, platform_id, kind, format, edition, region, igdb_id,
                    cover_file, source, psn_entitlement, NULL, acquired_at,
                    created_at, updated_at
                FROM products;
                """)
            try db.execute(sql: "DROP TABLE products;")
            try db.execute(sql: "ALTER TABLE products_new RENAME TO products;")
            try db.execute(sql: "CREATE INDEX products_platform_idx ON products(platform_id);")
            // Idempotent import commits: one Product per (source, external_id).
            try db.execute(sql: """
                CREATE UNIQUE INDEX products_source_external_idx
                    ON products(source, external_id) WHERE external_id IS NOT NULL;
                """)

            // (b) Shared response cache (PLAN §14.2).
            try db.execute(sql: """
                CREATE TABLE import_cache (
                    source         TEXT     NOT NULL,
                    key            TEXT     NOT NULL,
                    endpoint       TEXT     NOT NULL,
                    params_json    TEXT     NOT NULL DEFAULT '{}',
                    fetched_at     DATETIME NOT NULL,
                    expires_at     DATETIME NOT NULL,
                    status         INTEGER  NOT NULL,
                    body           BLOB     NOT NULL,
                    item_count     INTEGER  NOT NULL DEFAULT 0,
                    schema_version INTEGER  NOT NULL DEFAULT 1,
                    PRIMARY KEY (source, key)
                );
                """)
            try db.execute(sql: "CREATE INDEX import_cache_expiry_idx ON import_cache(source, expires_at);")

            // (c) Reject ring buffer (last 50/source, pruned by the store).
            try db.execute(sql: """
                CREATE TABLE import_cache_rejects (
                    id           INTEGER PRIMARY KEY,
                    source       TEXT     NOT NULL,
                    endpoint     TEXT     NOT NULL,
                    params_json  TEXT     NOT NULL DEFAULT '{}',
                    received_at  DATETIME NOT NULL,
                    status       INTEGER,
                    reason       TEXT     NOT NULL,
                    body_excerpt TEXT     NOT NULL DEFAULT ''
                );
                """)
            try db.execute(sql: "CREATE INDEX import_cache_rejects_source_idx ON import_cache_rejects(source, received_at);")
        }
    }

    // MARK: - v6 — HLTB fallback id + per-game origin (PLAN §5.3, owner request)

    /// v6 adds two nullable `games` columns (pure `ALTER TABLE ADD COLUMN`, so no
    /// table rebuild and no deferred foreign-key checks):
    ///
    ///  - `hltb_id` — the HowLongToBeat game id kept when the HLTB fallback fills a
    ///    time estimate (PLAN §5.3), so "Open on HowLongToBeat" goes straight to the
    ///    exact page rather than a search.
    ///  - `origin` — how the *game* first entered the library, for debugging (owner
    ///    request). No CHECK constraint (a future importer adds a value without a
    ///    rebuild); validated in Swift by ``GameOrigin``. Backfilled from the source
    ///    of each game's **oldest** product (lowest product id via `product_games`),
    ///    falling back to `'manual'` for games with no product at all (played-only).
    static func registerV6(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE games ADD COLUMN hltb_id INTEGER;")
            try db.execute(sql: "ALTER TABLE games ADD COLUMN origin TEXT;")

            // Backfill origin from the oldest product's source; else 'manual'.
            try db.execute(sql: """
                UPDATE games SET origin = COALESCE(
                    (SELECT p.source
                       FROM products p
                       JOIN product_games pg ON pg.product_id = p.id
                      WHERE pg.game_id = games.id
                      ORDER BY p.id ASC
                      LIMIT 1),
                    'manual');
                """)
        }
    }

    // MARK: - v7 — drop the products.source CHECK (PLAN §5.5)

    /// v7 removes the CHECK constraint on `products.source` so future importers never
    /// need another table rebuild — the allowed set is validated in Swift by
    /// ``ProductSource`` instead (Delicious is the first source added this way). The
    /// table is rebuilt the standard create-copy-drop-rename way with deferred foreign-key
    /// checks (the v5 pattern): all columns and rows are preserved, the platform index and
    /// the partial unique `(source, external_id)` index are recreated. `product_games`'
    /// `ON DELETE CASCADE` is why the FK checks are deferred while the old table is dropped.
    ///
    /// NOTE(orchestrator): this is registered after v6 (which landed from the HLTB lane on
    /// the merge). If v6 had not yet landed it would still be named v7; the orchestrator
    /// resolves the final numbering at merge.
    static func registerV7(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7", foreignKeyChecks: .deferred) { db in
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
                    source          TEXT    NOT NULL,
                    psn_entitlement TEXT,
                    external_id     TEXT,
                    acquired_at     DATETIME,
                    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """)
            try db.execute(sql: """
                INSERT INTO products_new
                    (id, title, platform_id, kind, format, edition, region, igdb_id,
                     cover_file, source, psn_entitlement, external_id, acquired_at,
                     created_at, updated_at)
                SELECT
                    id, title, platform_id, kind, format, edition, region, igdb_id,
                    cover_file, source, psn_entitlement, external_id, acquired_at,
                    created_at, updated_at
                FROM products;
                """)
            try db.execute(sql: "DROP TABLE products;")
            try db.execute(sql: "ALTER TABLE products_new RENAME TO products;")
            try db.execute(sql: "CREATE INDEX products_platform_idx ON products(platform_id);")
            try db.execute(sql: """
                CREATE UNIQUE INDEX products_source_external_idx
                    ON products(source, external_id) WHERE external_id IS NOT NULL;
                """)
        }
    }

    // MARK: - v8 — PS Plus / subscription copies (PLAN §13.3)

    /// v8 adds `products.subscription TEXT` (PLAN §13.3 "PS Plus copies"): `NULL` = a copy
    /// I really own; `'ps_plus'` = a PlayStation Plus claim, a licence that **expires with
    /// the subscription**. The column is free text (validated in Swift by
    /// ``ProductSubscription``, which tolerates an unknown membership string) so another
    /// service's subscription tier needs no rebuild. A partial index over the non-NULL
    /// values backs the Format ▸ "PS Plus" facet ("games whose only owned copies are
    /// subscription copies") without scanning every product.
    ///
    /// Pure `ALTER TABLE ADD COLUMN` + `CREATE INDEX`, so no table rebuild and no deferred
    /// foreign-key checks (the v4/v6 pattern). Existing rows get `subscription = NULL`
    /// (really owned), which is exactly right for every copy imported before PSN.
    static func registerV8(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8") { db in
            try db.execute(sql: "ALTER TABLE products ADD COLUMN subscription TEXT;")
            try db.execute(sql: """
                CREATE INDEX products_subscription_idx
                    ON products(subscription) WHERE subscription IS NOT NULL;
                """)
        }
    }

    // MARK: - v9 — first / last played dates (PLAN §13.3, PSN import)

    /// v9 adds two nullable `games` columns filled **only by importers** (never typed by
    /// the owner): the earliest and latest date a game is known to have been played.
    /// PSN is the first source (trophy `firstPlayedDateTime` / `lastPlayedDateTime` and the
    /// game list's play dates, PLAN §13.3); the inspector shows "Last played 12 Mar 2021"
    /// in the played section, and ``LibrarySort/lastPlayed`` sorts by it (NULLs last).
    ///
    ///  - `first_played_at` — the earliest known play date (only ever moves **earlier**).
    ///  - `last_played_at`  — the latest known play date (only ever moves **later**; a
    ///    re-sync never moves it backwards, and a NULL never overwrites a known value —
    ///    see ``LibraryStore/setPSNPlayedDates(gameID:first:last:db:)``).
    ///
    /// Pure `ALTER TABLE ADD COLUMN` (the v4/v6/v8 pattern) — no table rebuild, no deferred
    /// foreign-key checks. Existing rows get NULL (unknown), which is exactly right.
    static func registerV9(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9") { db in
            try db.execute(sql: "ALTER TABLE games ADD COLUMN first_played_at DATETIME;")
            try db.execute(sql: "ALTER TABLE games ADD COLUMN last_played_at DATETIME;")
        }
    }

    // MARK: - v10 — Batocera ROM catalogue (PLAN §15, phase 1)

    /// v10 adds the **ROM catalogue** — "the shelf in the cellar" (PLAN §15). It is a
    /// completely separate table from `games`: nothing in Library, the grid, counts, stats,
    /// ranking or exports ever reads it. Only a *promotion* copies a catalogue entry into
    /// `games` through the normal importer path, at which point `rom_catalog.promoted_game_id`
    /// links the two.
    ///
    ///  - `rom_catalog` — one row per folded ROM (system + relative path is the stable
    ///    identity; `md5` / `screenscraper_id` are secondary keys). Carries the scraped
    ///    metadata (genre / family / developer / year / rating) and Batocera's own play data
    ///    (`play_count` / `game_time_s` / `last_played_at` / `favorite`), so it is browsable,
    ///    searchable and taste-scorable with **no** IGDB call. `promoted_game_id REFERENCES
    ///    games ON DELETE SET NULL` (a promoted game deleted from the library just unlinks —
    ///    the catalogue row survives). `not_interested` / `dismissed_at` retire a title from
    ///    the future Discover row.
    ///  - `rom_catalog_sync` — per-system change detection: the last-read `gamelist.xml`
    ///    mtime + size, so an unchanged system is skipped on the next sync.
    ///  - `rom_catalog_fts` — external-content FTS5 over (name, normalised_title) with the
    ///    same diacritics-insensitive tokenizer as `games_fts`, kept in step by three
    ///    triggers, for fast search at ~15 000 rows.
    ///
    /// Pure `CREATE TABLE` / `CREATE INDEX` / `CREATE VIRTUAL TABLE`, so no table rebuild and
    /// no deferred foreign-key checks. Fresh installs and v9 upgrades get an empty catalogue.
    static func registerV10(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10") { db in
            try db.execute(sql: """
                CREATE TABLE rom_catalog (
                    id                INTEGER PRIMARY KEY,
                    source            TEXT     NOT NULL DEFAULT 'batocera',
                    system            TEXT     NOT NULL,
                    platform_id       TEXT     REFERENCES platforms(id) ON DELETE SET NULL,
                    relative_path     TEXT     NOT NULL,
                    name              TEXT     NOT NULL,
                    sort_title        TEXT     NOT NULL DEFAULT '',
                    normalised_title  TEXT     NOT NULL DEFAULT '',
                    libretro_key      TEXT     NOT NULL DEFAULT '',
                    screenscraper_id  TEXT,
                    md5               TEXT,
                    region            TEXT,
                    lang              TEXT,
                    genre             TEXT,
                    family            TEXT,
                    developer         TEXT,
                    publisher         TEXT,
                    release_year      INTEGER,
                    rating            REAL,
                    players           TEXT,
                    play_count        INTEGER NOT NULL DEFAULT 0,
                    game_time_s       INTEGER NOT NULL DEFAULT 0,
                    last_played_at    DATETIME,
                    favorite          INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
                    image_path        TEXT,
                    thumbnail_path    TEXT,
                    first_seen_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    last_seen_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    removed_at        DATETIME,
                    promoted_game_id  INTEGER REFERENCES games(id) ON DELETE SET NULL,
                    dismissed_at      DATETIME,
                    not_interested    INTEGER NOT NULL DEFAULT 0 CHECK (not_interested IN (0, 1)),
                    UNIQUE (source, system, relative_path)
                );
                """)
            try db.execute(sql: "CREATE INDEX rom_catalog_system_idx    ON rom_catalog(system);")
            try db.execute(sql: "CREATE INDEX rom_catalog_platform_idx  ON rom_catalog(platform_id);")
            try db.execute(sql: "CREATE INDEX rom_catalog_promoted_idx  ON rom_catalog(promoted_game_id);")
            try db.execute(sql: "CREATE INDEX rom_catalog_sort_idx      ON rom_catalog(system, sort_title);")
            try db.execute(sql: "CREATE INDEX rom_catalog_libretro_idx  ON rom_catalog(system, libretro_key);")

            try db.execute(sql: """
                CREATE TABLE rom_catalog_sync (
                    source         TEXT     NOT NULL DEFAULT 'batocera',
                    system         TEXT     NOT NULL,
                    gamelist_mtime DATETIME,
                    gamelist_size  INTEGER  NOT NULL DEFAULT 0,
                    last_read_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    entry_count    INTEGER  NOT NULL DEFAULT 0,
                    PRIMARY KEY (source, system)
                );
                """)

            // External-content FTS5 over rom_catalog(name, normalised_title). Same
            // diacritics-insensitive tokenizer as games_fts (v2).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE rom_catalog_fts USING fts5(
                    name,
                    normalised_title,
                    content='rom_catalog',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
            try db.execute(sql: """
                CREATE TRIGGER rom_catalog_ai AFTER INSERT ON rom_catalog BEGIN
                    INSERT INTO rom_catalog_fts(rowid, name, normalised_title)
                    VALUES (new.id, new.name, new.normalised_title);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER rom_catalog_ad AFTER DELETE ON rom_catalog BEGIN
                    INSERT INTO rom_catalog_fts(rom_catalog_fts, rowid, name, normalised_title)
                    VALUES ('delete', old.id, old.name, old.normalised_title);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER rom_catalog_au AFTER UPDATE ON rom_catalog BEGIN
                    INSERT INTO rom_catalog_fts(rom_catalog_fts, rowid, name, normalised_title)
                    VALUES ('delete', old.id, old.name, old.normalised_title);
                    INSERT INTO rom_catalog_fts(rowid, name, normalised_title)
                    VALUES (new.id, new.name, new.normalised_title);
                END;
                """)
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

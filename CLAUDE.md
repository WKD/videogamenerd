# VGN — Video Game Nerd

Native macOS app to catalogue every game I've owned or played, and rank them
(tiers + one ultimate Top). Spec: **`PLAN.md`**. Process/rules for the parallel
build: **`docs/EXECUTION.md`** (binding; PLAN.md wins on *what*, EXECUTION on *how*).

## Build / test / run

Build and test with a scoped DerivedData so parallel worktree builds don't collide:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd build
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd test
```

Run the built app:

```sh
open .build/dd/Build/Products/Debug/Video\ Game\ Nerd.app
```

Run a single test (Swift Testing) by name, or a whole suite:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd test -only-testing:VGNTests/SmokeTests/sqliteHasFTS5
xcodebuild ... test -only-testing:VGNTests/ScalePerfTests    # perf numbers (DEBUG, printed)
```

Release-ish build (optimised, what you'd actually run day to day):

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -configuration Release -derivedDataPath .build/dd build
```

`.build/` is git-ignored. `VGN` is the only shared scheme; it builds + tests from a
fresh clone.

### Launch arguments (`LaunchMode`)

Never launch a dev build against the owner's real library. Use:

- `-VGNSampleData YES` → throwaway **in-memory** DB seeded with the sample library
  (demos, UI checks); no real file, no network.
- `-VGNSeedGames <n>` (DEBUG) → throwaway in-memory DB with `n` synthetic games for
  perf work (`PerfSeeder`).
- default (no args) → the live on-disk database at `~/Library/Application Support/VGN/`.

```sh
open .build/dd/Build/Products/Debug/Video\ Game\ Nerd.app --args -VGNSampleData YES
```

## Toolchain

macOS 15 deployment, built against the macOS 26 SDK. Xcode 26.x / Swift 6.
Requires `xcode-select -s /Applications/Xcode.app`.

## Project conventions

- **Single app target `VGN`** + unit-test target `VGNTests` (hosted by the app,
  Swift Testing, `@testable import VGN`). Internal-by-default — no `public` tax.
- **Folder-synchronised groups** (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77).
  Any file created on disk under `VGN/` or `VGNTests/` is picked up automatically:
  `.swift` compiled, everything else (`.json`, `.plist`, `.jpg`, `.xcassets`) copied
  as a bundle resource. **Never edit `project.pbxproj` to add files** — just drop
  them in. Only edit the pbxproj for targets, build settings or package deps.
- **Layering by folder, enforced by discipline** (not separate modules):
  - `VGN/Model/` — plain `Sendable`/`Hashable`/`Identifiable` value types (contracts
    for the UI lane). Foundation only.
  - `VGN/Ranking/` and `VGN/Matching/` — **pure logic**: Foundation only, no
    GRDB / SwiftUI / AppKit imports; operate on plain values (`Int64` ids, keys).
  - `VGN/Database/` — GRDB, the schema and migrations (**one closure per version**,
    owned by the Database lane). All schema changes go through a new numbered
    migration there.
  - `VGN/Services/`, `VGN/UI/` — everything else.
- **Swift 6 language mode, strict concurrency.** UI state in `@MainActor @Observable`
  stores; all I/O in actors. Target zero warnings. Do **not** set
  `SWIFT_DEFAULT_ACTOR_ISOLATION` (code must stay nonisolated-by-default).
- **GRDB 7 is the only dependency** (SwiftPM, `upToNextMajor` from 7.0.0). No XcodeGen.
- **No network in tests** — stub with `URLProtocol` + recorded fixtures. Strip
  credentials/tokens from anything recorded.
- IDs: `Int64` row ids for games/products/tiers; platform id = slug `String`
  (`ps5`, `snes`, `pc`, `mac`). Fine-rank key aliased once as `RankKey` in
  `VGN/Model/RankKey.swift`.

## Architecture map (per folder)

- `VGN/Model/` — plain `Sendable` value types the UI consumes (`GameSummary`,
  `LibraryFilter`, `SidebarSelection`, `Tier`, `PlayNextTypes`, `GameTrait`…).
- `VGN/Ranking/` — **pure** tier/duel engine (Foundation only): sparse `RankKeySpace`,
  `PlacementSession` (binary insertion), `RankMoves`, `RefineMode`, `Consistency`
  (invariants + contradiction cycles), `DerivedScore` (1–10 bands), `GlobalRank`,
  `TierDividerMove`.
- `VGN/Matching/` — **pure** title work: `TitleNormalizer` (the fold/canonical/
  articleless/core ladder), `FuzzyMatch`, `Dedupe`, `LibretroIndex`/`LibretroFilename`.
- `VGN/Recommendation/` — **pure** Play Next engine (Foundation only): `TimeFit`,
  `TasteScoring`, `DirectLinks`, `CrowdPrior`, `RecommendationEngine`, `TasteBacktest`.
- `VGN/Database/` — GRDB. `AppDatabase` (pool/queue factories + migrator),
  `Migrations` (**one closure per version, lane A only** — v1 is the whole PLAN §4
  schema; v2 FTS/sort rebuild; v3 `rom` format; v4 Play Next tables; v5 shared importer
  cache `import_cache`/`import_cache_rejects` + `products.external_id` idempotency, GOG/PSN §14.2;
  v6 `games.hltb_id` (HLTB fallback §5.3) + `games.origin`, backfilled from each game's oldest product;
  v7 drops the `products.source` CHECK — validated in Swift via `ProductSource`, so file/importer sources
  (Delicious §5.5) add no rebuild;
  v8 `products.subscription` (NULL = really owned, `'ps_plus'` = a PS Plus claim; free text, tolerant
  `ProductSubscription`) + a partial index — PS Plus copies §13.3;
  v9 `games.first_played_at` / `games.last_played_at` (nullable, **importer-filled only**, never
  typed — PSN §13.3; monotonic via `LibraryStore.setPSNPlayedDates`)). `LibraryStore`
  (writes, invariants), `LibraryQuery` (grid SQL), `RankingStore` (tier/duel data
  side, resumable state in `app_state`), `RecommendationStore`, `CatalogTitleIndex`,
  `EnrichmentJobStore`, `LibraryExporter` (JSON/CSV), `AppDatabase+Snapshot`
  (backup + `restore`).
- `VGN/Services/` — everything with I/O, behind protocols where PLAN names one:
  `IGDB/` (token actor, rate limiter, Apicalypse), `Covers/` (`CoverStore` actor +
  `CoverProvider` chain), `Enrichment/` (`EnrichmentCoordinator` actor + job queue),
  `TimeToBeat/`, `Keychain/`, `Networking/` (transport, `RateLimiter`, `Retry`,
  monotonic `ServiceClock`, `AsyncSemaphore`), `ClaudeCLI/` (`ClaudeProcessRunner`),
  `Recognition/` (photo scan), `SecondOpinion/` ("Ask Claude").
- `VGN/UI/`, `VGN/VGNApp.swift`, `VGN/AppEnvironment.swift` — SwiftUI + the composition
  root. `@MainActor @Observable` stores adapt DB observations to Model value types.

**Data-safety invariants** (PLAN §4, enforced by DB CHECKs *and* `LibraryStore`):
played-or-owned (removing the last leaves a game orphaned → `.wouldOrphan`, never a
silent delete); only played games carry a tier/rank; rank order is consistent with
tiers. Enrichment honours the `games.user_edited` marker and only fills empty fields
(unless an explicit refresh). Every write method is one transaction.

## On-disk layout

```
~/Code/videogamenerd/          container (NOT a repo)
├── samples/                   original shelf photos — git-ignored, read-only
├── main/                      checkout of `main` — only the orchestrator writes here
└── worktrees/<name>/          one git worktree + branch per agent task
```

## Parallel development (how this repo is built)

Work is done by an **orchestrator** session (started in the container folder) plus up
to **3 parallel subagents on Opus**, each in its own worktree. Full rules and the wave
table: `docs/EXECUTION.md`. The essentials:

- **Lanes** keep files from colliding: A = data & logic (`Database`, `Model`, `Ranking`,
  `Matching`; sole owner of migrations), B = services then feature verticals
  (`Services/**`, later its own `UI/<Feature>/`), C = UI (shell, sidebar, grid,
  inspector, feature folders). Every brief lists **owned paths**; hot files
  (`VGNApp.swift`, migrations, `SidebarSelection`, `project.pbxproj`, `CLAUDE.md`,
  `.gitignore`) have one owner per wave.
- **Worktrees** are created by the orchestrator:
  `git -C main worktree add ../worktrees/w<wave>-<lane>-<topic> -b w<wave>/<lane>-<topic>`.
  Agents work only inside theirs, build with `-derivedDataPath <worktree>/.build/dd`,
  commit feature-sized commits (each green), and **never push, rebase, or touch `main/`**.
- **Merge & push per feature**, not per wave: `merge --no-ff` into `main` → build + test
  on main → push. Never force-push. Milestones are tagged `m0`…`m6` and the tags pushed.
  Merged worktrees/branches are removed.
- Human-only acceptance checks are collected in `docs/ACCEPTANCE.md`; known limitations, shortcuts and postponed work in `docs/LIMITATIONS.md` — update it whenever a hand-off report flags one.

App support dir at runtime: `~/Library/Application Support/VGN/`
(`vgn.sqlite`, `covers/`, `thumbs/`, `backups/`). Tests use in-memory / temp-dir
DBs, never the real one.

## Testing conventions

- Swift Testing (`import Testing`, `@testable import VGN`), target `VGNTests`, hosted
  by the app. **No network** — stub with `URLProtocol` + recorded fixtures; strip
  credentials from anything recorded. **No real Keychain** (one guarded round-trip
  test exists — keep it guarded), **no real Application Support dir** (use
  `AppDatabase.inMemory()` / `.temporary()`).
- **`@MainActor` tests that touch GRDB must sit in a `@Suite(.serialized)`** — parallel
  ones deadlock under Swift Testing. Give every async test a hard timeout. `UndoManager.undo()`
  hangs headless (assert `canUndo` + apply the inverse directly).
- **Clicks can be tested headless:** `ClickProbeWindow` (`VGNTests/UI/FilterChipsClickTests.swift`) hosts a view in an off-screen window shaped like the app's (unified toolbar, full-size content, never key) and sends real mouse events. Use it for any "is this control actually clickable?" question — model tests cannot see hit-testing bugs. Known trap it guards: a **horizontal `ScrollView` whose top edge touches the window toolbar never delivers clicks to its buttons** (vertical ones are fine) — use a wrapping row (`RankingFlowLayout`) there. Likewise never stack `onTapGesture` + `TapGesture().modifiers(…)`: the plain tap wins; read the modifiers inside one tap handler (`GameCell.clickKind`).
- **No wall-clock assertions.** Perf tests (`ScalePerfTests`, `GridQueryPerfTests`,
  the `PerformanceTests`/`RecommendationStore` perf cases) assert correctness and
  **print** timings — never `#expect(ms < …)`, which flakes under parallel load.
  Deterministic time via the injected `ServiceClock` (`ManualClock` in tests) and, for
  the cover negative-cache TTL, `CoverStore`'s injected wall-clock closure.
- **Suites as they exist now:** `VGNTests/UI/**` (UI-model + fake-backend tests, several
  `@Suite(.serialized)`) is owned by the UI lanes; `VGNTests/Snapshots/**` (off-screen
  PNG renders) and a `VGNUITests` XCUITest target are added by the hardening UI lanes —
  the UI suite is not part of the default `xcodebuild test` gate (it takes over the
  keyboard/mouse and needs a one-time permission grant). Everything else is the normal gate.

## Scripts & recording fixtures

`scripts/` (run with `swift scripts/<name>.swift`; live recorders need
`~/.config/vgn/igdb.env` = `IGDB_CLIENT_ID`/`IGDB_CLIENT_SECRET`, never committed —
strip `Authorization`/`Client-ID` and tokens from anything recorded):

- `record-igdb-fixtures.swift` — refresh the IGDB search/game/bundle/time-to-beat JSON in
  `VGNTests/Fixtures/`.
- `record-libretro-fixture.swift` / `record-vision-fixture.swift` — libretro tree + Vision OCR fixtures.
- `record-hltb-fixtures.swift` — bounded (≤ 25 requests, ≥ 2 s apart, stop on first unexpected response) HowLongToBeat recorder → `VGNTests/Fixtures/hltb-*.json` (PLAN §5.3, `docs/hltb.md`). No credentials.
- `crop-tiles.swift` — regenerate shelf tiles from the (git-ignored) originals in `../samples/` (see `docs/fixtures.md`).
- `smoke-live.swift` — one live IGDB round-trip to sanity-check credentials.
- `scan-accuracy.sh` — arms the gated photo-scan accuracy harness (`docs/recognition-accuracy.md`); inert otherwise.
- `validate-platforms.sh` — lint `VGN/Resources/platforms.json`.
- `snapshots.sh` / `uitests.sh` — the hardening UI lanes' snapshot render + XCUITest runners.

Fixture rules: bundle resources are flattened, so **fixture file names must be unique**
per bundle (prefix by topic, e.g. `igdb-search-bloodborne.json`). Swift file basenames
and top-level type names must be unique across the whole target.

## Identity

Bundle id **`com.pomatelier.VideoGameNerd`** (tests: `…Tests`, `…UITests`), product / display name **"Video Game Nerd"** (`Video Game Nerd.app`). The Swift module, target, scheme and executable/process name stay **`VGN`** (`PRODUCT_MODULE_NAME`, `EXECUTABLE_NAME`), so `@testable import VGN`, `pgrep -x VGN` and the test host path keep working. Keychain service = the bundle id; the data folder stays `~/Library/Application Support/VGN/`.

## Signing

**Sign to Run Locally** for now: `CODE_SIGN_IDENTITY = "-"`, no team.
App Sandbox **off** (the photo scanner spawns the `claude` CLI; a sandboxed app
can't). Hardened runtime is on in settings but ad-hoc signing effectively relaxes
it locally — expect the "Disabling hardened runtime with ad-hoc codesigning" note.

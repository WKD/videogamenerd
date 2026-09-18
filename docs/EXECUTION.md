# VGN — Execution plan (milestones 0–6)

How PLAN.md is being built: one orchestrator session + 3 parallel subagents per wave. PLAN.md is the spec; this file is the process. If the two disagree on *what* to build, PLAN.md wins.

## Layout on disk

```
~/Code/videogamenerd/          container (NOT a repo)
├── samples/                   original shelf photos (IMG_3681…3686.png, ~25 MB each) — never in git
├── main/                      checkout of `main` — ONLY the orchestrator writes here
└── worktrees/<name>/          one git worktree + branch per agent task
```

IGDB credentials for fixture recording / live smoke tests: `~/.config/vgn/igdb.env` (`IGDB_CLIENT_ID`, `IGDB_CLIENT_SECRET`). Never print, log, commit or copy them into the repo or into fixtures (strip `Authorization`/`Client-ID` headers and tokens from anything recorded).

## Rules for agents

1. Work **only** inside your assigned worktree (absolute path given in your brief). Never touch `main/`, another worktree, or `samples/` (read-only).
2. Touch **only the paths your brief lists as owned**. Hot files (`VGNApp.swift`, `VGN/Database/Migrations*`, `SidebarSelection`, `project.pbxproj`, `CLAUDE.md`, `.gitignore`) have exactly one owner per wave. Need a change elsewhere? Say so in your handoff instead of making it.
3. Schema changes go through lane A only.
4. No new dependencies (GRDB 7 is the only SwiftPM package). No XcodeGen. Files are picked up via folder-synchronised groups — never edit the pbxproj to add files.
5. Swift 6 language mode, strict concurrency, zero warnings as the target. Swift Testing (`import Testing`, `@testable import VGN`). **No network in tests** — stub with `URLProtocol` + recorded fixtures.
6. Build/test with your own DerivedData so parallel builds don't collide:
   `xcodebuild -project <worktree>/VGN.xcodeproj -scheme VGN -destination 'platform=macOS' -derivedDataPath <worktree>/.build/dd build` (same with `test`). Use absolute paths / `git -C <worktree>`; avoid `cd`.
7. Commit on your branch in **feature-sized commits** (each one builds + tests green) — the orchestrator merges and pushes per feature. Never push, never rebase/merge main yourself, never force anything. End commit messages with the `Co-Authored-By` attribution line your session's guidance specifies.
8. Follow PLAN.md's decisions; don't re-litigate them. If something in PLAN.md is impossible or clearly wrong, take the closest sensible path and flag it in the handoff.
9. Finish with a **handoff report**: what's done (commits), public API other lanes will call, what is stubbed/faked, deviations from PLAN.md, anything you needed from another lane, and what a human must verify by eye.

## Shared conventions (contracts)

- IDs: `Int64` row ids for games/products/tiers; platform id = slug `String` (e.g. `ps5`, `snes`, `pc`, `mac`).
- `VGN/Ranking` and `VGN/Matching` are pure: Foundation only, no GRDB/SwiftUI/AppKit imports, operate on plain values (`Int64` ids, `RankKey` rank keys — type decided by the Ranking lane in Wave 0, expected `Int64`).
- UI views take value types (`GameSummary`, `SidebarCounts`, `LibraryFilter`, `SidebarSelection`) defined in `VGN/Model/`; stores (`@MainActor @Observable`) adapt DB observations to them. Views ship with preview/sample data.
- Migration v1 holds the **entire** PLAN §4 schema (+ `enrichment_jobs`). Later schema needs = new numbered migration, lane A.
- Services sit behind protocols where PLAN names one (`CoverProvider`, `TimeToBeatProvider`, `ShelfRecognizer`, `LibraryImporter`).
- App support dir: `~/Library/Application Support/VGN/` (`vgn.sqlite`, `covers/`, `thumbs/`, `backups/`). Tests use in-memory / temp-dir DBs, never the real one.

- **Swift file basenames and top-level type names must be unique across the whole target** (one module): two `PlatformCatalog.swift` in different folders fail the build. Name files/types after their lane's concern (`IGDBModels.swift`, not `Models.swift`); avoid generic names another lane might pick (`Errors`, `Extensions`, `Constants`, `Catalog`).
- **Bundle resources are flattened.** Synchronised groups copy every non-Swift file into the bundle's `Resources/` root regardless of subfolder. So resource/fixture **file names must be unique per bundle** (app: `VGN/**`, tests: `VGNTests/**`) — prefix fixtures by topic (`igdb-search-bloodborne.json`, not `igdb/search.json`). Already taken in the test bundle: `platforms.json` (IGDB platform dump), `IMG_368x.jpg`, `tile*.jpg`. Load with `Bundle.main.url(forResource:withExtension:)` in the app; in tests use a `Bundle(for:)`-style lookup on a class defined in the test target.
- `VGN/Resources/platforms.json` (61 platforms) fields: `id, name, short, manufacturer, group, kind, generation?, igdbIDs [Int], libretroRepo?, sort`. The sidebar groups by **`group`** (Sony, Nintendo, Sega, Microsoft, Atari, NEC, SNK, Computer, Arcade, Other), `sort` ascending within group. `libretroRepo` is read straight from the platform — there is no separate plist.

## Waves

| Wave | Agent A | Agent B | Agent C | Tags |
|---|---|---|---|---|
| 0 Skeleton | `VGN.xcodeproj` (hand-written, synchronised groups, GRDB 7, Swift 6, macOS 15.0, sandbox off, hardened runtime, Sign to Run Locally, shared scheme), minimal app + 1 test green from CLI, `CLAUDE.md`, shared value types in `VGN/Model/` | `VGN/Resources/platforms.json` (+ IGDB ids, libretro repos), `LibretroRepoMapping.plist` from romlord, downsized JPEG fixtures + tiles in `VGNTests/Fixtures/` | Pure logic + exhaustive tests: `VGN/Ranking/` (RankingEngine: binary insertion, sparse keys, renumber, invariants), `VGN/Matching/` (normalisation, fuzzy, libretro tag ladder), `PlaytimeParser` | — |
| 1 M0 finish + M1 foundations | Database: pool, v1 full schema, FTS5 + triggers, seeds, `LibraryStore` writes w/ invariants incl. compilation transactions, observations (sidebar counts, grid rows), launch snapshots | IGDB client (token actor, rate limiter, search / games / bundles / time-to-beat, recorded fixtures); `CoverStore` actor + IGDB & libretro providers | App shell: split view, sidebar, grid + cell, inspector skeleton, Settings + `KeychainStore` | `m0` |
| 2 M1 | (started early, as soon as the DB merged) `RankingStore`: snapshot + mutation applier, persisted/resumable duels with undo, refine + border duels, tier board / Top observations; `sort_title`; FTS v2 (diacritics, multi-token prefix, safe escaping) | After services merge: Quick Add palette (full keyboard flow) | After shell merge: live wiring of sidebar/grid/inspector to `LibraryStore`, cover loading + prefetch via `CoverStore`, `O`/`P`/tier keys, inspector on `GameDetail`. Then: persisted enrichment queue (metadata, covers, DB-backed `catalog_cache`, backoff/resume) — goes to whichever lane frees up first | `m1` |
| 3 M2 + M3 | TTB enrichment job, status/playtime ops, whatever M2/M3 need from the data layer | M2 UI: search, filters + chips, sort, size slider, multi-select, tier keys | M3 UI: compilation editor, "Add as compilation", stack marker, all-or-nothing ownership UX | `m2` `m3` |
| 4 M4 + M5 UI, M6 engine | M6 pipeline: tiler, `ClaudeCLIRecognizer`, Vision OCR + serial codes, overlap merge, IGDB match scoring | Triage + Duel views; playtime/status inspector UI, me-vs-average bar | Tier Board (drag), The Top (dividers, podium, filters, CSV export) | `m4` `m5` |
| 5 M6 + hardening | Scan review sheet, photo input, scan Settings, single-transaction add | Accuracy harness over the 6 real samples + prompt/tiling tuning | Hardening: concurrency warnings, debug seed for perf, review of the merged whole, CLAUDE.md refresh | `m6` |

**Milestone 5b — Play Next + ROM format** (added 2026-09-18, PLAN §7b) is woven into the waves: ROM format → data lane now (migration + `ProductFormat.rom` + format filter), Quick Add `⌘D` and the ROM badge with the Quick Add / M2 UI work; `VGN/Recommendation/` pure engine + backtest → data lane once `RankingStore` is merged (it only needs plain values); `game_traits` / IGDB rating / `rec_feedback` schema + enrichment fields → with the enrichment queue; Play Next view → wave 4–5 UI. Tag `m5b`. "Ask Claude" second opinion is an open owner decision — not built unless confirmed.

HLTB optional provider: skipped in this run.

The table is a plan, not a contract: the orchestrator re-sequences as lanes free up (a lane never idles waiting for a wave boundary), keeping at most 3 agents running and the owned-paths rule intact.

## Integration (orchestrator)

Per finished feature: merge branch → `main` (`--no-ff`), `xcodebuild build` + `test` on main, launch smoke test at milestone boundaries, push. Milestone tags `m0`…`m6` pushed when their "done when" is met as far as machines can tell; human-only acceptance items are collected in `docs/ACCEPTANCE.md`.

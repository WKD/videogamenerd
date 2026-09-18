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
- **Test hygiene learned the hard way:** any `@MainActor` test that touches GRDB goes in a `@Suite(.serialized)` (parallel ones deadlock under Swift Testing — see `VGNTests/UI/LiveWiringTests.swift`); every async test gets a hard timeout so a missed emission fails instead of hanging; `UndoManager.undo()` hangs in the headless host (assert `canUndo` + apply the inverse directly); under the XCTest host `AppEnvironment` builds nothing (no live DB, no services). Never run a dev build against the owner's real library (`~/Library/Application Support/VGN/`) — use `-VGNSampleData YES`. Never take full-screen screenshots.
- **Bundle resources are flattened.** Synchronised groups copy every non-Swift file into the bundle's `Resources/` root regardless of subfolder. So resource/fixture **file names must be unique per bundle** (app: `VGN/**`, tests: `VGNTests/**`) — prefix fixtures by topic (`igdb-search-bloodborne.json`, not `igdb/search.json`). Already taken in the test bundle: `platforms.json` (IGDB platform dump), `IMG_368x.jpg`, `tile*.jpg`. Load with `Bundle.main.url(forResource:withExtension:)` in the app; in tests use a `Bundle(for:)`-style lookup on a class defined in the test target.
- `VGN/Resources/platforms.json` (61 platforms) fields: `id, name, short, manufacturer, group, kind, generation?, igdbIDs [Int], libretroRepo?, sort`. The sidebar groups by **`group`** (Sony, Nintendo, Sega, Microsoft, Atari, NEC, SNK, Computer, Arcade, Other), `sort` ascending within group. `libretroRepo` is read straight from the platform — there is no separate plist.

## How this was built

Milestones 0–6 (plus 5b Play Next) were built by an orchestrator + up to 3 parallel
Opus subagents, one worktree each, sequenced by the lane rule above rather than by a
fixed wave plan (a lane never idled at a wave boundary). Rough order:

- **Skeleton:** hand-written `VGN.xcodeproj` (synchronised groups, GRDB 7, Swift 6,
  macOS 15, sandbox off), the pure logic layers (`Ranking/`, `Matching/`,
  `Recommendation/`) with exhaustive tests, `platforms.json`, and the downsized shelf
  fixtures — all before any UI.
- **Data + services:** the v1 schema + `LibraryStore` (invariants, compilation
  transactions, observations, launch snapshots); the IGDB client (token actor, rate
  limiter, recorded fixtures); the `CoverStore` actor + provider chain; the persisted
  enrichment queue.
- **UI verticals:** shell/sidebar/grid/inspector wiring, Quick Add palette, search +
  filters, compilation editor, the ranking views (Tier Board, The Top, Duel/Triage),
  playtime UI, Play Next + "Ask Claude", and the photo-scan review sheet.
- **Hardening (wave 6):** UI lanes A/B add off-screen **snapshot** render tests and a
  `VGNUITests` XCUITest smoke target (window-only screenshots, run on demand — not part
  of the normal gate, it takes over the keyboard and needs a permission grant). Lane C
  (this file's author) did the non-UI engineering review: concurrency + data-safety
  audit, real bug fixes with tests, the LIMITATIONS closers, perf at 2 k/10 k, and docs.

Milestone tags `m0`…`m6` (+ `m5b`) were pushed in completion order. Treat git history +
`docs/LIMITATIONS.md` as the record; PLAN §10 has the milestone definitions.

## How to continue

- **What's left** is in `docs/LIMITATIONS.md` §2 (PLAN milestones 7–9: PSN/GOG import,
  the stats view, Liquid Glass polish, the icon's Dark/Tinted appearances) and the small
  UI hooks the hardening pass left for the menu/`AppEnvironment` owner (cover-sentinel
  clear, Export Library…, Restore from backup).
- **Adding a source** (PSN/GOG): implement the `LibraryImporter` protocol → it lands rows
  in the `import_titles` staging table → the shared review sheet. Nothing else changes.
- **Schema change:** a new numbered migration in `VGN/Database/Migrations.swift`
  (lane A only) — never edit an existing one. Add a "created at v1 with data → vN" test.
- **New pure logic** (ranking/matching/recommendation): keep it Foundation-only and
  unit-test it directly on plain values, no DB/UI.

The rules above (owned paths, one migration owner, Swift 6 strict concurrency, no network
/ real Keychain / real Application Support dir in tests, feature-sized green commits) still
hold for any further work.

## Integration (orchestrator)

Per finished feature: merge branch → `main` (`--no-ff`), `xcodebuild build` + `test` on main, launch smoke test at milestone boundaries, push. Milestone tags `m0`…`m6` pushed when their "done when" is met as far as machines can tell; human-only acceptance items are collected in `docs/ACCEPTANCE.md`.

# VGN — Limitations, shortcuts and postponed work

Everything that is knowingly imperfect, deferred, or unverified, collected from the agents' hand-off reports and the orchestrator's integration notes. Snapshot: 2026-09-18, `main` at the `m1`/`m2`/`m4` tags (537 tests). Companion files: `docs/ACCEPTANCE.md` (what only the owner can verify by hand) and `docs/recognition-accuracy.md` (photo-scan numbers).

Legend: **[decide]** needs an owner decision · **[follow-up]** small, scheduled or easy · **[later]** out of scope for milestones 0–6 · **[watch]** fine today, could bite later.

---

## Hardening pass — wave 6, lane C (whole-app engineering review, 2026-09-19)

Closed / added this pass (details in the relevant sections below):

- **Cover negative cache, two real bugs fixed** (data-quality). (1) The 7-day
  "no cover" sentinel stamped/compared its file mtime with the *monotonic*
  `ServiceClock` (uptime), so any sentinel written before a reboot read as forever
  "fresh" → a once-missing cover was **never re-fetched**. Now wall-clock. (2) A
  transient provider failure (e.g. the libretro listing unreachable during a blip)
  produced an empty candidate list that was negatively cached for 7 days like a
  genuine miss. Added a `CoverProbe.transientFailure` signal through the provider
  chain; the sentinel is only written on a confirmed empty-but-reachable result.
- **Manual-cover sentinel [follow-up] — CLOSED.** `CoverStore.clearNegativeCache(gameID:)`
  is now public. **UI hook the orchestrator must add:** in `AppEnvironment.onRemoveCover`,
  after `store.clearUserCover(gameID:)`, call `await coverStore.clearNegativeCache(gameID:)`
  then re-trigger enrichment (`await enrichment.refresh(gameID:)` or `notifyLibraryChanged()`).
- **Title normaliser budget-label over-strip [watch] — CLOSED.** `.articleless` no
  longer strips the ambiguous retail budget-line labels (Platinum / Essentials /
  Greatest Hits / Player's Choice); they strip only at `.core`. "Pokémon Platinum"
  survives fuzzy matching. Genuine edition tags (…Edition / …Cut / Deluxe) still strip.
- **FuzzyMatch empty-title false-confident — fixed.** Two inputs that normalise to
  "" (pure punctuation, a lone "(USA)") scored 1.0 and merged as duplicates in
  Dedupe. Now returns 0 when either normal form is empty. (Also fixed two latent
  numeric bugs: jaroWinkler length-1 underflow, levenshteinRatio scalar/grapheme unit.)
- **Library export (JSON/CSV) [later] — BUILT (non-UI).** `LibraryExporter.exportJSON()`
  (complete, re-importable graph) and `.exportCSV()` (flat sheet with derived score +
  rank). **UI hook the orchestrator must add:** a File ▸ Export Library… menu item that
  calls the two methods and writes to a user-chosen file (`NSSavePanel`).
- **Backup restore — BUILT + tested.** `AppDatabase.restore(from:to:)` /
  `restoreLive(from:)` (validate → stage → atomic swap, clears stale WAL). **UI hook:**
  a Settings/File "Restore from backup…" that, on next launch, calls `restoreLive(from:)`
  **before** `AppDatabase.live()` (precondition: no open pool on the target).
- **Flaky perf tests [follow-up] — CLOSED.** RecommendationStore + grid/sidebar perf
  tests assert correctness only and print timings; new `ScalePerfTests` at 2 k / 10 k.
- **Migration coverage — added** a full v1-with-data → v4 test (exercises v2 FTS rebuild
  and v3 products-table rebuild on live compilation/rank/comparison data).

New **[watch]** items discovered (not fixed — see notes below): cover-fetch
cancellation is not truly propagated (unstructured `Task`); thumbnail decode runs on
the `CoverStore` actor; `CatalogTitleIndex` search is O(n) per keystroke; the grid CTE
scans all games per emission; `DerivedScore` fallback bands (non-6-tier) share
endpoints; `CrowdPrior` has a latent (non-live) 0/0.

Perf numbers (DEBUG, in-memory, best-of-3), 2 k / 10 k games:

| metric | @2 000 | @10 000 |
|---|---|---|
| grid query (`.tierRank`) | 44 ms | 203 ms |
| sidebar counts | 2.6 ms | 13 ms |
| FTS search | 5.0 ms | 22 ms |
| tier board | 17 ms | 77 ms |
| The Top | 47 ms | 216 ms |
| recommend (month) | 66 ms | 309 ms |
| enrichment enqueueMissing | 2.2 ms | 10 ms |
| CatalogTitleIndex build | 121 ms | 554 ms |
| CatalogTitleIndex search | 37 ms | 147 ms |

DEBUG figures; release is roughly an order of magnitude faster. All are comfortable
for a realistic personal library (hundreds–low thousands). At 10 k the grid CTE and
`CatalogTitleIndex` linear search are the two to revisit if the library ever gets huge.

---

## 0. The big caveat: nobody has driven the GUI

Agents cannot operate the app's windows. Every screen was built from model-level tests (537 of them), SwiftUI previews that compile, and "process stays alive, console clean" launch checks in sample-data mode. **Layout, focus/keyboard routing, drag feel, animation, and anything visual are unverified.** The per-milestone checklists in `docs/ACCEPTANCE.md` are the real acceptance tests. **Mitigation decided 2026-09-18 (hardening pass):** off-screen snapshot rendering of every screen inside the unit tests (agents get eyes on layout) and an on-demand XCUITest smoke suite with window-only screenshots (keyboard/focus flows); drag feel, animation and taste remain human-only. Highest-risk items, in order:
1. Quick Add's floating `NSPanel` owning the keyboard on macOS 15 (Tab/arrows/⌘-combos while the text field keeps focus).
2. Duel/Triage key focus — keys must not leak into the search field or re-tier the grid selection behind it.
3. Tier Board drag & drop (insertion position, multi-select drags) and the divider drag in The Top.
4. Grid scroll smoothness with real covers (only measured as query time + cell-diffing assertions, never as frames).

## 0b. Found by the hardening pass

- **Fixed 2026-09-19 — the app burned 100 % of a CPU core while idle.** `LibraryGridView`'s context-menu builder mutated the selection (`selectOnly`) while SwiftUI was building every cell's menu, so each update invalidated the view again (~700 selection writes per second). Present since the very first app shell; invisible to 650+ unit tests and to "process stays alive" launch checks; surfaced because the XCUITest runner could never find the app idle. Fix: the builder is pure, selection changes only inside menu actions. **New rule:** nothing reachable from a `body`/`@ViewBuilder`/menu builder may write observable state; launch checks now also assert idle CPU (< 5 % after 8 s) on the main destinations.
- **UI smoke suite status (2026-09-19):** `VGNUITests` (scheme `VGN-UITests`, `scripts/uitests.sh`, details in `docs/uitests.md`) builds, loads and runs; identifiers, launch hooks (`-VGNOpen <screen>`, `-VGNDisableAnimations YES`) and window-only screenshots are proven by `DuelFlowTests`, which **passes end to end** (←/→ answers, ⌘Z undo, progress, no arrow-key leakage). **Every other flow is still blocked**: on this macOS only the *first* test of a run gets its app window frontmost-queryable; later tests' windows render (the accessibility dump shows them) but stay behind the runner, so their queries fail. Tried and ruled out: `XCUIApplication.activate()`, terminating the previous app, app-side `NSApp.activate` (it even regressed the first test). Next thing to try: one `xcodebuild` invocation per test class (a `--per-class` loop), then giving the library's detail pane key focus on appear. Until then the keyboard/focus risks of §0 (Quick Add panel, search vs tier keys, Triage) remain human-verified only. The UI-test target needs `ENABLE_HARDENED_RUNTIME = NO` (ad-hoc signing vs library validation).
- **Privacy incident during the UI-test work (2026-09-19):** a screenshot *fallback* the UI-test agent had added used `app.screenshot()`, which on macOS captures the whole desktop; at least one capture showed other apps' windows (Notes, terminals). The agent found it while reviewing its own screenshots, removed the fallback (screenshots are now window-only-or-nothing), and deleted every capture; none was committed or pushed. The image was, however, read by the agent (i.e. processed by the model) and may persist in that agent's local session transcript under the machine's temp folder. Rule now in the suite's base class and docs: never `app.screenshot()` / `XCUIScreen.main`.
- Fixed: the photo-scan sheet could not be dismissed from its input state; Quick Add's sticky flags no longer touch the real `UserDefaults` in sample/seed modes; `scripts/uitests.sh` crashed on a full run under bash 3.2.
- Snapshot rendering (`scripts/snapshots.sh`, `docs/snapshots.md`): ~120 screens, light + dark, opt-in (not part of plain `xcodebuild test`, because rendering in parallel made a Quick Add debounce test flake). Cannot render: window toolbars, the Quick Add floating panel, menus, sheet/popover chrome, live covers, motion. One reference (`playnext-small-library@light`) is timing-dependent.
- Fixed 2026-09-19: unit tests run inside the app host and were reading the owner's **real preferences** (a sort order chosen in the app broke three view-model tests). Persisted UI preferences now go through `AppPreferences.defaults`, a throw-away suite under XCTest.
- Open, low priority: the unit suite flaked once in five consecutive runs on 2026-09-19 (one timing-sensitive test — candidates: the Tier Board `nudgeBackward` model test and Quick Add's debounce test; not reproduced, not yet pinned down); cover downloads are not cancelled when a cell scrolls away and thumbnail decoding runs on the `CoverStore` actor (only matters if real-cover scrolling stutters); "Restore from Backup…" glue (`PendingRestore`) is not unit-tested (the underlying `AppDatabase.restore` is); the old private `PhotoScanTab` placeholder struct in `SettingsView.swift` is dead code.

## 1. Still to build inside milestones 0–6

- **M3 Compilations UI** — **done** (wave 5, lane C). Compilation editor (add/remove/reorder members via the same quick-search, reuse-not-duplicate, orphan-aware removal, Fill-from-IGDB-bundle diff, edit details, auto single↔compilation conversion); inspector "Part of *X* (PS3) · n games" with an inline clickable member list and "Edit compilation…"; grid stack-marker tooltip names the compilation + context-menu "Show Compilation" / "Edit Compilation…" / "Group as Compilation…"; group-a-selection sheet (merges existing singles); the copy-removal warning now lists **member titles** (`GameDetail.Copy.memberTitles/memberIDs`).
- **M5 Playtime polish** — **done** (wave 5, lane C). Inspector averages line (Main/Rushed/Completionist + source), me-vs-average bar (pure `PlaytimeBar` geometry with markers, sensible past completionist, accessible), PSN "manual wins", status ⌃⌘1…4 shortcuts, "Open on HowLongToBeat" link, and the derived-score line ("9.6 · #4 overall · A, #2 of 14" / "~8.5 · unplaced in A" + Place now) via `RankingStore.scoreLine`. Playtime filter buckets (< 10 h / 10–40 h / > 40 h over effective playtime, IGDB-main fallback) + sidebar stats popover. The full stats **view** (PLAN §9) is still a later milestone.
- ~~M5b Play Next view + "Ask Claude"~~ — merged 2026-09-19. Known gaps: "Start playing" has no Undo (the store has none for it); the first Ask Claude call in an hour costs ≈ $0.70 notional because the CLI caches its own ~35 k-token system prompt; `--max-turns 1` still reports 2 turns.
- ~~M6 Photo-scan UI~~ — merged 2026-09-19 (`m6`). Known gaps: 1–2-character spine fragments ("DA", "L") still show up in the *no match* bucket (unchecked by default); complete titles sharing a prefix are never merged (deliberate); Continuity Camera is untestable without the owner's iPhone; the scan draft carries no cover id (covers arrive via enrichment, like Quick Add).
- ~~Final hardening pass~~ — done 2026-09-19 (see §0b): whole-app review (4 real defects fixed, export + restore added), snapshot rendering, UI smoke suite (partially blocked), the 100 % CPU render loop found and fixed. Not done: a scroll check with *real* covers (needs a populated library).
- Milestone tags pushed: `m0 m1 m2 m3 m4 m5 m5b m6` (tagged in completion order, not numeric order).

## 2. Out of scope for this run (PLAN milestones 7–9 and optional items) [later]

- **PSN import** (M7), **GOG import** (M8) — only the `import_titles` staging table exists.
- **Polish** (M9): Liquid Glass touches under `#available(macOS 26)`, stats view, Top export as image, app icon **Dark/Tinted appearances** (the "Console Grey" icon shipped 2026-09-19 as a single-appearance `AppIcon` set; SVG masters incl. dark and tinted variants are in `design/app-icon/`; the macOS 26 layered `.icon` file via Icon Composer is still to do), richer empty states.
- **HowLongToBeat provider** — skipped by decision; only the "open on HLTB" idea remains, and even that link is not in the inspector yet.
- **TheGamesDB cover provider** — not built (PLAN marks it optional).
- **"Choose cover…" sheet** — `CoverStore` returns every candidate from every provider, but there is no UI to browse them; today you get the first good hit or drop your own image.
- **`ClaudeAPIRecognizer`** (API-key variant of photo scan) — protocol seam exists, not built.
- **Editable tier labels/colours** — tiers are data (seeded S–F) but there is no editing UI.
- ~~**Library export (JSON/CSV)** from PLAN §9 "Safety" — not built.~~ **Non-UI built (wave 6, lane C):** `LibraryExporter.exportJSON()` / `.exportCSV()`. Only the File ▸ Export Library… menu item + `NSSavePanel` remain (UI lane). Launch snapshots (last 10) can now be restored via `AppDatabase.restoreLive(from:)` (call before `live()`), a Restore-from-backup UI entry still to add.
- **Signing**: "Sign to Run Locally" (ad-hoc). Consequence: macOS may re-prompt for Keychain access after each rebuild, and the hardened runtime is effectively relaxed. Switch to an Apple Development team id when convenient. [decide]

## 3. Library, Quick Add, search

- **Quick Add tier keys are `⌃S … ⌃F`, not bare letters** (PLAN §6.1 said "S A B C D") — letters are text input in a search field. [decide if you dislike it]
- **Adding a bundle is `↩` on the bundle row** (adds as compilation; falls back to a single game with a note if IGDB returns no members). IGDB's `bundles` field is empty in practice — members come from a reverse lookup, so coverage is whatever IGDB has.
- **IGDB `search` quirks**: returns nothing for mid-word prefixes and alt-name-only titles; a name-prefix + alternative-name fallback covers "bloodb" and "chevaliers de baphomet", verified live, but odd titles may still need "Create '…' manually".
- **Bulk "Mark Owned"** adds a *physical* copy on each game's *primary platform* without asking (the platform/format popover only appears for a single ambiguous game). [decide]
- **Type-to-select vs tier keys in the grid**: with a selection, S/A/B/C/D/F/O/P/0 act immediately; to type-to-select a title starting with one of those letters you must deselect first (or already be typing within ~1 s). [watch]
- ~~**Manual cover edge case**~~ **CLOSED (wave 6, lane C):** public `CoverStore.clearNegativeCache(gameID:)` added. **UI hook to add:** in `AppEnvironment.onRemoveCover`, after `store.clearUserCover(gameID:)`, `await coverStore.clearNegativeCache(gameID:)` then re-run enrichment for the game. (The related monotonic-clock sentinel bug and the transient-failure poisoning bug were also fixed — see the hardening summary at the top.)
- **Enrichment never overwrites non-empty fields** (plus the `user_edited` marker) — so a wrong-but-non-empty IGDB value is only replaced by an explicit "Refresh metadata". Manual entries (no IGDB id) get no metadata/time-to-beat; they get a cover job only on platforms that have a libretro repo.
- **Grid query** ≈ 33 ms at 2 000 games in DEBUG (was ~45 ms); fine, but it is one full re-query per emission — no paging. [watch]
- **`ManualAddSheet` view** — **removed** (wave 5, lane C); `ManualAddModel` kept (Quick Add uses it inline). File renamed `ManualAddModel.swift`.
- **Unsafe "un-play"**: `setPlayed(_, false)` still asks to delete a played-but-not-owned game (invariant 1, correct by design). Triage now uses the new safe `LibraryStore.markNotPlayed` instead (owned → Backlog, unowned → explicit "Remove from library" prompt). See §4.

## 4. Ranking

- **Triage `U` ("not actually played")** — **done** (wave 5, lane C). Backed by `LibraryStore.markNotPlayed` (owned → Backlog, no prompt; unowned → an explicit "Remove from library?" alert, never a surprise delete). Un-play is not added to Triage's `←` history (a game un-played this session isn't restored by "back").
- **Triage "back"** clears the tier directly instead of using the store's undo (multi-select `setTier` isn't in the duel undo history). Same visible result.
- **Disputes → "Settle"** — **done** (wave 5, lane C). Now enqueues the cycle's exact pairs via `RankingStore.enqueuePair` (served before natural refine candidates, logged as `refine`, persisted in the duel state, consumed on answer) instead of re-placing the games.
- **Multi-select drag on the Tier Board** — **done** (wave 5, lane C). `RankingStore.move([(gameID,toTier,atIndex)])` is one transaction / one undo step; `TierBoardModel` routes multi-move drops through `RankingBackend.moveBatch`.
- **The Top: no insertion line while hovering during a reorder drag** (SwiftUI `dropDestination` gives no location in `isTargeted`); the drop lands correctly. Reorder and divider drag are disabled while a filter is active (by design).
- **Divider drag maps a fixed 44 pt to one game** although rows have different heights — the maths is tested, the feel is not. [watch]
- **Drag payload UTType (`com.videogamenerd.ranking-item`) isn't declared in Info.plist** → benign console note during drags. **Deliberately still open** (wave 5, lane C): the project uses `GENERATE_INFOPLIST_FILE`, and an exported UTType needs a partial `Info.plist` + a `project.pbxproj` edit (`INFOPLIST_KEY_*` build settings can't express `UTExportedTypeDeclarations`). Lane C must not touch `project.pbxproj`, so this was skipped per the brief. **To close:** add a partial Info.plist declaring the exported type and point `INFOPLIST_FILE`/`GENERATE_INFOPLIST_FILE` at it in the pbxproj (build-config owner). [follow-up — needs pbxproj]
- **Derived scores**: bands S 9.0–10 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9 are constants for exactly six tiers; with any other tier count the engine falls back to *equal* bands across 1–10 (PLAN said "proportionally" without defining it). Scores are relative to tier membership, so moving a divider changes them — intended.
- **Border duels are logged with context `refine`** (the schema only knows `placement|refine`); accepting a border suggestion moves the game to the new tier **unplaced** (it then needs a placement duel) rather than guessing a slot.
- **Undo horizon**: per-answer inside the current placement + one step for the last completed action, history bounded to 50; dismissed border pairs remembered (last 32).
- **Perf at 2 000 ranked games (DEBUG)**: tier board 43 ms, The Top 53 ms (slightly over the 50 ms target; it builds full rows), duel answer 7 ms. CSV export fetches game detail per row for playtime. [watch]
- Sharp edge for future code: `PlacementSession.revalidated(against:)` drops the session's undo history — only call it when the tier actually changed.

## 5. Play Next (recommendations)

- **It is a shortlist-ranker, not a learner** — by design (PLAN §7b). Under ~15 ranked games the backtest says "not enough data" and match strength is always "weak"; "strong" needs ≥ 25 ranked games plus real evidence.
- **IGDB trait coverage is uneven**: e.g. *Bloodborne* has no franchise or series in IGDB; keywords are noisy (capped at 12 per game). Games without an IGDB match compete on time fit only ("no metadata").
- **Snooze is a fixed 21 days** (the feedback table has no "until" column). [follow-up if you want it adjustable]
- Genre/platform/decade affinities are synthesised at query time, not stored as traits.
- Weights and backtest thresholds (ρ ≥ 0.45 = "good") are reasoned constants, **not yet tuned on your real library** — that is what the backtest is for once you have rankings.
- **"Ask Claude"** is non-deterministic, takes ~10–20 s, needs the `claude` CLI logged in, and sends your tier list (top ~60 + D–F titles) and the shortlist — nothing else. On demand only.

## 6. Photo scan

- **Measured once** on your 5 photos: recall 98 %, precision 92 %, platform 94 %, IGDB pre-match 97 % (details and every miss/false positive in `docs/recognition-accuracy.md`). One shelf, one lighting — other shelves may differ.
- **17 false positives = spine fragments at tile edges** ("God of W…"); a prefix-aware merge is being added with the scan UI. 5 misses were faint spines the model declined to guess (intended: it must never invent a title; the two unlabelled spines are in the answer key's `skip` list).
- **Usage**: ≈ 8 `claude -p` calls and ~1–2 minutes per photo; the CLI priced the 5-photo run at $19.66 *notional* (≈ $4/photo on the default model) — it counts against your subscription's usage limits, it is not charged (see the note in §9). A cheaper model has **not** been evaluated — owner decision 2026-09-18: not for now (the model stays configurable in Settings ▸ Photo Scan). [later]
- One earlier full run (~$12–15 notional) was **wasted**: killed by a 600 s test timeout before results were saved. Fixed (per-photo incremental writes, timeouts disabled for the harness).
- **Tiles are 1850 × 2400 px — larger than the model's effective input.** Nothing is downscaled by VGN (tiles are full-resolution crops, JPEG q 0.8), but Claude's vision input is resized on its side when an image exceeds roughly 1 568 px on the long edge (Anthropic's published guidance; newer models may differ), so each tile is effectively seen at about 65 % scale. Recall is still 97–98 % on the owner's photos, so this is headroom rather than a bug: smaller tiles (≤ ~1 500 px, PLAN's original figure) would show the model more detail on faint spines at roughly twice the calls per photo. Tiling was tuned toward fewer, larger tiles (~8/photo) to bound usage — a deviation from PLAN's "~1 500 px tiles"; the row detector is a brightness heuristic with a plain-grid fallback.
- The Vision OCR fallback is rough (spine text is rotated/stylised); serial-code extraction only *boosts* platform/region, there is no serial→title database.
- The accuracy harness is a gated test (inert unless `scripts/scan-accuracy.sh` arms it), never part of the normal run.

## 7. Title matching & covers

- ~~**Title normaliser over-strips budget labels**~~ **CLOSED (wave 6, lane C):** the ambiguous retail budget-line labels (Platinum / Essentials / Greatest Hits / Player's Choice) now strip only at `.core`, not the `.articleless` level used for fuzzy matching, so "Pokémon Platinum" → "pokemon platinum". Edition tags (…Edition / …Cut / Deluxe / Complete) still strip at `.articleless`. `stripEditionTags(_:includeBudgetLabels:)` is the seam.
- **CatalogTitleIndex** offline autocomplete search is O(n) over the whole `catalog_cache` per keystroke (build+search DEBUG: 2 k ≈ 121+37 ms, 10 k ≈ 554+147 ms). Off the main actor and debounced, so fine at realistic sizes; if the catalogue grows to many thousands, index into an FTS table. `catalog_cache` is never pruned. [watch]
- **Cover fetch cancellation** is not truly propagated: `CoverStore.fetchAndStoreCover`/`thumbnail` run the shared work in an unstructured `Task` that nothing cancels, so scrolling away doesn't stop an in-flight download (it just isn't awaited). De-dup itself is correct. Wasted bandwidth only. **Thumbnail decode + file writes run on the `CoverStore` actor**, serialising the store under heavy scroll; move ImageIO decode off the actor if grid scroll ever stutters. [watch]
- **Fuzzy thresholds** (0.90 confident / 0.74 plausible) were tuned on a hand-made table, then held up in the live scan — still worth re-checking on libretro cover matching with your real library.
- Libretro cover matching is fuzzy against No-Intro/Redump names with Europe → USA → World → Japan preference; in the 10-game live smoke test 9 of 10 covers came from IGDB, only 1 from libretro (modern platforms have no libretro art, so this is expected — but retro hit rate is unmeasured). [watch]
- LibretroIndex (DEBUG): indexing 10 k names ≈ 620 ms, 1 k lookups ≈ 950 ms — off the main thread.
- GitHub unauthenticated rate limit (60/h) applies to fetching libretro file listings; they are cached on disk for ~30 days.

## 8. Data the owner should glance at

- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**, sidebar `group` assignments, anything missing. [decide before adding many games]
- `docs/shelf-truth-draft.json` — owner-reviewed; two unlabelled spines deliberately skipped.
- Tier palette (classic tier-list colours) and derived-score bands — constants, easy to change.

## 9. Engineering & process notes

- **Claude usage/billing**: photo scan and "Ask Claude" run `claude -p` with an **allowlisted environment** (HOME, PATH, LANG/LC_*, TMPDIR, USER, LOGNAME, SHELL, TERM) — no `ANTHROPIC_*` variable can reach the child, and `--bare` is never used, so it authenticates with Claude Code's own OAuth login (subscription). The CLI's `total_cost_usd` is a notional price, reported regardless of how you are billed.
- The Xcode project file is **hand-written** (objectVersion 77, synchronised folders). If Xcode re-saves it, ids get rewritten — harmless. Never add source files to it by hand.
- **Swift file basenames and type names must be unique across the target**, and bundle resources are flattened (fixture names must be unique) — both bit us once; rules are in `docs/EXECUTION.md`.
- **Test infrastructure quirks**: hosted unit tests need the XCTest-host guard (the app renders nothing and builds no services under tests); `@MainActor` tests touching GRDB must sit in a serialized suite; `UndoManager.undo()` hangs headless, so undo is asserted indirectly.
- A dev build was launched **once** against the real library (to verify `m0`); it created the empty database and the first backup. Everything since uses `-VGNSampleData YES` / `-VGNSeedGames n`. One full-screen screenshot was taken by mistake early on and deleted; full-screen captures are now forbidden in agent briefs.
- The wave table in `docs/EXECUTION.md` describes the original plan; actual sequencing diverged (lanes were re-sequenced whenever one freed up). Treat git history + this file as the record.
- Subagents run with the `opus` model alias — whichever Opus version the local configuration resolves, not pinned to 4.8.
- Two harmless build notes remain: the AppIntents metadata note at build time, and "Disabling hardened runtime with ad-hoc codesigning".

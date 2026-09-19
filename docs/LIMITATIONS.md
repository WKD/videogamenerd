# VGN — Limitations, decisions and postponed work

What is knowingly imperfect, deferred or unverified. Rewritten 2026-09-19 after the owner's review of every open item. Companions: `docs/ACCEPTANCE.md` (manual checks only the owner can do), `docs/recognition-accuracy.md`, `docs/snapshots.md`, `docs/uitests.md`.

Legend: **[doing]** being built now · **[later]** deliberately postponed · **[watch]** fine today, could bite later · **[owner]** needs the owner.

---

## 1. Owner decisions (2026-09-19)

| Topic | Decision |
|---|---|
| Quick Add tier keys | Keep `⌃S … ⌃F` (`⌃0` clears). |
| Bulk "Mark Owned" | **Ask once for the batch**: one sheet (format for all; platform = each game's primary one, ambiguous games listed and fixable), one transaction (`LibraryStore.addCopies`). Replaces the silent "physical on primary platform". Bulk **un-own** will not be built (owner decision 2026-09-19): a multi-selection ⇧O-off shows a banner ("un-own one game at a time") rather than half-removing copies. **[done]** |
| Grid: letters vs type-to-select | **Tier / owned / played keys need ⇧** in the library grid (`⇧S…⇧F`, `⇧O`, `⇧P`); plain letters always type-to-select. `0` still clears the tier. Tier Board, Triage and Quick Add keep their own keys. Deterministic rule in the pure `GridKeyRouter`; Caps Lock is not ⇧. **[done]** |
| Play Next snooze | Keep the fixed 21 days. |
| UI smoke suite | Prepare a `--per-class` runner (one `xcodebuild` run per test class) but **only execute it when the owner says they are away from the Mac** (10–20 min of keyboard/mouse takeover). **Script ready, never run**: `scripts/uitests.sh --per-class` (12 classes; `--list` previews; `--per-test` is the fallback). |
| Signing | Stay "Sign to Run Locally" (ad-hoc) for now. Consequence: macOS may re-ask for Keychain access after rebuilds; hardened runtime effectively relaxed. |
| Photo-scan tile size | **Measured 2026-09-19, no change.** IMG_3683 with 1100 × 2400 px tiles (rows kept whole; 16 calls instead of 8): recall 57/59 (97 %), precision 100 % — the same recall as the shipping 1850 × 2400 tiles for twice the calls, time (141 s) and notional cost ($6.76). The two misses (*The Last of Us Part I*, *Final Fantasy XIII-2*) are hard spines, not a resolution problem. Tiles under ~1 570 px high would cut each shelf row — and its spine titles — in two (20–24 calls); not tried. Re-run any geometry with `VGN_SCAN_TILE=WxH[xOverlap] scripts/scan-accuracy.sh IMG_3683` (`VGN_SCAN_DRYRUN=1` counts tiles for free). |
| Data folder | Stays `~/Library/Application Support/VGN/` although the app is now "Video Game Nerd" (`com.pomatelier.VideoGameNerd`). |
| Build now | Library stats view · cleanup batch · insertion line for The Top's reorder drag. ("Choose cover…" sheet + grid entry and Undo for Play Next "Start playing" are **done**, wave 7 lane B.) **[doing]** |
| Next milestone | **GOG import (M8)**, planned in PLAN §14 and built before PSN (it creates the shared importer machinery). Sign-in = **OAuth** (owner, 2026-09-19) with GOG's publicly documented Galaxy client credentials, kept in one file. Same cache-first / stop-and-ask protocol as PSN; live steps G1–G5 need the owner present. PSN (M7) and Polish (M9) after. |

## 2. The big caveat: the GUI has barely been driven

Agents cannot operate windows. Screens were built from model-level tests, SwiftUI previews and launch checks. Since the hardening pass there are two partial remedies:
- **Snapshots** (`scripts/snapshots.sh --generate` → `.build/snapshots/index.html`): ~120 screens, light + dark, off-screen. Opt-in (rendering in parallel with the unit tests made a debounce test flake). Cannot render window toolbars, the Quick Add floating panel, menus, sheet/popover chrome, live covers, motion. One reference (`playnext-small-library@light`) is timing-dependent. Reference comparison is not bit-stable run to run on this machine (anti-aliasing), so re-recording is done per affected screen.
- **UI smoke suite** (`VGNUITests`, scheme `VGN-UITests`, `scripts/uitests.sh`): builds, loads, runs; `DuelFlowTests` **passes end to end**. The other 11 flows are blocked: on this macOS only the *first* test of a run gets a frontmost-queryable window (later windows render but stay behind the runner). Ruled out: `XCUIApplication.activate()`, terminating the previous app, app-side `NSApp.activate`. Next: per-class runs (see §1). The UI-test target needs `ENABLE_HARDENED_RUNTIME = NO`.

Still human-only: drag feel (Tier Board, divider drag's fixed 44 pt per game), animation, Continuity Camera (needs the owner's iPhone), grid scrolling with real covers, and everything in `docs/ACCEPTANCE.md`. Highest-risk interaction: Quick Add's floating panel owning the keyboard on macOS 15.

## 3. Found and fixed by the hardening pass (kept as lessons)

- **100 % CPU while idle** — the grid's context-menu builder wrote the selection during view updates (present since the first shell; no test could see it). Rule: nothing reachable from a `body` / `@ViewBuilder` / menu builder may write observable state; launch checks assert idle CPU ≈ 0 %.
- **Covers could be lost for good** — the 7-day "no cover" marker was timed with uptime (resets at reboot), and a network blip was cached as a genuine miss.
- **Stale stream emissions overwrote fresh ranking boards** (a tile could snap back; showed up as a flaky test). Tier Board and The Top now re-read on emission.
- **IGDB bundle members** — a game's `bundles` field lists its *parents*, not its members ("God of War Collection" got "God of War Trilogy" as its only member). Members now come from the reverse lookup; nested bundles expand; DLC/packs are dropped. The owner's library was repaired on 2026-09-19 (backup `vgn-pre-bundle-fix-…`).
- Matching: empty-normalised titles matched at 100 %; budget labels ("Pokémon Platinum") were over-stripped. Photo-scan sheet could not be dismissed from its first screen. Quick Add wrote sticky flags to real preferences in sample mode. **Unit tests read the owner's real preferences** (they run inside the app) — now isolated via `AppPreferences.defaults`.
- **Two dead-click bugs no model test could see (2026-09-19):** ⌘/⇧-click never multi-selected (a plain `onTapGesture` shadowed the modifier gestures), and the filter chips' ✕ / "Clear all" did nothing (a horizontal `ScrollView` touching the window toolbar swallows clicks). Both fixed; `ClickProbeWindow` now sends real mouse events to an off-screen, toolbar-shaped window, so clickability is testable headless. Other screens have not been swept with it yet. [later: sweep Play Next, Tier Board, The Top, Stats, sheets]
- **Privacy incidents (2):** one full-screen screenshot by the orchestrator on day one, and a UI-test screenshot *fallback* (`app.screenshot()` captures the whole desktop on macOS) that showed other apps' windows. Both deleted, never committed; the second was read by an agent (processed by the model) and may persist in that agent's local transcript in the temp folder. Rules: never full-screen captures; UI tests screenshot `app.windows.firstMatch` or nothing.

## 4. Open items

### Library, Quick Add, search
- IGDB `search` misses mid-word prefixes and alt-name-only titles; the name-prefix / alternative-name fallback and the **typed-year filter** ("super mario bros 1985") cover the known cases; odd titles may still need "Create '…' manually". [watch]
- Enrichment never overwrites non-empty fields (plus the `user_edited` marker): a wrong-but-non-empty IGDB value is only replaced by "Refresh metadata". Manual entries (no IGDB id) get no metadata/time-to-beat, and a cover job only on platforms with a libretro repo.
- Placeholder covers print a large platform label that the badges can overlap; redundant now that platform pills sit under the title. [later, cosmetic]
- Compilation members keep IGDB's order (e.g. Mass Effect 2 · 1 · 3); reorder in the editor. [later: sort by release date on creation]
- Grid query ≈ 33 ms at 2 000 games (DEBUG), one full re-query per emission, no paging. [watch]
- **Mark Played As** (wave 7, ⇧M / context menu / Game menu): the ⇧M shortcut is displayed as **text only** ("Mark as Finished   ⇧M"), not a SwiftUI menu key equivalent — a shift-only equivalent would register globally and steal a capital "M" typed in the search field / Quick Add. The key itself is handled by the pure `GridKeyRouter`, so it is unit-tested; that the menus *render* the hint and that ⇧M does not leak into text fields is window-only (see `docs/ACCEPTANCE.md`). Selection reselection after a Backlog mark is keyed to the next grid observation emission (fine for a single window; an unrelated emission arriving first would cancel the plan). [watch]
- **BY LENGTH shelves + weekly play pace** (wave 9, lane C):
  - The pace store defaults to `UserDefaultsPlayPacePreferences` over `AppPreferences.defaults` (a throw-away suite under the test host; real `.standard` otherwise). **Sample mode is not special-cased**, so a pace set while running `-VGNSampleData` persists to the real `.standard` domain — harmless (a UI preference, not library data), but if the owner wants sample mode isolated, `AppEnvironment` (off-limits this wave) should pass an `InMemoryPlayPacePreferences()` into `LibraryViewModel` and Settings for the sample `LaunchMode`. [wiring, AppEnvironment]
  - The sidebar popover and Settings ▸ General share the **same store**, so a change in one shows up in the other on its **next open** (`reload`), not live across the two open windows simultaneously — full live cross-window sync was not built. [watch]
  - In **sample/preview mode** every "By Length" shelf count reads 0 and Unmeasured stays hidden, because `GameSummary` carries no time-to-beat estimate; the in-memory `LibraryFilterEvaluator` treats a length scope as "no constraint" there. The live GRDB path bands for real. [by design]
  - ~~The pace is exposed as `vm.playPace` for a later Play Next alignment but nothing consumes it yet.~~ **Done (wave 10, lane C):** Play Next's time brackets are now the five `LengthShelf` shelves; `TimeBracket` carries the shared `PlayPace` and derives its bounds from `LengthShelf.bounds(for:)` — one source of truth with the sidebar. A pace change (sidebar popover / Settings) recomputes Play Next once via `PlayNextBody.onChange(of: paceModel?.pace)`. The engine weights were **not** retuned; only the bracket bounds feeding `TimeFit` changed (`TimeFit` already handled open-ended ends, so no width-proportional tolerance was assumed).
  - Adding the section changes the existing **sidebar snapshot references** (`snap-library-sidebar@light/dark.png`); per the brief they were **not** re-recorded — the snapshot suite (opt-in, not the default gate) will flag them until a hardening lane re-records. [handoff]
- **Personal length / play style** (wave 10, lane C):
  - The missing-side inflation ratio **R = 1.5** is a **named constant** (`PlayStyle.sidesRatio`), not measured per library (owner's library median completely ÷ normally = 1.54, so 1.5 is close). Could later be measured per library, per genre, or merged with the filed "personal pace factor" idea (§7b — inflating advertised times by my own ratio). [later]
  - `LibraryFilter.playStyle` **defaults to `.storyFirst`** (raw main-story length) so a bare/legacy filter bands by the plain `normally` estimate; the app always injects the owner's real style (`PlayStyle.default` = lots of side quests) through `LibraryViewModel`, and "Clear all" preserves it. The mismatch between that default and `PlayStyle.default` is deliberate (keeps neutral filters showing the plain advertised time). [by design]
  - **Stats window** ("backlog in hours", `LibraryStatsStore`) still sums the raw `ttb_normally_s`, **not** the personal length — left as-is this wave (another lane owns that file's time section). A follow-up could make "backlog in hours" adopt the personal length at the owner's style for consistency with the shelves. [later — did NOT touch `VGN/Database/LibraryStatsStore.swift` or `VGN/UI/Stats/**`]
  - The rushed-only → *Unmeasured* rule is a **behaviour change** from the old `COALESCE(normally, hastily, completely)`: a game whose only time is rushed now shows in Unmeasured / "No Estimate" (so the HLTB fetch can fill main/completionist), instead of being banded by the rushed time. [by design]

### Library Stats window (wave 7, lane D)
- **Clicking a chart bar does nothing** in v1. Possible follow-up: click-through from a bar (platform / decade / tier / genre) to the main grid pre-filtered to that slice. [later]
- **"Hours by platform"** attributes a game's full effective playtime to *every* platform it is associated with (there is no primary-platform column), so per-platform hours can sum to more than the grand total for multi-platform games. Games-per-platform counts each game once per platform the same way. Documented, not a bug. [watch]
- **Average derived score per platform/decade/genre** includes *unplaced* ranked games at their tier's band midpoint (they carry a tier, so they count as ranked); genres are shown only at n ≥ 3. Scores are recomputed from the ranking snapshot on each report, never stored (PLAN §7). [watch]
- Report ≈ 17 ms at 2 000 games (DEBUG, `LibraryStatsReportPerfTests`); re-queried in full on each library change (a cheap GRDB change signal drives the reload), no incremental update. [watch]
- The stats window reuses whichever database `AppEnvironment` opened, so in **sample mode** it shows the sample library and in **seeded** mode the synthetic one — never the real library unless launched live.

### Ranking
- The Top: reorder now draws a Finder/Music-style insertion line while hovering (2 pt line + leading knob; the destination tier's colour + letter when the drop would cross a divider). The drop lands exactly where the line shows — both go through one pure function (`TheTopDropGeometry.resolve`). Reorder and divider drag are still disabled while a filter is active (by design), so no line appears then. Residuals: **no auto-scroll** near the top/bottom edge during a drag (SwiftUI's `ScrollView` doesn't provide it and driving it from the per-row `DropDelegate` — whose location is row-local, not scroll-view-relative — was not clean enough this pass; drag a game to a visible row, scroll, drop). The upper/lower-half split assumes `DropInfo.location` is in the row's local coordinate space (per Apple's docs); confirmed by the geometry unit tests but the live half-row boundary wants one human drag to eyeball.
- Divider drag maps a fixed 44 pt to one game. [owner: judge the feel]
- Derived-score bands are constants for six tiers; any other tier count falls back to equal bands. Border duels are logged as `refine`; accepting a border suggestion moves the game to the new tier *unplaced*. Undo: per answer inside a placement + one step for the last completed action (history 50). Triage "back" clears the tier directly; a `U` un-play is not restored by "back".
- Perf at 2 000 ranked games (DEBUG): tier board 43 ms, The Top ~50 ms, duel answer 7 ms. [watch]

### Play Next
- A shortlist-ranker by design: < 15 ranked games ⇒ "not enough data", match strength always weak; weights and the backtest threshold (ρ ≥ 0.45 = good) are **not yet tuned on the real library**. [owner: revisit once ~25 games are ranked]
- "Start playing" is undoable (wave 7, lane B): an inline "Started … — Undo" toast (~10 s, or until the next action / leaving the screen) plus Edit ▸ Undo "Start Playing" (⌘Z). It restores the game's exact prior status / played flag / `updated_at` and removes only the `picked` row that start inserted, in one transaction; the game becomes a candidate again. Residual limits: **undo is single-shot (no redo)**; it **refuses** (leaving everything intact, with a toast) when you've *ranked* the game since starting (un-playing would strip a valid tier) or when un-playing would orphan a no-longer-owned game.
- IGDB traits are uneven (*Bloodborne* has no franchise/series; keywords capped at 12). "Ask Claude": ~10–20 s, non-deterministic, first call in an hour ≈ $0.70 notional (the CLI caches its own system prompt), sends only the tier list + shortlist.

### Photo scan
- Measured on one shelf, one lighting: recall 97–98 %, precision 92–100 %, IGDB pre-match 96–97 %. 1–2-character spine fragments still land in *No match* (unchecked); complete titles sharing a prefix are never merged (deliberate). ≈ 8 `claude -p` calls, 1–2 min and ≈ $4 notional per photo on the owner's default model (`claude-fable-5-1`); the model is configurable in Settings ▸ Photo Scan; a cheaper model has not been evaluated (owner: not now).
- Vision OCR fallback is rough; serial codes only boost platform/region (no serial→title database).

### Covers & matching
- Cover downloads are not cancelled when a cell scrolls away; thumbnail decoding runs on the `CoverStore` actor. [watch — owner chose not to fix until scrolling actually stutters]
- "Choose cover…" sheet (browse every candidate) — **built (wave 7, lane B).** Inspector button next to the cover actions; grid of candidates grouped by provider (provider · region · size), current cover shown, "Use This Cover" / double-click / "Choose File…". Notes:
  - **IGDB contributes only the game's cover** — `artworks` are not modelled anywhere in the app, so they can't be enumerated. If wanted, model `game.artworks` (image ids) during enrichment and add them in `IGDBCoverProvider.allCandidates`. **[later]**
  - **libretro browsing shows the best-matching title's regions/discs/revisions only** (the top fuzzy-score cluster), not near-but-different titles like numbered sequels. Capped at 60 tiles.
  - **Candidate listing is live-mode only.** Sample mode (`-VGNSampleData`) must not touch the network, so the sheet lists no remote candidates there — the local "Choose File…" path still works. [watch]
  - **Entry point is the inspector only.** A grid context-menu entry was out of reach this wave (another lane owns `LibraryGridView.swift`); add "Choose Cover…" there in a wave that owns the grid. **[later]**
- Catalogue-cache title search is a linear scan per keystroke and the cache is never pruned. [later — owner chose not now]
- Libretro hit rate on a real retro library is unmeasured (9 of 10 covers came from IGDB in the smoke test, as expected for modern platforms). Fuzzy thresholds 0.90 / 0.74 were hand-tuned, then held up in the live scan.

### Safety
- Export (JSON/CSV) and Restore from Backup… are in the File menu; the restore glue (`PendingRestore`, applied at next launch after a safety snapshot) is unit-tested since 2026-09-19 (no bug found). [owner: still try a restore once before relying on it]

### GOG import (G0 scaffolding — wave 8, lane A)
The shared importer machinery, migration v5, the GOG client/auth/mapping/validator and the
sync coordinator are built and tested on **synthetic fixtures only** — no `gog.com` request
has ever been made (PLAN §14.5 step G0). What G0 cannot know until the live steps G1–G5:
- **Every GOG response shape is an assumption.** DTOs come from community documentation, not
  a recorded response. All guesses are marked `// ASSUMPTION(G0):` and listed in
  `docs/gog-import.md`. Field names, the `releaseDate` variants, and especially the **noise
  heuristics** (DLC / soundtrack / demo detection off `isGame`/`isHidden`/`category`/title
  keywords) must be confirmed and tuned against real data at G4/G5. **[G1–G5, with owner]**
- **Sign-in is OAuth route (a) only** (owner decision, G1). The session-cookie route was not
  modelled. Galaxy client id/secret are the documented public values in
  `GOGAuthConfiguration+Galaxy.swift` — **verify at G1** they still work.
- ~~`ProductSource` has no `.gog` case~~ **Done (wave 8, lane B):** `ProductSource.gog`
  ("GOG") added to `VGN/Model/GameEnums.swift`; no exhaustive switch over it existed, so the
  change is additive.
- ~~Keychain adapter for the GOG token is not built~~ **Done (wave 8, lane B):**
  `KeychainGOGTokenStore` over `SecretStoring` with a new `SecretKey.gogTokens` case; the
  token is one JSON blob under account `gog.tokens`, never logged.
- ~~Linux-only titles carry no note~~ **Done (wave 8, lane B):** surfaced at presentation time
  — `GOGMapping` sets transient `macAvailable`/`linuxOnly` flags on the staging row and the
  review sheet shows a "Linux-only → PC" chip. No schema change.
- **UI is wired in live mode only.** `AppEnvironment` builds the real `GOGAuth`/`GOGImporter`/
  coordinator/matcher only in live mode; sample/seeded/test modes use an inert backend (no
  network, no Keychain) and sign-in is disabled there. So the Settings **GOG pane, the OAuth
  login sheet and the review sheet cannot be exercised in `-VGNSampleData` mode** — only in a
  real run, which reaches `gog.com` (hence the live steps G1–G7 must be run by the orchestrator
  **with the owner**, `docs/gog-import.md`).
- **Login web view is untested against GOG.** The `WKWebView` bridge and `GOGLoginNavigationPolicy`
  are unit-tested on synthetic URLs; not one page has been loaded from `gog.com`. The captcha
  host GOG's login page may pull in is **not** on `allowedNavigationHosts`, so if login shows a
  "Blocked a page from …" note at G1, add that host to the configuration and retry (stop-and-ask).
- **Force-refresh per data set** deletes that set's cache rows with a small raw `DELETE` in the
  live backend (the cache store exposes no per-key delete and is lane A's file); the paged
  "Library" set is matched by key prefix. If lane A later adds a typed `invalidate(source:key:)`,
  switch to it.
- **GOG bundles are imported as single games, not expanded.** PLAN §14.3 wants an IGDB bundle to
  become a compilation Product with its members; the review sheet's chosen `ScanMatch` does not
  carry an `isBundle`/member list, so the commit path creates a single game (the owner can
  "Group as compilation…" afterwards). Bundle expansion in the import review sheet is deferred.
  **[follow-up]**
- **IGDB matching is skipped when IGDB is not configured** (`NoMatchImportMatcher`): every title
  then waits under *New* for manual review. A configured but flaky IGDB lookup can't sink a sync
  (`ResilientImportMatcher` turns a lookup error into "no match").

### HowLongToBeat fallback (wave 9, lane A — PLAN §5.3)
Fills only the *gaps* IGDB leaves, on demand (inspector ▸ Fetch from HowLongToBeat; Game ▸
Fetch Missing Time Estimates…). Built and tested **entirely on synthetic fixtures** from the
reference client's documented shapes — **no `howlongtobeat.com` request was made by this lane**.
- **The request shape is an assumption.** Ported from `ScrappyCocco/HowLongToBeat-PythonAPI`
  (master, 2026-09-19) and **isolated in one file** (`VGN/Services/TimeToBeat/HLTB/HLTBEndpoint.swift`),
  cross-checked with `ckatzorke/howlongtobeat`. The **endpoint discovery** (finding the rotating
  `/api/<word>/<token>` path by scraping the Next.js app chunk and re-assembling the token from
  string literals) is the **first thing that will break** and the first to re-verify on the real
  site. Symptom of a break: a clean `schemaMismatch` / discovery-failure stop, nothing corrupted;
  the feature degrades to the "Open on HowLongToBeat" link. Fix in that one file, then re-record
  fixtures with `scripts/record-hltb-fixtures.swift` (≤ 12 requests). See `docs/hltb.md`.
- **`ttb_source = 'igdb'` on empty games:** the enrichment write no longer tags a game
  `ttb_source = 'igdb'` when IGDB returned no time (it stays `NULL`, so the value is not
  mislabelled). **Existing rows were not backfilled** — a library enriched before wave 9 may still
  carry `ttb_source = 'igdb'` with no times. Harmless: the "no estimate" scope keys on the three
  value columns, not the source, so the fallback still reaches those games.
- **v6 migration adds `games.hltb_id` and `games.origin`** (the latter an owner request: the
  source a game *first* entered by, backfilled from the oldest product, else `manual`). `origin` is
  surfaced only in the inspector footer + export; it is set once at creation and never changed by a
  later copy.

## 5. Out of scope for now [later]
Filed ideas (PLAN §7b "Ideas filed for later", owner 2026-09-19): a **personal pace factor** that inflates advertised completion times from my own finished games (median of mine ÷ advertised), applied to Play Next, the BY LENGTH shelves and the backlog-hours stat; and **"finish what you started"** pools in Play Next (*almost there* — most of the estimate already played; *worth another try* — abandoned early but a strong taste match). Both wait for per-game playtime, i.e. the PSN import.

PSN import (M7, fully planned in PLAN §13) · Polish M9 (Liquid Glass touches, Dark/Tinted icon via Icon Composer — masters in `design/app-icon/`, Top export as image, richer empty states) · TheGamesDB covers · `ClaudeAPIRecognizer` · editable tier labels/colours (owner: not now) · adjustable snooze.

## 6. Owner to glance at [owner]
- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**.
- Tier palette and derived-score bands (`VGN/Ranking/DerivedScore.swift`) — constants.

## 7. Engineering notes
- `claude -p` runs with an allow-listed environment (no `ANTHROPIC_*` can reach it, never `--bare`) → the owner's subscription; `total_cost_usd` is notional.
- The Xcode project was hand-written, then normalised by Xcode on 2026-09-19 (ids reordered, a "Recovered References" group) — harmless. Never add source files to it by hand; Swift basenames and type names must be unique across the target; bundle resources are flattened.
- Tests: hosted in the app (XCTest-host guard builds nothing), `@MainActor` + GRDB ⇒ serialized suite, async tests need hard timeouts, `UndoManager.undo()` hangs headless, preferences are isolated. Never launch a dev build against the real library except at the owner's request; use `-VGNSampleData YES` / `-VGNSeedGames n`.
- The live accuracy harness finds `samples/` from `main/` or a worktree; subset runs write to `.build/scan-accuracy/` and no longer touch the committed report.
- Subagents run on the `opus` alias (not pinned to a version). Two harmless build notes remain (AppIntents metadata; "Disabling hardened runtime with ad-hoc codesigning").

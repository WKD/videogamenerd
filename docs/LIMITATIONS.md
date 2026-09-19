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
| The Vault *(2026-09-20)* | Batocera ROMs and barely-played PS Plus games (≤ 10 min) share one pool, **The Vault** (PLAN §16): out of the library, browsable, suggested only by Play Next ▸ "From the vault". PS Plus games get a boost that ramps up to the owner's planned unsubscribe date, scaled by whether the game can still be finished in time. **[planned — after the PSN live fixes]** |
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

### Delicious Library import (§5.5, wave 10)
- **Own-cover fallback vs enrichment.** A Delicious box-art cover applied to a game with no cover is stored **without** the user-chosen marker, so it is not locked. But enrichment only fills an **empty** `cover_file`; once the Delicious cover is set, `cover_file` is non-empty, so the background cover job won't fetch a "better" one on its own. In practice the Delicious regional box art sticks unless the owner uses **Choose Cover…** / **Remove custom cover**. Making enrichment prefer a higher-quality cover over an import-supplied one would need an enrichment change (off-limits this wave). [watch]
- **Title cleaning is heuristic** (match-title only; the original is always shown). The dry run over the owner's real file cleaned 20/103 titles well, but a few leave harmless residue in the *match* string only — a stray region tail ("Evolution Worlds - US"), empty brackets ("Resident Evil 2 [ ] [ UK Import ]", which the matcher's own bracket-stripping then removes), or a bundle cut at " + " that shortens a compilation's match ("God of war collection: God of war 1"). These affect only the IGDB query; the owner reviews and can pick an alternative or create manually. [watch]
- **Live cover application is window-only.** The reader, mapping, duplicate rules, commit payload and the cover DB setter are unit-tested; the end-to-end live cover apply (real cover directory + files) is exercised only by launching the app. [owner]
- **Covers not offered in matcher-less runs isn't a thing** — the toggle appears whenever a cover store exists (live and sample). In sample mode the cover writes to a temp dir, so it's a no-op for the real library.

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

### PSN import (S0 scaffolding — wave 11, lane A)
The PSN vertical (auth, client, DTOs, validator, mapping, importer, commit), the development
response cache, and schema **v8** (`products.subscription`) are built and tested on **synthetic
fixtures only** — **not one request** has been made to any `playstation.com`/`sony.com` host
(PLAN §13.5 step S0). Full assumption checklist + the S1–S8 runbook: `docs/psn-import.md`.
- **Every PSN response shape and the mobile-app OAuth values are assumptions.** Ported from
  `achievements-app/psn-api` @ `1e9d9a80…`, cross-checked against `psnawp` /
  `andshrew/PlayStation-Trophies`; all marked `// ASSUMPTION(S0):`. The GraphQL **persisted-query
  hash** for purchases is the fragile one (**most likely to fail at S6**); build with
  `PSNImporter(includePurchases: false)` to ship owned-digital later without blocking. **[S1–S8, with owner]**
- **`games` has no `last_played` column** (PLAN §4). The commit writes `psn_playtime_s` only
  (manual `my_playtime_s` always wins); the trophy/game-list **first/last-played dates are
  carried on the staging row but not stored on the game**. If the owner wants last-played on the
  game, a future migration adds the column — out of scope for v8 (which the brief scoped to
  `products.subscription` only). **[owner decision]**
- **External-id stability edge**: a merged PSN row's external id prefers concept → title →
  `NPWR…` → entitlement → name+platform. A trophy-**only** game (played, never purchased) keyed
  on its `NPWR…` id would switch to a concept/title id if later *purchased*, so its owned copy is
  a new product rather than an update. Rare; the review sheet's `matched_game_id` still dedupes
  the game itself. **[watch at S7/S8]**
- **Probe-before-full guard** records its marker in the runtime `import_cache` (via a manifest
  row) keyed by `(dataSet, accountLabel)`. A full fetch throws `PSNClient.ClientError.probeRequired`
  until a probe has run for that data set — so "full run before a probe" is impossible by
  construction. `accountLabel` (`test`/`real`) also scopes the DEBUG dev-cache folder.
- **Transient PSN row fields** were added to the shared `ImportStagingRow` (`subscription`,
  `launchedNotPlayed`, `reviewNote`, `statusPrefill`) and four PSN cases to `ImportIgnoreReason`
  (`betaOrTrial`, `themeOrAvatar`, `preOrder`, `inactiveEntitlement`, `mediaApp`). Additive —
  recomputed each sync, never persisted; GOG/Delicious set none of them and stay green.
- **UI is the next lane**: Settings ▸ PlayStation pane, the login WKWebView, the review-sheet
  groups (New / Already matched / Ignored, plus "Launched 0 %" / "Played — no purchase found"),
  the yellow-circle **"+" badge** (`#FFC300` circle, `#0070D1` "+"), Format ▸ **PS Plus** menu
  entry (model+SQL are done — `LibraryFilter.includeSubscriptionOnly`), the Play Next
  "leaves with PS Plus" option, and the bulk **Change Copy Format** action are all next-lane.

### HowLongToBeat fallback (wave 9 lane A; **verified live wave 10 lane B** — PLAN §5.3)
Fills only the *gaps* IGDB leaves, on demand (inspector ▸ Fetch from HowLongToBeat; Game ▸
Fetch Missing Time Estimates…). **Verified against the live site 2026-09-19** (wave 10): the
request shape is no longer an assumption — the fixtures in `VGNTests/Fixtures/hltb-search-*.json`
are recorded from real searches, and the whole discovery → init → search → parse flow was proven
end to end (see `docs/hltb.md` for the request log and the real mechanics).
- **What the first port got wrong (now fixed).** The old port assumed a rotating
  `/api/<word>/<token>` path assembled from JS string literals, and **no auth step**. The live
  site actually (a) uses a plain slashed path found by matching the one `fetch("/api/…",{method:"POST"})`
  in a turbopack chunk (currently `api/search/site`), and (b) requires a **per-session token**:
  `GET <path>/init?t=<ms>` → `{token, hpKey, hpVal}`, sent as `x-auth-token` / `x-hp-key` /
  `x-hp-val` headers **and** injected as a `body[hpKey]=hpVal` field. All of this now lives in
  `HLTBEndpoint.swift`; the client fetches the token once per run.
- **What stays frail.** The endpoint path, the token scheme and the `hpKey`/`hpVal` field names can
  all rotate — a break shows as a clean `schemaMismatch` / discovery-failure / 403 stop, nothing
  corrupted, and the feature degrades to the "Open on HowLongToBeat" link. The token embeds the
  caller IP + UA and **expires**: a long bulk run whose token lapses mid-way stops on a 403 (no
  in-run refresh, by design) and the owner just re-runs — only still-missing games are re-queried.
  Fix lives in that one file; re-record fixtures with `scripts/record-hltb-fixtures.swift`
  (≤ 25 requests, ≥ 2 s apart). See `docs/hltb.md`.
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
Filed ideas (PLAN §7b "Ideas filed for later", owner 2026-09-19): a **personal pace factor** that inflates advertised completion times from my own finished games (median of mine ÷ advertised), applied to Play Next, the BY LENGTH shelves and the backlog-hours stat; and **"finish what you started"** pools in Play Next (*almost there* — most of the estimate already played; *worth another try* — abandoned early but a strong taste match). Both wait for per-game playtime, i.e. the PSN import. Also filed (PLAN §15): a **Batocera / ROM collection** importer — played or favourite ROMs become library games, the thousands of others stay in a separate catalogue that feeds a Play Next "Discover" row instead of flooding the grid. Also filed: **"Play it again"** replay suggestions for finished games — needs an inferred replay-value score (no online source has one) and a machine-known last-played date (PSN provides it); to be built only if enough finished games get that date from imports, never if it would rely on hand-entered dates.

PSN import UI landed in wave 11 (see §5c for what remains — build-steps panel, richer review grouping, Play Next PS Plus term); the live steps S1–S8 are still gated on the owner · Polish M9 (Liquid Glass touches, Dark/Tinted icon via Icon Composer — masters in `design/app-icon/`, Top export as image, richer empty states) · TheGamesDB covers · `ClaudeAPIRecognizer` · editable tier labels/colours (owner: not now) · adjustable snooze.

## 5b. Reconciling unlinked games (§5.1, wave 11)
- **Subscription copies (rule 4) — now enforced (wave 11, PSN lane).** `products.subscription` (v8) is read into `ReconcileCopy` by `LibraryStore.copies(of:)`; `MergePlanner` only collapses a copy into a target copy with the **same** subscription state, so a PS Plus copy is never collapsed into a really-owned one (or vice-versa). `ReconcileProductRow` round-trips `subscription` via `SELECT *` (undo-safe). The TODO is removed.
- **Grid context-menu label.** `GameSummary` carries no `igdb_id` (owned by lane A / the PSN lane's additive change), so the grid entry can't always tell linked from unlinked purely: it reads the single-selection live detail when the right-clicked game is that game, otherwise shows "Link to IGDB…". The sheet itself always adapts its title. The inspector and File-menu command (which have the detail) always show the exact label.
- **Reconcile menu lives in the File menu**, next to Quick Add and the importers (the app's convention for library-data actions — `PlayedMarkCommands` already owns the "Game" menu, and two `CommandMenu("Game")` would create a duplicate). Functionally a menu-bar "Link to IGDB…" for a single selection, as asked.
- **Duel-state JSON blob** (`app_state` `ranking.duel`) is not rewritten on a merge: it references game ids only inside the blob and stale ids are dropped on load (`revalidateSession`). A merged loser id in an in-flight placement session is simply dropped — acceptable, but a duel in progress on the merged-away game is lost.
- **Undo** restores the full row snapshot (games, products incl. `external_id`, product_games, platforms, genres, traits, comparisons, rec_feedback, import_titles, enrichment_jobs). `enrichment_jobs` self-heal via the coordinator scan regardless. `UndoManager.undo()` hangs headless, so undo is verified by asserting registration + driving the store's `restoreReconcile` directly.
- **No snapshot (PNG) reference added** for the two new sheets this wave — the snapshot harness can't render sheet chrome reliably (see §2); click coverage (`ReconcileClickTests`) exercises the real buttons instead.

## 5c. PSN import UI (§13, wave 11 — lane C)
What landed, and what a later lane still owns:
- **Landed & live-reachable.** Migration v9 (`first_played_at`/`last_played_at`, importer-filled); the `LivePSNImportBackend` behind the shared `ImportBackend` seam (live only; sample/seeded/test get the inert backend — no network, no Keychain); **Settings ▸ PlayStation** tab (`PSNAccountModel`/`PSNAccountPane`): web-login **or** a *Paste NPSSO instead* disclosure (SecureField, `isPlausibleNPSSO`, never echoed, cleared after use), the three-line risk note, per-data-set cache age + Force Refresh (cost+age confirm), Sync Now, Sign Out (+ wipe), session expiry, and the GOG-style `ImportError` surfaces; `PSNLoginSheet` (WebKit, reads the `npsso` cookie from a non-persistent store via the pure `PSNLoginCookies` matcher; bounded wait → paste fallback; NPSSO never logged); `PSNImportBuilder`/`PSNImportHookup` (progress + review sheets; **File ▸ Import from PlayStation…**, disabled→opens Settings when signed out); the review commit path (`ImportReviewModel.commitItems` emits the correct `PSNCommit` per row — purchase vs played-only vs PS Plus, play time, first/last played dates, 100 % status; launched-0 % never marked played); **PS Plus in the library** (grid `+` badge, inspector copy row, **Format ▸ PS Plus** facet + filter chip); bulk **Change Copy Format ▸ Physical/Digital/ROM** (single-copy games only, one undo step).
- **Landed (wave 12, lane A).** The four deferred items above are now built and tested (no request to Sony was made):
  - **The safety latch is a visible switch** (`PSNAccountModel`, all builds): off shows the risk note + an Enable confirmation → "Relaunch VGN to apply" (wired at launch, never hot-swapped); on adds "Turn off…". File ▸ Import from PlayStation… is disabled with "Enable it in Settings ▸ PlayStation" while off.
  - **DEBUG "PSN build steps" panel (§13.5)** — `PSNBuildRunner` seam (live adapter + scripted fake), `PSNBuildStepsModel`, `PSNBuildStepsPanel` (behind a "PSN build steps…" button so the pane keeps its `settingsPane()` sizing). test/real picker (REAL ACCOUNT marker + a second confirm on full fetches), the S2–S6 probe/fetch steps in order, one at a time, probe-before-full per label, reject→**Acknowledge** lock (+ explicit "Try this step again"), running "requests this session: k / 40", per-step redacted rows with the clickable dev-cache path, "Wipe dev cache (this account)", and "Copy report" (redacted-only). **All of it is `#if DEBUG`** — verified absent from a Release binary.
  - **DEBUG normal-Sync gate (§13.5 D10)** — Sync Now / File ▸ Import refuse in DEBUG live builds until every probe and full fetch has passed once for the current account label. Release is unchanged (the per-fetch probe guard still applies).
  - **Richer PSN review grouping (§13.3)** — the sheet now shows Played · Launched 0 % (unticked) · Played — no purchase found (with the "Own the ticked rows as ▸ Physical/Digital" group action) · Purchased · PS Plus · Already in your library (per-row change detail) · Ignored, plus a **Proposed removals** section (`applySubscriptionRemovals`, explicit confirm). Banner: "N imported · M updated". GOG/Delicious keep the generic buckets.
  - **Play Next PS Plus term (§13.3)** — `Candidate.ownedOnlyViaSubscription` (loaded via a `sub_only` subquery), a "Leaves with PS Plus" reason, and Options ▸ **Prefer expiring PS Plus games** (off by default, persisted) driving an additive `subscriptionBonus` term that only reorders near-ties; inherently excluded from the backtest.
- **Remaining (needs the owner, live).** The gated live steps **S1–S8 have not been run** — every PSN response shape and the mobile-app OAuth values are still `ASSUMPTION(S0)` (the sign-in URL / `npsso` cookie domain, the DTOs, and the `getPurchasedGameList` persisted-query hash are unverified). Run them through the panel per `docs/psn-import.md` (arm the latch → relaunch → sign in TEST → probe each data set → sign in REAL → probe → full fetch), stopping at the first odd response. Nothing in this lane made a request to Sony.

## 5d. Batocera ROM catalogue (§15, wave 12 — lane B, phase 1)
Phase 1 landed the whole non-UI half; phase 2 (a later wave) owns everything visible.
- **Landed.** Migration **v10** (`rom_catalog` + `rom_catalog_sync` + `rom_catalog_fts`, a
  separate shelf no library query reads; `promoted_game_id` ON DELETE SET NULL); the streaming
  `BatoceraGamelistReader`; `BatoceraShare` (locate systems + mtime/size); the pure
  `BatoceraSystems` table + skip list, `BatoceraFolding` (libretro-key dedupe), `BatoceraPromotion`
  (the `> 300 s` OR favourite rule); `RomCatalogStore` (upsert/remove, change detection,
  promotion candidates, FTS search, per-system counts, never-played pool, taste queries) +
  `RomCatalogTraits`; the change-detecting `BatoceraSync` actor; and promotion through the
  existing importer commit path (`BatoceraImporter`/`BatoceraPromotionBuilder`/`BatoceraPromoter`,
  `ProductSource.batocera`). Dry-run on the real share: 35 mapped systems, 9 skipped, **0 unknown**,
  **10 912** entries after folding 112 dupes, **292** promotion candidates, **91.6 %** genre→trait
  coverage, full read+fold in ~0.7 s (Swift perf test).
- **Interim: Batocera play time storage.** There is no neutral `imported_playtime_s` column, so
  Batocera `gametime` is written into `psn_playtime_s` **only when both `my_playtime_s` and
  `psn_playtime_s` are NULL** (`LibraryStore.setImportedPlaytimeIfEmpty`, gated by
  `PSNCommit.playtimeOnlyIfEmpty`) — a real PSN value is never clobbered, but a game with a
  PSN time will not also show its Batocera time. **Proposed to lane A:** add `imported_playtime_s`
  (or a `playtime_source` tag) in a future migration so the two coexist; the read-time playtime
  precedence (manual > …) would then include it. Not added silently.
- **Deferred (phase 2 — the UI lane).** The **Batocera sidebar browser** + search + "Add to
  Library"; the **promotion review sheet** + banner + Undo after a sync (data ready:
  `BatoceraSyncSummary.candidateCatalogIDs`, `BatoceraPromoter.Plan`, `gameHasROMCopy`); **Settings ▸
  Batocera** (share-path picker remembered, Sync Now, skip-list override, auto-sync at launch);
  **Play Next ▸ Discover** (platform best-ofs ∩ `neverPlayedPool`, scored with
  `RomCatalogEntry.traits` + the crowd `rating`, "Not interested" → `setNotInterested`). The IGDB
  match step that turns a candidate into a `.newGame`/`.existingGame` target (and computes the
  duplicate flag) is also phase 2 — `BatoceraImporter.fetch` yields staging rows, the match runs
  through the shared coordinator.
- **`GameOrigin` for Batocera** is carried as `.other("batocera")` (label "Batocera") — no new
  enum case, so no UI switch fallout. `ProductSource.batocera` **is** a real case (the commit needs
  it so the promoted game's origin is tagged `batocera`, not `manual`).
- **Folding is a safety net, not the mechanism** — 1G1R means only 112/11 024 raw entries fold on
  the real box. The libretro key is title-only (region/disc/rev stripped); genuinely-distinct games
  that share a normalised title would fold, but none were observed. Multi-disc PS1/Sega-CD titles
  fold correctly (Disc 1 kept).

## 5e. Batocera ROM catalogue UI (§15, wave 13 — lane A, phase 2) — **as built**
Phase 2 built the whole visible surface (see `docs/batocera-import.md`). No schema change (v10
sufficed). Watch items / follow-ups:
- **Ask Claude for Discover is a follow-up [later].** The regular Play Next shortlist has "Ask
  Claude"; the Batocera Discover row does **not** wire a second opinion this lane (the brief
  scoped it out). Discover reasons are the engine's structured `PlayNextReason` sentences only.
- **Batocera play time still shares `psn_playtime_s` [watch].** The phase-1 interim above is
  unchanged — no neutral `imported_playtime_s` column was added (it was not needed for the UI, and
  a migration was avoided per the brief). A promoted ROM's time still lands in `psn_playtime_s`
  only when both playtime columns are empty, so a game with a real PSN time won't also show its
  Batocera time. Still proposed for a future migration.
- **Discover crowd prior is a local, capped weight [watch].** ScreenScraper ratings carry **no
  rating count**, so the engine's count-confidence crowd weight would be zero. `DiscoverScorer`
  instead blends the 0–1 rating with a small weight capped at 0.25 that shrinks as the owner ranks
  more games — a documented deviation from the engine's crowd term, deliberately below the taste
  terms so it only nudges near-ties. The engine's own weights/backtest are untouched.
- **The library toolbar still renders over the ROM Catalogue view [watch].** The detail pane's
  search field + filter menus (which drive the *grid*) stay in the window toolbar for the ROM
  Catalogue destination; the catalogue's own search/sort/filter live in the view. They do nothing
  to the catalogue but are visually redundant. Suppressing the toolbar per-selection was left out
  to keep the change additive.
- **Share thumbnails / "Show in Finder" are window-only [owner].** Reading box art from the share
  and revealing a ROM in Finder are exercised only by launching the app against a real mounted
  share (tests never read `/Volumes`; the loader has a nil root there). Idle CPU with the catalogue
  open is a launch check (no timers, mount checked on demand only).

## 5f. Batocera favourites — auto-add / boost / pin (§15, wave 13 — lane B) — **as built**
No schema change (v10's `favorite` / `promoted_game_id` / `dismissed_at` sufficed). Watch items:
- **One undo step, banner-scoped [watch].** The "N favourites added · Undo" banner registers an
  undo step and its button both call the same idempotent inverse (`BatoceraPromoter.undoAutoAdd`),
  which deletes the ROM copies the batch created, deletes the newly-created games (orphan-safe —
  a pre-existing owned game survives) and clears `promoted_game_id`. **Play-time-only** additions
  to a *pre-existing* game (a favourite whose match already owned a ROM copy) are **not** reverted
  by undo — only the link is cleared; reverting an imported play time is out of scope (and, since
  favourites usually have no play time, rarely relevant).
- **Auto-add is live + IGDB-configured only [expected].** The background matcher/promoter pass runs
  only when a real `ImportMatcher` exists (live mode with IGDB credentials) and the setting is on;
  in sample/seeded/test it never runs (the sync itself is inert there — `/Volumes` untouched). With
  IGDB unconfigured the old "N ready to review" banner shows and nothing is staged/queried.
- **"Nothing queried twice" is per staged row [watch].** A favourite is staged in `import_titles`
  *before* it is matched, so a later auto-add pass skips it (`favouritesNeedingMatch` excludes
  rows with a staging entry) — even the ones that were **not** confident. Opening *Review…* later
  still re-matches those `.new` rows (that path always re-runs the coordinator's matching); the
  "never twice" guarantee is about the unattended background pass, not the explicit review.
- **Favourite boost is backtest-neutral like PS Plus [by design].** `batoceraFavouriteBonus`
  (default 0.05, below the taste/crowd terms) is applied in `RecommendationEngine.score` only,
  gated on `status == .backlog` — the backtest's `predict` never sees it. Reason
  `.batoceraFavourite` ("★ a favourite on your Batocera"); Discover's pin uses a separate reason
  `.batoceraFavouritePinned` ("★ your favourite").
- **First-run batch cap is a constant [owner].** One pass caps at
  `BatoceraFavouriteAutoAdd.batchCap = 60`; the owner's ~247 favourites take ~4 syncs to fully
  match. Tunable in one place if that feels slow.

## 6. Owner to glance at [owner]
- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**.
- Tier palette and derived-score bands (`VGN/Ranking/DerivedScore.swift`) — constants.

## 7. Engineering notes
- `claude -p` runs with an allow-listed environment (no `ANTHROPIC_*` can reach it, never `--bare`) → the owner's subscription; `total_cost_usd` is notional.
- The Xcode project was hand-written, then normalised by Xcode on 2026-09-19 (ids reordered, a "Recovered References" group) — harmless. Never add source files to it by hand; Swift basenames and type names must be unique across the target; bundle resources are flattened.
- Tests: hosted in the app (XCTest-host guard builds nothing), `@MainActor` + GRDB ⇒ serialized suite, async tests need hard timeouts, `UndoManager.undo()` hangs headless, preferences are isolated. Never launch a dev build against the real library except at the owner's request; use `-VGNSampleData YES` / `-VGNSeedGames n`.
- The live accuracy harness finds `samples/` from `main/` or a worktree; subset runs write to `.build/scan-accuracy/` and no longer touch the committed report.
- Subagents run on the `opus` alias (not pinned to a version). Two harmless build notes remain (AppIntents metadata; "Disabling hardened runtime with ad-hoc codesigning").

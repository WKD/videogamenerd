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
| ROM format *(2026-09-20)* | **Kept** — not folded into Digital. Everything that comes from Batocera is a `rom` copy. |
| Grid disc badge on cartridges *(wave 17)* | The Physical badge is a **disc** (`opticaldisc`, outline since wave 19) and also shows on cartridge games — `platforms.json` has no media field, so physical-on-a-cartridge can't be told from physical-on-a-disc. A cartridge-vs-disc variant is a possible follow-up. **[watch]** |
| PSN "own the ticked rows as" default *(wave 17)* | The two-segment Physical\|Digital control starts **neutral = played, not owned** (PLAN §13.3 default), not pre-selected Physical, so a played-not-owned import stays possible and the existing commit test holds. Picking a segment applies to ticked rows and is adopted by later ticks; a per-row "Own as" override (row menu) shows the neutral/mixed look. Chosen from the owner's "either remove both default or do a toggle" — both, effectively. **[done]** |
| PSN Launched → Vault undo *(wave 17)* | At commit the Launched group's unticked rows go to the Vault (PLAN §16). The **import commit itself is final** — the review sheet is its confirmation and no import-undo exists — but the **Vault sends are one reversible step**: "Undo Vault Sends" in the committed footer (un-vaults + deletes the rows it created), plus per-row "Bring back" and deletion from the Vault browser. **[done]** |
| No automatic clean-up of my data *(2026-09-20)* | **Nothing may modify or delete library data on its own** — no launch-time repair, no background pass, no bulk normalisation. Inconsistencies are shown as review lists (Unlinked, Bundles to Expand, Platform Without a Copy…) and fixed only by my explicit, undoable action. A one-shot platform repair was reverted before it ever ran. |
| Next milestone | **GOG import (M8)**, planned in PLAN §14 and built before PSN (it creates the shared importer machinery). Sign-in = **OAuth** (owner, 2026-09-19) with GOG's publicly documented Galaxy client credentials, kept in one file. Same cache-first / stop-and-ask protocol as PSN; live steps G1–G5 need the owner present. PSN (M7) and Polish (M9) after. |

## 2. The big caveat: the GUI has barely been driven

Agents cannot operate windows. Screens were built from model-level tests, SwiftUI previews and launch checks. Since the hardening pass there are two partial remedies:
- **Snapshots** (`scripts/snapshots.sh --generate` → `.build/snapshots/index.html`): ~120 screens, light + dark, off-screen. Opt-in (rendering in parallel with the unit tests made a debounce test flake). Cannot render window toolbars, the Quick Add floating panel, menus, sheet/popover chrome, live covers, motion. One reference (`playnext-small-library@light`) is timing-dependent. Reference comparison is not bit-stable run to run on this machine (anti-aliasing), so re-recording is done per affected screen.
- **UI smoke suite** (`VGNUITests`, scheme `VGN-UITests`, `scripts/uitests.sh`): builds, loads, runs; `DuelFlowTests` **passes end to end**. The other 11 flows are blocked: on this macOS only the *first* test of a run gets a frontmost-queryable window (later windows render but stay behind the runner). Ruled out: `XCUIApplication.activate()`, terminating the previous app, app-side `NSApp.activate`. Next: per-class runs (see §1). The UI-test target needs `ENABLE_HARDENED_RUNTIME = NO`.
  - **Wave-18 `--per-class` attempt was BLOCKED at initialisation (2026-09-20).** `build-for-testing` compiled fine, but every `test-without-building` invocation died before any flow with *"Failed to initialize for UI testing: LocalAuthentication Code=-4 — System authentication is running … BiometryType=1"* (twice, stopped after the second). A system Touch-ID/auth dialog on the login session cancels the UI-testing harness — almost certainly a **Keychain/Touch-ID prompt left on screen by the ad-hoc-signed rebuilds** (see §1 Signing) or an again-required Accessibility/Automation grant; owner-only to clear at the machine, then re-run. No flow ran, no input was hijacked, no `VGN` was left running. So `--per-class` vs the frontmost-window blocker is **still unverified**. Full write-up + the 12 not-run classes: `docs/uitests.md` "Run status — 2026-09-20".

Still human-only: drag feel (Tier Board, divider drag's fixed 44 pt per game), animation, Continuity Camera (needs the owner's iPhone), grid scrolling with real covers, and everything in `docs/ACCEPTANCE.md`. Highest-risk interaction: Quick Add's floating panel owning the keyboard on macOS 15.

## 3. Found and fixed by the hardening pass (kept as lessons)

- **100 % CPU while idle** — the grid's context-menu builder wrote the selection during view updates (present since the first shell; no test could see it). Rule: nothing reachable from a `body` / `@ViewBuilder` / menu builder may write observable state; launch checks assert idle CPU ≈ 0 %.
- **Covers could be lost for good** — the 7-day "no cover" marker was timed with uptime (resets at reboot), and a network blip was cached as a genuine miss.
- **Stale stream emissions overwrote fresh ranking boards** (a tile could snap back; showed up as a flaky test). Tier Board and The Top now re-read on emission.
- **IGDB bundle members** — a game's `bundles` field lists its *parents*, not its members ("God of War Collection" got "God of War Trilogy" as its only member). Members now come from the reverse lookup; nested bundles expand; DLC/packs are dropped. The owner's library was repaired on 2026-09-19 (backup `vgn-pre-bundle-fix-…`).
- Matching: empty-normalised titles matched at 100 %; budget labels ("Pokémon Platinum") were over-stripped. Photo-scan sheet could not be dismissed from its first screen. Quick Add wrote sticky flags to real preferences in sample mode. **Unit tests read the owner's real preferences** (they run inside the app) — now isolated via `AppPreferences.defaults`.
- **Two dead-click bugs no model test could see (2026-09-19):** ⌘/⇧-click never multi-selected (a plain `onTapGesture` shadowed the modifier gestures), and the filter chips' ✕ / "Clear all" did nothing (a horizontal `ScrollView` touching the window toolbar swallows clicks). Both fixed; `ClickProbeWindow` now sends real mouse events to an off-screen, toolbar-shaped window, so clickability is testable headless.
- **Click-probe sweep extended (2026-09-20, wave 18 — lane C).** The sweep now covers the remaining primary controls (no new dead clicks found): **Duel** (both choice buttons), **Triage** (tier legend + Back/un-tier), **Tier Board** (tile click → single-select — the modifier-shadow shape), **The Top** (row click + empty-state "Start ranking"), **Play Next** (bracket segmented picker; hero Start / Not-this-one — "Open on IGDB" already covered by `PlayNextIGDBClickTests`), **Stats** (segmented scope picker + empty-state "Show all games"), and the sheets that host cleanly (**Choose Cover** tile, **bulk Mark Owned** confirm, **banner** secondary action) — see `VGNTests/UI/ClickSweep{Ranking,PlayNext,Sheets}Tests.swift`. The whole gate stays ~+6 s (Swift Testing runs the serialized suites in parallel with the rest). **Technique finding:** SwiftUI does **not** materialise its accessibility peer tree in an off-screen, never-key, in-process window (only ~60 AppKit chrome nodes exist, none carrying the app's `A11yID`s), so accessibility-identifier location does **not** work headless; targets are reached by **bounded coordinate sweeps in a region provably free of menus** (each click pop-up-guarded via `NSPopUpButton` hit-testing) plus precise **`NSSegmentedControl` segment** clicks for segmented pickers — never a whole-window sweep. **Not covered (skipped + why):** Play Next's alternative-card / "From the vault" buttons and its options **Menu** (menu-backed — never clickable in a test); The Top's "Export CSV" (opens a modal `NSSavePanel`); the reconcile **IGDB-link** and **Bundle-expansion** sheets (owned by lane W18-A this wave); Quick Add's panel (deferred). Play Next's hero "Never" and Choose Cover's single-tap select are the two `count:2`/modifier tap-stack cases — proven clickable via their neighbours / a double-click respectively.
- **Sidebar jumped up under the title bar — a whole CLASS, not one view (2026-09-20, wave 19 — lane D).** Selecting **Unranked** / **Played** scrolled the sidebar out of frame, exactly as **Bundles to Expand** did in wave 17. Root cause (both times): a view mounted in the `NavigationSplitView` **detail** column with an unbounded ideal height — a `Text` carrying `.fixedSize(horizontal: false, vertical: true)` — makes the split view size **both** columns to that height and pushes the sidebar's scroll view up under the traffic lights. Wave 17 fixed one instance (`BundlesToExpandHeader`, via `lineLimit`); the new instance was **`EmptyStateView`**, shown by the grid whenever a scope has no rows (genuinely empty, or its first rows not yet loaded). Three-part fix: (a) `EmptyStateView`'s message is now `lineLimit(6)` + a capped width, not `fixedSize(vertical:)`; (b) the grid shows a **quiet placeholder** (not the empty state) until the scope's first rows arrive — `LibraryViewModel.gamesLoaded` distinguishes "loading" from "empty"; (c) **structural guard** — `RootView`'s detail destination area is wrapped in a `GeometryReader`, the only container that actually contains the leak (`.frame(maxHeight: .infinity)` and `.frame(idealHeight:)` do **not** — proven in `SidebarJumpMatrixTests`), so no future detail view can move the sidebar. Guard test runs the full selection × (loading/empty/populated) matrix in one window plus a deliberately-bad injected child. Sweep: the only unbounded `fixedSize(vertical:true)` on wrapping text in the detail column was `EmptyStateView`; the Inspector's is inside a `ScrollView` (contained), and ranking/Play Next/Vault use single-line/control `.fixedSize()` (safe) — all left as-is.
- **Hosted-window click tests must poll, never fixed-sleep (2026-09-20, wave 19 — lane F).** `BatoceraClickProbeTests.addToLibraryButtonReceivesClicks` flaked 2/3 in a full parallel gate (passes alone in ~4.5 s; under load it ran 102 s and timed out). Cause: a coordinate sweep that slept a **fixed** tier (25/60/120 ms) after each click and checked the effect once — under load SwiftUI lags a click by more than the tier, so the sweep both **misses** the delivered click and **burns** time. This was the third load-sensitive hosted test (the earlier two — sidebar geometry — were also fixed by polling a post-condition instead of sleeping). Fix: `ClickProbeWindow` now has one poll-based primitive — after a click, poll the post-condition across run-loop turns (a MISS costs a single run-loop turn; after each full pass a patient settle poll of a few seconds catches the right click if SwiftUI lagged it — the click was still delivered), stopping at the first success, all bounded (`clickAndAwait` / `sweepUntil` / the `sweep*` band helpers in `ClickProbeLocator.swift`, and the count-returning `sweep` in `FilterChipsClickTests.swift`). Layout readiness (`settle`/`settleShort`/`awaitReady`) waits for the view tree to be stable across two run-loop turns instead of a flat 1 s. Every sweep click stays pop-up-guarded. No dead-click bug was found — it was purely a test-timing defect. Side benefit: the full gate dropped ~39 s → ~31 s (the 1 s fixed settle × ~40 hosted tests and the double-length sweeps were the fat).
- **Privacy incidents (2):** one full-screen screenshot by the orchestrator on day one, and a UI-test screenshot *fallback* (`app.screenshot()` captures the whole desktop on macOS) that showed other apps' windows. Both deleted, never committed; the second was read by an agent (processed by the model) and may persist in that agent's local transcript in the temp folder. Rules: never full-screen captures; UI tests screenshot `app.windows.firstMatch` or nothing.

## 4. Open items

### Delicious Library import (§5.5, wave 10)
- ~~**Own-cover fallback vs enrichment.** A Delicious cover would stick even when a better one existed.~~ **Fixed (wave 17, lane A):** an importer-supplied cover is now marked **provisional** (`games.cover_provisional`, migration v14). The background cover job still runs for such games and replaces the provisional cover the moment the provider chain (IGDB → libretro…) finds one; a user-chosen cover is never touched; a miss keeps the Delicious cover (the 7-day negative cache stops a refetch loop). Existing libraries were backfilled: a Delicious-origin, not-user-chosen cover that never went through a cover job (the identifiable "the importer supplied it" signal) becomes provisional. [done]
- **Title cleaning is heuristic** (match-title only; the original is always shown). The dry run over the owner's real file cleaned 20/103 titles well, but a few leave harmless residue in the *match* string only — a stray region tail ("Evolution Worlds - US"), empty brackets ("Resident Evil 2 [ ] [ UK Import ]", which the matcher's own bracket-stripping then removes), or a bundle cut at " + " that shortens a compilation's match ("God of war collection: God of war 1"). These affect only the IGDB query; the owner reviews and can pick an alternative or create manually. [watch]
- **Live cover application is window-only.** The reader, mapping, duplicate rules, commit payload and the cover DB setter are unit-tested; the end-to-end live cover apply (real cover directory + files) is exercised only by launching the app. [owner]
- **Covers not offered in matcher-less runs isn't a thing** — the toggle appears whenever a cover store exists (live and sample). In sample mode the cover writes to a temp dir, so it's a no-op for the real library.

### Library, Quick Add, search
- IGDB `search` misses mid-word prefixes and alt-name-only titles; the name-prefix / alternative-name fallback and the **typed-year filter** ("super mario bros 1985") cover the known cases; odd titles may still need "Create '…' manually". [watch]
- Enrichment never overwrites non-empty fields (plus the `user_edited` marker): a wrong-but-non-empty IGDB value is only replaced by "Refresh metadata". Manual entries (no IGDB id) get no metadata/time-to-beat, and a cover job only on platforms with a libretro repo.
- ~~Placeholder covers print a large platform label that the badges can overlap~~ **Fixed (wave 19, D2):** the large platform label was dropped from `PlaceholderCover` (it sat exactly on the badge row and collided with the badges) — the platform is already shown by the pill under the title. `platformID` stays in the view's API (callers pass it) but is no longer drawn.
- **What counts as a game — `game_type` policy (wave 19, W19-E).** One pure classifier (`GameTypePolicy`) drives one function (`IGDBClient.bundleMembers(ofBundleID:)` → `BundleMemberResult`) through which every bundle-member producer flows: non-standalone content (DLC/expansion/season/pack/mod/update) is dropped and reported ("Left out: …"), standalone expansions and episodes are kept, a **port** folds onto its parent game (one paced `games(ids:)` lookup, cached), and < 2 members ⇒ not a compilation.
  - **Not retroactive [by design].** Existing library entries are **never** removed or merged automatically — a *Season of Infamy* already in the library, or an existing port twin, stays until the owner acts (Edit Compilation… / the reconcile "Same Game, Two Entries" and "DLC & Expansions" lists built by lane W19-C). Only a *fresh* scan/expand/import applies the new rules.
  - **Standalone port matches (W19-E part 2) — done.** A port that appears *inside a bundle* folds via the member policy; a **standalone** port now folds too: an import whose best match is a port becomes the parent (one batched `games(ids:)` per sync, the resolved parent persisted so a resume never re-resolves, the review row noting "Port → the original"), and choosing a port result in Quick Add / Link-to-IGDB offers "link to the original" with a secondary "Use the port entry instead" (unresolved ⇒ the port itself). The parent-resolution seam is one defaulted protocol method on `ImportBundleExpanding` / `CatalogSearching` (fakes untouched); `ScanMatch` gained additive `foldParentID` / `resolvedFromPortID`. [done]
- ~~Compilation members keep IGDB's order (e.g. Mass Effect 2 · 1 · 3); reorder in the editor.~~ **Fixed (wave 17, lane A):** a compilation created from an IGDB bundle (Quick Add / photo scan / import review / bundle expansion / reconcile expand) now orders members by **first release date ascending** (unknown dates last, ties by IGDB order) through one shared pure function, `LibraryStore.orderedByReleaseDate`. **Existing compilations keep their order** — hand-ordered ones the owner arranged in the editor are never reshuffled; only newly-created ones are sorted. [done]
- ~~Deleting one copy of a multi-copy game (Mac + PC) left the removed platform's pill under the title for ever.~~ **Fixed (wave 19, lane C) — as a read rule, not a data change (owner decision 2026-09-20):** the platforms a game shows / is counted / filtered under are now computed from its **copies** (∪ its `played = 1` rows) for an owned game, or from all its `game_platforms` rows for a played-not-owned game (PLAN §4 inv. 4, one shared `LibraryQuery.effectivePlatformsSQL`). Deleting or re-platforming a copy corrects the pill / inspector / sidebar count / stats / export instantly, for the owner's existing 12 stale cases as well as new ones — **nothing is deleted or repaired**; the stale `game_platforms` row just stops being read. A `played = 1` row (a "played on" statement) always shows; a game never ends with zero platforms (a game with no copy falls back to its rows). The earlier one-shot launch repair was reverted before it ever ran and removed. [done]
- **Copy removal is undoable (wave 19, lane C):** un-owning / removing a copy from the inspector trash or ⇧O now registers a **"Remove Copy"** undo step that restores the product row(s) (incl. `external_id` / `subscription` / `acquired_at`), their `product_games`, and any game deleted as an orphan — reusing the reconcile snapshot machinery (`LibraryStore.removeProductsCapturingUndo`). The grid query at 2 000 games is now ≈ 69 ms (DEBUG) — up from ≈ 33 ms — because the shared effective-platform rule scans copies ∪ played-on rows per game; well within budget, Release is far faster. [done]
  - **Follow-up [handoff]:** the **compilation editor's** "remove member" (a separate sheet using the `CompilationWriting` protocol, no window `UndoManager`) is **not yet** undoable. The store method is ready (`LibraryStore.removeCompilationMemberCapturingUndo`, tested); wiring it needs `removeCompilationMemberCapturingUndo` added to `CompilationWriting` and the sheet's `@Environment(\.undoManager)` threaded into `CompilationEditorModel` to register `store.restoreReconcile`. Deferred rather than half-built (the primary inspector/⇧O paths are done).
- Grid query ≈ 33 ms at 2 000 games (DEBUG), one full re-query per emission, no paging. [watch]
- **Mark Played As** (wave 7, ⇧M / context menu / Game menu): the ⇧M shortcut is displayed as **text only** ("Mark as Finished   ⇧M"), not a SwiftUI menu key equivalent — a shift-only equivalent would register globally and steal a capital "M" typed in the search field / Quick Add. The key itself is handled by the pure `GridKeyRouter`, so it is unit-tested; that the menus *render* the hint and that ⇧M does not leak into text fields is window-only (see `docs/ACCEPTANCE.md`). Selection reselection after a Backlog mark is keyed to the next grid observation emission (fine for a single window; an unrelated emission arriving first would cancel the plan). [watch]
- **BY LENGTH shelves + weekly play pace** (wave 9, lane C):
  - ~~**Sample mode is not special-cased**, so a pace set while running `-VGNSampleData` persists to the real `.standard`.~~ **Fixed (wave 17, lane A):** `AppPreferences.defaults` now returns a throw-away suite for a `-VGNSampleData` / `-VGNSeedGames` launch too (not only the test host), so pace, play style, PS Plus deadline **and** sort order stay isolated in sample/seeded modes — one choke point instead of per-model wiring. [done]
  - The sidebar popover and Settings ▸ General share the **same store**, so a change in one shows up in the other on its **next open** (`reload`), not live across the two open windows simultaneously — full live cross-window sync was not built. [watch]
  - In **sample/preview mode** every "By Length" shelf count reads 0 and Unmeasured stays hidden, because `GameSummary` carries no time-to-beat estimate; the in-memory `LibraryFilterEvaluator` treats a length scope as "no constraint" there. The live GRDB path bands for real. [by design]
  - ~~The pace is exposed as `vm.playPace` for a later Play Next alignment but nothing consumes it yet.~~ **Done (wave 10, lane C):** Play Next's time brackets are now the five `LengthShelf` shelves; `TimeBracket` carries the shared `PlayPace` and derives its bounds from `LengthShelf.bounds(for:)` — one source of truth with the sidebar. A pace change (sidebar popover / Settings) recomputes Play Next once via `PlayNextBody.onChange(of: paceModel?.pace)`. The engine weights were **not** retuned; only the bracket bounds feeding `TimeFit` changed (`TimeFit` already handled open-ended ends, so no width-proportional tolerance was assumed).
  - Adding the section changes the existing **sidebar snapshot references** (`snap-library-sidebar@light/dark.png`); per the brief they were **not** re-recorded — the snapshot suite (opt-in, not the default gate) will flag them until a hardening lane re-records. [handoff]
- **Personal length / play style** (wave 10, lane C):
  - The missing-side inflation ratio **R = 1.5** is a **named constant** (`PlayStyle.sidesRatio`), not measured per library (owner's library median completely ÷ normally = 1.54, so 1.5 is close). Could later be measured per library, per genre, or merged with the filed "personal pace factor" idea (§7b — inflating advertised times by my own ratio). [later]
  - `LibraryFilter.playStyle` **defaults to `.storyFirst`** (raw main-story length) so a bare/legacy filter bands by the plain `normally` estimate; the app always injects the owner's real style (`PlayStyle.default` = lots of side quests) through `LibraryViewModel`, and "Clear all" preserves it. The mismatch between that default and `PlayStyle.default` is deliberate (keeps neutral filters showing the plain advertised time). [by design]
  - ~~**Stats window** ("backlog in hours", `LibraryStatsStore`) still sums the raw `ttb_normally_s`, not the personal length.~~ **Fixed (wave 17, lane A):** "Backlog to beat" now sums the owner's **personal length** at their play style (the same source of truth the BY LENGTH shelves use; a rushed-only game counts as *without an estimate*), and the card labels the basis ("≈ … at your play style · N games, M without an estimate"). The Stats window re-queries on a play-style change (via `vgnPlayStyleDidChange`), like the shelves. "Me vs. average" deliberately still uses the raw advertised `ttb_normally_s` — that is what the comparison is against. [done]
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
  - ~~**IGDB contributes only the game's cover** — `artworks` are not modelled.~~ **Fixed (wave 17, lane A):** the sheet now also offers the game's IGDB **artworks** (labelled provider · kind · size), fetched on demand when it opens through the shared IGDB client + rate limiter (`IGDBClient.artworks(forGameID:)`), nothing stored until a candidate is picked; live mode only (sample stays network-free). Landscape artworks preview with the same portrait crop the grid uses, so the owner isn't surprised. Screenshots were left out (optional, and rarely good box art). [done]
  - **libretro browsing shows the best-matching title's regions/discs/revisions only** (the top fuzzy-score cluster), not near-but-different titles like numbered sequels. Capped at 60 tiles.
  - **Candidate listing is live-mode only.** Sample mode (`-VGNSampleData`) must not touch the network, so the sheet lists no remote candidates there — the local "Choose File…" path still works. [watch]
  - **Entry point is the inspector only.** A grid context-menu entry was out of reach this wave (another lane owns `LibraryGridView.swift`); add "Choose Cover…" there in a wave that owns the grid. **[later]**
- Catalogue-cache title search is a linear scan per keystroke and the cache is never pruned. [later — owner chose not now]
- **IGDB read cache (W19).** `catalog_cache` is now a read-through cache: id-keyed reads (enrichment metadata, Vault trait match, importers, bundle members, Choose Cover artworks) serve a fresh (≤30 d), shape-adequate hit without a request; search/autocomplete has a short-lived in-session LRU (≈15 min, ≈200 queries) with in-flight coalescing. Freshness is **per shape** (part 2A): each shape carries its own `_vgn_fetched` stamp, so a slim search sighting never renews the metadata clock — a metadata hit needs its own stamp within 30 days. The cache is for **speed / not re-asking IGDB, never a way around the 4 req/s limit** — every miss still goes through the one `RateLimiter`; no prefetch, warming or bursting. Notes on what stays **uncached** and why:
  - **Time-to-beat (`game_time_to_beats`) is not cached.** It is a separate endpoint not covered by `catalog_cache` and the brief says only cache it if it fits the table with no schema change. It is a *batched* endpoint (one request covers a whole batch), and enrichment's job store already prevents re-querying a game whose TTB job is done, so the marginal benefit is low; making a cache actually reach "zero requests" would need negative-result tracking (games IGDB has no time for) and risks polluting the shared game blob / title index. Left uncached deliberately. [watch — revisit only if a profile shows repeated TTB traffic]
  - **The owner's ~3 300 existing `catalog_cache` rows carry no `_vgn_fields`/`_vgn_fetched` markers**, so id-keyed reads treat them as satisfying nothing (or fall back to the row `fetched_at` for a mask that is present) and refetch-then-tag on first use (one-time, correctness-safe). Offline title search over them is unaffected. [expected]
  - **Search LRU is not forced anywhere today.** The client exposes a `force` search path, but the "Change IGDB Match…" / re-match sheets use the cached path: within the 15-min TTL IGDB search results are stable, so forcing would return identical rows. The substantive explicit-refresh (`force`) is wired on the persistent path (Refresh metadata → `games(ids:force:)`). [watch]
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
- **PSN bundles expand too — done (W18-A, 2026-09-20).** The PSN review expands a bundle into a
  compilation (one Product per ownership kind; no product for played-not-owned; members deduped),
  asks "Which did you play?" once in the row with the exactly-one play-data routing, drops platform
  tails for matching, and folds cross-gen twins under one row. **Bundles to Expand** gained
  **Expand All Unplayed (N)…** (batch fetch one-at-a-time, cancellable progress, one confirmation,
  one undo), candidate detection also by IGDB `game_type` via `match_json`, and the per-game expand
  sheet's per-member played ticks + tier/rank picker. The single-played member is remembered as the
  staging row's `matched_game_id` so re-sync routes updates to it. Tests: `PSNBundleReviewTests`,
  `BundleBatchExpandTests`. Remaining caveats:
  - **The compilation view's "N h on the whole collection (PSN)" line is rendered (part 3).** The
    inspector's compilation copy row shows it under "Part of …" (`CompilationCollectionPlaytimeLabel`,
    one line, `minimumScaleFactor` at the 300 pt minimum), fed through the detail read
    (`GameDetail.Copy.collectionPlaytimeS` ← `LibraryStore.collectionPlaytimeSeconds`) — never a DB
    read from a `body`; nothing shown when there is no record or the time was routed to a single member.
    Not added to the Compilation *editor* header (it would be a multi-file change through
    `CompilationProductInfo`, past the "two-line" bar the brief set). **[minor follow-up]**
  - A re-synced compilation reuses its existing `(source, external_id)` Product and does **not**
    rewrite its `subscription` (a PS Plus claim that became a purchase keeps the old flag) — the same
    behaviour as a single import copy. **[watch]**
  - Cross-gen twin folding in the review is a display safety-net: it hides the older twin and never
    commits it, but does not merge that twin's independent owned/played signals into the kept row
    (`PSNMapping`'s merge index already collapses true twins that share a concept/title id or
    canonical name — this only catches the residual tail-only case). **[watch]**
- **Import bundle expansion (GOG + Delicious) — done** *(2026-09-20)*. `ScanMatch` now carries the
  IGDB `game_type`; the sync coordinator fetches a bundle match's members during matching (behind
  the `ImportBundleExpanding` seam, shared IGDB client) and the review row commits as a compilation
  (§5.1). Caveats:
  - ~~**Batocera promotion does not expand bundles**~~ **Fixed (wave 17, lane D — D2).** A Batocera
    ROM whose confident IGDB match is a bundle now promotes as a `rom`/`batocera` **compilation**
    with its members, on the review path AND the favourites auto-add path. The coordinator runs
    the shared `ImportBundleExpanding` seam for Batocera; the review row carries the expansion to
    the committer through two additive fields on `ImportReviewCommitRow` (`bundleTitle` /
    `bundleMembers`); `BatoceraPromoter.Plan.bundle` + `BatoceraPromotionBuilder.compilationCommitItem`
    commit the `.compilation` item. `promoted_game_id` points at the **first member** (so In-Library
    detection — `promoted_game_id IS NOT NULL` — works for a compilation), and the ROM's play
    time / last played land on that member **only when the bundle resolved to exactly one member**
    (else dropped from games, kept on the catalogue row — PLAN §13.3). Auto-add expands only a
    confident bundle with **≥ 2 members** (a 0/1-member one waits for review). Undo removes the
    whole compilation (its members are orphan-deleted). **[done]**
  - **A committed compilation row is not marked `matched_game_id`** (a compilation has many members,
    the column holds one). Re-import is still safe/idempotent — the `(source, external_id)` guard
    skips it — but the review sheet re-lists it as *New* until the product exists; ticking it again
    just yields "already in your library". **[watch]**
- **Reconcile: a bundle now expands, not disabled** *(2026-09-20)*. Choosing a bundle in the
  "Link to IGDB…" sheet, or the **"Expand Bundle into Games…"** repair action, turns the placeholder
  into a compilation (`LibraryStore.expandBundle`, fully undoable). Scope caveats:
  - **Bundle detection on the repair path is by empty-member-list**, not a `game_type` check:
    `CatalogSearching` has no "metadata by id", so the presenter fetches members and treats *no
    members* as "not a bundle" (a single game, or a bundle with no IGDB coverage, both no-op with a
    note). Good enough for the conservative requirement; a `game_type` lookup would distinguish the
    two. **[watch]**
  - **The discoverable "Bundles to Expand (N)" list is a store query + per-game action, not a
    dedicated sidebar list.** `LibraryStore.bundleExpansionCandidates()` (title heuristic:
    Trilogy/Collection/Anthology/Compilation/Pack/"N in 1"…) is ready, and the per-game "Expand
    Bundle into Games…" action is wired (inspector + File menu). Surfacing the candidate count as its
    own Unlinked-style section is a follow-up. **[follow-up]**
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

### Suspicious estimates (wave 18, lane B — PLAN §5.3)
Flags a game whose stored times look wrong (out of order, completionist ≥ 4× main, rushed < 0.25×
main, or a lone completionist) so the owner can refresh them from HowLongToBeat. Pure rule
`EstimateSanity` (Model) with the SQL mirror in `LibraryQuery`; a parity test proves they agree.
- **The dismissals live in `app_state`** (`estimate.looksRight`, a JSON id array — same mechanism as
  `reconcile.notBundle`), **no schema change**. `LibraryQuery`'s length expression and the filter
  read that key directly via `json_each`, so the grid / BY LENGTH shelves / Stats re-run live when a
  game is dismissed or flagged again. (Requires the SQLite JSON1 extension, which the system SQLite
  GRDB links has.)
- **The dismissal set the inspector's ⚠︎ reads is cached on the HLTB presenter** (loaded once,
  updated optimistically on toggle), not carried on `GameDetail`. Across two open windows a dismissal
  made in one flips the other's grid/shelves immediately (SQL reads `app_state`) but the *inspector*
  ⚠︎ in the other window refreshes only when its presenter next reloads — acceptable for a
  single-owner app; a full cross-window observation was not built.
- **Personal-length fallback is completionist-only.** A flagged **completionist ≥ 4× main** is
  ignored for planning and falls back to `main × PlayStyle.sidesRatio` (1.5) — the BY LENGTH shelves,
  the Length sort, Stats "Backlog to beat", Play Next's time input and the Vault scorer all use the
  shared expression, so they agree. The **main**-implausible cases (`rushed > main`, `main >
  completionist`) keep the stored pair and rely on the existing `completely < normally` clamp
  (which collapses a dirty completionist to the main story) — a deliberate "use the ordered pair
  conservatively" choice. A **lone flagged completionist** (no main) keeps its stored
  completionist-only estimate rather than becoming Unmeasured, because there is no main to fall back
  to (it is still surfaced in the filter so the owner can refresh it). The inspector always shows the
  raw stored values (plus the ⚠︎); a dismissed game uses its raw values again.
- **Refresh (replace) semantics.** "Refresh Time Estimates from HowLongToBeat…" **overwrites** all
  three `ttb_*` columns with HLTB's values and stamps `ttb_source = 'hltb'` (so the game leaves the
  filter); it never touches the owner's own **playtime** (`my_playtime_s` / `psn_playtime_s`). If
  HLTB has the game but lacks one of the three times, that column is set to NULL (HLTB is the new
  reference) — usually HLTB has all three. A game HLTB does not know is left untouched and stays
  flagged. One Undo step restores the whole batch's previous times + source.
- **Not retuned.** The recommendation weights and the taste backtest were not re-tuned for the
  fallback length (per brief).

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
- **Corrected from the real account (wave 14, lane A — offline, no new Sony traffic).** The gated live steps S1–S6 were run with the owner and revealed several shapes the S0 assumptions got wrong; all fixed against synthetic fixtures (see `docs/psn-import.md` "Live log" + "Mapping"):
  - **One trophy list**: the endpoint ignores `npServiceName`, so the separate PS3/Vita data set / probe (panel S3a′) / fetch is gone; the list is fetched once, each title's own `npServiceName` kept. Combined `trophyTitlePlatform` (`PS4,PS5`, `PS3,PSVITA`) → newest slug.
  - **Game list `service`** (`none(purchased)` / `ps_plus` / `other`) drives ownership; **`category`** gives the platform and flags media apps (not ending `_game`). `concept.id` (Int) vs purchases' `conceptId` (String/null) unified via `PSNFlexibleID`.
  - **Cross-gen twins** (PS4 + PS5 entitlement of one game) collapse to one copy (ps5 preferred, "PS4 & PS5 versions", stable external id on the PS5 entitlement; a bought twin beats a Plus twin).
  - **The Vault gate (PLAN §16, `ImportPolicy.vaultPlaytimeGateSeconds = 600`, shared with Batocera — its old 300 s rule raised to 600)**: a `PS_PLUS` claim played ≤ 10 min is staged *Ignored* (`.vaultedSubscription`) for a later lane to move to the Vault; > 10 min → owned-via-subscription. Bought copies never vaulted. Review header: "PS Plus: N played · M in the Vault". **A later lane still owns the actual Vault table/migration v11 and moving these rows there** — for now they sit in the review sheet's *Ignored* bucket, restorable, and are simply not imported.
  - Panel steps are now S2 · S3a · S5 · S6 · three full fetches; full-fetch estimates 1 / 2 / 6 (trophy 265, game list 231, purchases 581 from the probes).
- **Still not run against the real account: the FULL fetches + first real review.** Only the tiny probes (S2/S3a/S5/S6) were made. The full real fetches (trophy 265, game list, purchases 581 → 6 pages) and the first real review sheet are untested with real data — watch the cross-gen merge, the Vault counts, and the ™-stripped IGDB matching on real names. The `getPurchasedGameList` persisted-query hash is confirmed valid (S6). Nothing in this lane made a request to Sony.

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
- ~~**First-run batch cap is a constant** — ~247 favourites take ~4 syncs.~~ **Fixed (wave 17,
  lane D — D4).** `batchCap = 60` is now the **batch size**, not the run limit: after a sync the
  presenter runs batches back-to-back (`runFavouriteMatching`, one IGDB request stream,
  cancellable) until no un-attempted favourite remains, so one sync matches them all. It **pauses
  cleanly on any IGDB error** (the auto-add pass uses the *throwing* matcher, not the resilient
  wrapper; the first failure stops the run — no retry storm — and the not-yet-attempted favourites
  wait for the next sync). Resume across quits/cancels is unchanged (staging rows guarantee no
  double query). One final banner: "N favourites added from Batocera · M need your review" with
  **Undo** (the whole run = one undo step) and **Review…**.
- **Finding the review after a Settings sync [done, wave 16].** Settings ▸ Batocera now shows a
  **Review…** button on the status line (next to "N waiting to review", when N > 0) and next to
  the post-sync "· N to review" summary; it brings the main window forward and opens the same
  review as File ▸ Import from Batocera… (`BatoceraSettingsModel.onReviewRequested` →
  `BatoceraImportPresenter.reviewCandidates()`, wired in `BatoceraBuilder`; inert in
  sample/test). The favourites-added banner keeps **Undo** and now also offers **Review…** as a
  **secondary** banner action when there are candidates (additive `LibraryBanner.secondaryActionTitle`
  + `LibraryViewModel.performBannerSecondaryAction()`), so the owner is never stranded behind an
  Undo-only banner.
- **Favourites-matching progress line [done, wave 17 — lane D, D4].** Settings ▸ Batocera now
  shows **"Matching favourites… 120 of 247 · Stop"** while the background pass runs. The presenter
  and the settings model share one small `@MainActor @Observable BatoceraFavouriteProgress` (no
  timer, no polling — values change only when a batch finishes, so the app idles at ~0 % CPU); the
  Stop button cancels the run cleanly. **The quiet in-window progress banner was deliberately
  skipped** (the banner API is one-shot messages; a live-updating banner would fight the other
  banners and is not cheap) — the Settings status line + the single final banner cover it, per the
  brief. **[eyeball: the Settings "Matching favourites… N of M · Stop" line during a live sync]**

## 5b. The Vault (PLAN §16, wave 14)

- **Data / logic / ingestion are in; some UI is not yet wired [doing].** Migration **v11**
  generalises `rom_catalog` to hold PS Plus entries (nullable columns, additive, FTS
  untouched); the store has the Vault methods (`syncPSNVault`, `sourceCounts[Observation]`,
  `unmatchedPSN`, `setVaultMatch` / `setVaultNoMatch`, `psnMatchProgress`,
  `setPromotedByExternalID`, `vaultPool`); the sidebar is **THE VAULT** with per-source rows;
  PS Plus ingestion runs after a PSN sync through the coordinator; `PSPlusDeadlineBoost` is
  wired into the engine and the vault scorer. **Not yet wired this wave:**
  - **IGDB trait-matching pass for PS Plus entries** — the store side is ready
    (`unmatchedPSN(limit:)` / `setVaultMatch` / `setVaultNoMatch`, ≤ 60 per run, `match_state`
    guards re-query), but the background service that drives the existing matcher + rate
    limiter (like `BatoceraFavouriteAutoAdd`) and the Settings status line
    ("Vault: N of M matched") are **not built**. Until then PS Plus entries stay unmatched, so
    they are browsable but never suggested in "From the vault" (`isSuggestable == false`).
  - **Browser PS-Plus row** — the browser is source-scoped, but the PS Plus row rendering
    (remote cover through the cover cache, "PS Plus"/"+" marker, IGDB year/genre once matched,
    *Add to Library…* via the PSN review, *Open in PlayStation Store*) is **not built**; the
    system picker shows platform slugs.
  - **Play Next "From the vault" row** — `DiscoverScorer` scores both sources and `vaultPool`
    returns both, but `DiscoverModel`/`DiscoverRow` still read the Batocera-only pool and show
    "Discover on your Batocera". The one combined row (and its rename) is **not wired**.
  - **Settings deadline picker** — the engine and scorer accept `psPlusMonthsLeft` / pace, but
    the *"I plan to leave PS Plus around [month year]"* picker + `AppPreferences` persistence
    and the store threading months-left into `RecommendationOptions` are **not built**; the
    old "Prefer expiring PS Plus games" toggle is **not yet renamed** to "Prioritise PS Plus
    games" / defaulted on in the UI (the engine default stays off for backtest neutrality).
  - **Review-sheet "In the Vault (N)" group** and **promotion-on-play linking**
    (`setPromotedByExternalID` exists but is not called from the commit path) are **not wired**.
- **Vault removal on an empty purchases fetch [watch].** `syncPSNVault` marks absent claims
  `removed_at`. The importer only builds vault entries when purchases were actually fetched
  (`includePurchases && !purchases.isEmpty`) and the presenter only upserts when
  `vaultPresentIDs` is non-empty, so a skipped/rate-limited purchases page never wrongly
  empties the Vault. A legitimate sync with zero remaining PS Plus claims would (correctly)
  remove them; `removed_at` is recoverable, not a delete.

## 5b. The Vault — wave 15 (UI wired)
- **The "Not yet wired" list above is now done [done].** The IGDB trait pass
  (`VaultTraitMatcher` + `VaultTraitMatchModel`, Settings status line + "Match more now"),
  the PS Plus browser row (remote cover, "+" marker, IGDB facts, match state, Add to
  Library…, Not Interested, Find match…), the Settings deadline picker threaded into both
  scorers, the review sheet's collapsed "In the Vault (N)" group + "Show in the Vault",
  promotion-on-play linking, and the "Prioritise PS Plus games" rename (on by default) are
  all wired. Matching progress now shows a determinate bar + "Matching N of M · Title" + ETA.
- **No PlayStation Store link [by design].** A correct product URL is not derivable from the
  stored fields — the PSN external id is an entitlement id, not a store/concept id
  (`conceptId` is null on every purchase row, `docs/psn-import.md`). The action is omitted.
## 5b. The Vault — wave 16 ("Send to the Vault" wired · resume after cancel)
- **"Send to the Vault" (the fourth fate) is wired [done].** Migration **v13** adds
  `import_titles.vaulted` (the persisted decision — `ImportDecision.vault` / `.unvault`). The
  review sheet has a per-row **Send to the Vault** action (row menu), a group action
  ("Send N to the Vault" in the bucket header, and per PSN group), a collapsed read-only
  **In the Vault (N)** group with **Show in the Vault** + a per-row **Bring back**, and a
  per-model **Undo** (`undoLastVaultSend`; `UndoManager.undo()` hangs headless, so the model
  keeps its own undo stack — tests drive it directly). The decision survives the next sync (the
  row never re-lists). Vault rows are written through `RomCatalogStore.sendToVault` with
  `owned = 1` for GOG / Delicious / a purchased PSN copy, `owned = 0` + `membership` for a
  hand-vaulted PS Plus claim (so it keeps the deadline boost). `VaultSource` gained **`.gog`** /
  **`.delicious`** cases (stable ids `vault:gog` / `vault:delicious`), so those rows are
  browsable in their own sidebar rows (shown only when count > 0) and suggested by "From the
  vault"; `DiscoverScorer.vaultPool` now includes them, and gives an `owned` entry no PS Plus
  term. **What a human must eyeball:** the review sheet's Vault section rendering, the sidebar
  GOG/Delicious Vault rows, and that the GOG/Delicious browser row shows "Owned" — all
  window-only (the model/store are unit-tested).
- **Resume matching after cancel [done].** The coordinator persists each *New* row's outcome
  (`match_attempted_at` + a `match_json` blob = outcome + bundle expansion), so a
  cancelled-then-restarted or a second sync **skips already-attempted titles** (never
  re-querying IGDB), restores their alternatives and bundle members, and re-queries only
  never-attempted titles and no-match ones older than 30 days (or on a per-row Re-match via
  `ImportStagingStore.clearMatchAttempt`). Bundle expansions are **persisted** in the same blob
  (not recomputed). The progress detail shows "… · N already matched".
- **Per-row "Re-match" in the review sheet [done, wave 16].** A New row now has a **Re-match**
  affordance (a small button + a row-menu item) that calls `ImportStagingStore.clearMatchAttempt`
  and re-runs matching for **just that title** through the injected `ImportMatcher` seam — the row
  shows a cancellable spinner (click it to cancel), never a whole-sheet re-match; the fresh
  outcome is persisted so a later sync reuses it. Wired for **GOG / Delicious / PSN** (the live
  backends expose their matcher via `ImportBackend.rematchMatcher`; a no-match matcher — IGDB
  unconfigured — hides it). **Hidden for Batocera** (`romPromotion`): its ROM rows match by
  libretro filename, not the IGDB title ladder, so a title re-query is meaningless there.
  Model + seam are unit-tested; the button/spinner rendering is window-only. **[eyeball: the
  Re-match button + spinner in the GOG/PSN/Delicious review sheet]**
- **Committed compilation rows no longer re-list as New [done].** The compilation commit path now
  marks the staging row matched (to the first member), so a re-sync lands it under *Already
  matched* (D4, §5.1); re-import stays idempotent on `(source, external_id)`.
- **Bundles-to-Expand list [done, wave 16].** Now a **sidebar smart list** exactly like Unlinked
  (orchestrator decision: consistency beats a separate panel). `SidebarSelection.bundlesToExpand`
  is a LIBRARY row right under Unlinked, shown only when its count > 0, with a live count badge;
  selecting it renders the normal grid scoped to the candidate game ids, under a slim explanatory
  header. The candidate rule lives in **one place** — `LibraryStore.fetchBundleExpansionCandidates(_:)`
  (the title heuristic `looksLikeBundleTitle` + the "not already a compilation member" guard +
  the persisted "not a bundle" dismissals) — shared by the count (in the single sidebar-counts
  observation), the grid scope (`LibraryStore.fetchGames` computes the ids and passes them to
  `LibraryQuery.gamesSQL(_:restrictToIDs:)`) and the async `bundleExpansionCandidates()` API. The
  heuristic is a Swift regex + keyword list SQL can't express cheaply, so the ids are computed in
  Swift once per relevant DB change (the observation reads `games`/`product_games`/`app_state`, so
  an expansion or a dismissal re-runs it and the badge + grid follow — no timer, no callback).
  Cost printed, not asserted: ~a few ms to scan 2 000 titles (see `BundlesToExpandScopeTests`).
  "Expand Bundle into Games…" is in the grid context menu (single selection) as well as the
  inspector + File menu. The never-mounted `BundlesToExpandModel`/`BundlesToExpandView` were
  **deleted** (no dead code); the file now holds only `BundlesToExpandHeader`. **[eyeball: the
  sidebar row + count, the grid header, and Expand from the grid context menu]**
- **Stale sidebar snapshot references [watch].** Snapshot tests under `VGNTests/Snapshots/**` that
  render the sidebar do not yet include the "Bundles to Expand" row (it only appears when the
  sample library has a candidate, which the current sample data has none of). No snapshot needed
  re-baselining this wave; a future sidebar snapshot that seeds a bundle candidate should add it.

## 5g. Empty states / progress / inspector polish (wave 17 — lane B)
- **Vault empty states have no button.** The "source not set up" Vault empties (Batocera / PS Plus)
  point the owner at **Settings ▸ Batocera / PlayStation** in the sentence but show **no button**:
  there is no programmatic "open a specific Settings tab" seam today (`SettingsView` is a plain
  `TabView` with no selection binding). **[follow-up: add a Settings tab-selection seam, then wire
  these two buttons + the inspector could reuse it.]**
- **Import review sheet "nothing to review" not done here.** `ImportReviewSheet.swift` is owned by
  the W16-B lane; the empty branch ("Everything is already in your library") should be added there.
- **Tier Board / Duel / Triage keep their own empty views.** The Top, Play Next, Stats, the grid and
  the Vault now use the shared `EmptyStateView`; the Tier Board still communicates emptiness with
  per-row "Drop games here" placeholders + the header **Place N** button (no full-board overlay), and
  `DuelEmptyStateView` / the Triage "complete" summary are bespoke (already rich, with Refine / Go to
  Triage / Start duels actions) and were left as-is rather than reshaped to the shared view.
- **Grid no-results shows at most two buttons.** The shared `EmptyStateView` caps actions at two, so a
  scoped search with facets prefers **Search all games** + **Clear filters** over also offering the
  **Add "query"** quick-add (which still appears when there is room). Behaviour, not a defect.
- **"From the vault" Play Next row.** The owner asked for an "Open on IGDB" button on it too, but Play
  Next has **no vault row today** — nothing to add there yet. The button is on the hero + alternative
  cards, gated on the game having an IGDB id.
- **IGDB link is a search URL.** "Open on IGDB" (cards + reconcile sheet) opens IGDB's *search* page
  keyed on the title (`IGDBWebLink`), not a direct game page — IGDB has no stable public URL from the
  numeric id alone. One scheme, shared.

## 5h. HowLongToBeat cache / platforms / manual link (§5.3, wave 20) — as built
- **The query ladder never re-scores against the raw stored title.** It matches candidates against the
  ladder query that fetched them (rung 1 = the raw title, deeper rungs = the cleaned name), so a game
  found only under its clean name still matches. It does **not** yet use IGDB `alt_titles` as extra
  match targets (D3 mentions it as optional; the alias matching lives on `HLTBCandidate.aliases` only).
- **Platform overlap is a small tie-breaker, not a hard filter.** A candidate on a different platform is
  never rejected — it just loses a title tie. `HLTBPlatformMap` covers the platforms HLTB catalogues;
  obscure slugs (WonderSwan, CD-i, Vectrex, MSX2…) have no entry and simply don't participate. The
  non-fixture spellings (Genesis/Mega Drive, TurboGrafx, Neo Geo…) are best-effort — only the
  fixtures' names are lint-checked.
- **The inspector "Linked to HowLongToBeat" caption shows no name.** `games` stores only `hltb_id`, not
  the HLTB title; the remembered name lives in the `id:<hltbID>` cache but the inspector detail doesn't
  read it, so the caption is name-less. Wiring the name through would need a detail read of the id-key
  entry (small follow-up).
- **The bulk "Find…" per-row button opens a sheet over the bulk sheet.** It calls the presenter's find
  flow; presenting a sheet over a sheet is functional but the bulk sheet stays up behind it. Not
  snapshot-tested. The picker "Choose…" path (with platforms) is the primary in-bulk resolution.
- **No snapshots were re-recorded.** The picker and Find sheets are new; the hardening snapshot lane
  should add references. No existing filter-chips snapshot was found to re-record for the result count.
- **`HLTBFindModel`'s request counter is a model-level count**, not a read of the client's
  cache/network tally: it counts each distinct in-session query it issues (identical queries are served
  from its own cache and don't count). The client's DB cache may still answer at zero network cost.

## 5i. Filter result count (§8, wave 20) — as built
- **The total is the sidebar scope count, not a fresh query.** For a scope the VM has no count for (a
  platform row, a BY LENGTH shelf), the line degrades to "N games" with no "of M" — by design (no
  second grid query). Right-alignment is approximate: the count is the last item in the wrapping flow
  after "Clear all", not pinned to the trailing edge, and it drops its whole self (lower layout
  priority) rather than only the "of N" part before the chips wrap.

## To-revisit play status (owner, 2026-09-20) — NOT built, needs its own lane
- Owner asked mid-wave-20 for a **"To revisit"** play status: an abandoned game flagged as wanting to
  play again. This spans a **migration** (a new `PlayStatus` value — a single-owner hot file), the
  `PlayStatus` model enum + its filter/sidebar facet, the inspector status control and the grid badge.
  It is outside the HLTB lane's owned paths and was **not** implemented here — it needs a data+UI lane
  (there is already a `PlayStatus` type and a `games` status column to extend).

## 6. Owner to glance at [owner]
- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**.
- Tier palette and derived-score bands (`VGN/Ranking/DerivedScore.swift`) — constants.

## 7. Engineering notes
- `claude -p` runs with an allow-listed environment (no `ANTHROPIC_*` can reach it, never `--bare`) → the owner's subscription; `total_cost_usd` is notional.
- The Xcode project was hand-written, then normalised by Xcode on 2026-09-19 (ids reordered, a "Recovered References" group) — harmless. Never add source files to it by hand; Swift basenames and type names must be unique across the target; bundle resources are flattened.
- Tests: hosted in the app (XCTest-host guard builds nothing), `@MainActor` + GRDB ⇒ serialized suite, async tests need hard timeouts, `UndoManager.undo()` hangs headless, preferences are isolated. Never launch a dev build against the real library except at the owner's request; use `-VGNSampleData YES` / `-VGNSeedGames n`.
- The live accuracy harness finds `samples/` from `main/` or a worktree; subset runs write to `.build/scan-accuracy/` and no longer touch the committed report.
- Subagents run on the `opus` alias (not pinned to a version). Two harmless build notes remain (AppIntents metadata; "Disabling hardened runtime with ad-hoc codesigning").

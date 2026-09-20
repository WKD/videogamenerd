# VGN — Human acceptance checklist & known issues

Things machines can't judge (or that need the owner's data/eyes). Updated by the orchestrator as features merge. Machine gates (build, tests, launch smoke) are not repeated here.

## To verify by hand

### Wave 0 / M0
- [x] `docs/shelf-truth-draft.json` — **owner-reviewed 2026-09-18.** Items per photo: 3683: 59 · 3684: 20 · 3685: 27 · 3686: 1 · 3687: 93. It is now the answer key for the M6 accuracy run.
  - Owner corrections applied: MGS V = *The Phantom Pain* (special vendor SteelBook); one Elden Ring (the second spine was an empty sleeve); PS5 *Death Stranding* is *Death Stranding 2*; *Deponia* is *Goodbye Deponia*; *Catherine* (PS3) added after *Darksiders* in 3684/3685; *Alice: Madness Returns* is Xbox 360; the *L.A. Noire* in 3684 is the Xbox 360 copy; IMG_3683 rebuilt (the draft had 30 of ~59 spines and two games that are not in that photo).
  - Closed 2026-09-18: PS5 *FF VII Remake* is not Intergrade; the two unlabelled spines in IMG_3687 are skipped (`skip` in the JSON) — unreadable spines are never guessed, neither by the answer key nor by the recogniser.
  - **Lesson for the M6 recogniser/harness** (from the draft's IMG_3683 failure): a vision model reading several overlapping shelf photos in one context (a) silently skips most of a dense row when working from a downsized image and (b) pattern-completes from neighbouring photos (it listed *Darksiders* / *Alice* in a frame where they don't appear). The app's design already isolates each tile in its own `claude -p` call with full-resolution crops; the accuracy harness must measure **recall per row** and **false positives per photo** separately, not just overall precision.
- [ ] `VGN/Resources/platforms.json` — skim the 61 platforms: slugs are forever (DB primary keys), sidebar `group` assignments, anything you own that is missing.

### M1 — Library core (code merged 2026-09-18; tag `m1` follows the loose-ends merge)
The agents cannot drive the GUI, so the keyboard palette has only been exercised through its model tests. **Main runtime risk: the Quick Add `NSPanel` key handling on macOS 15.** With the real app and real credentials:
- [ ] Settings ▸ Accounts: enter the IGDB client id/secret → **Test connection** says it is connected.
- [ ] `⌘N` opens the palette; typing streams results (library instantly, IGDB ~200 ms later); `↑↓` select, `Tab`/`⇧Tab` cycle platform, `⌘O` owned, `⌘P` played, copy format via the footer picker (click), `⌘1`/`⌘2`/`⌘3`, or `⌘D` to cycle, `⌃S…⌃F` tier (`⌃0` clears), `↩` adds and stays open (field clears), `⇧↩` adds and keeps the list (for a series), `⌘↩` opens the inspector, `esc` clears then closes.
- [ ] Typing a year narrows a long series: "super mario bros 1985" → the NES original first; "super mario bros 1988" → 2 and 3.
- [ ] **50 games by keyboard in < 5 minutes**, the palette never waiting on the network.
- [ ] Covers appear in the grid within seconds; the sidebar footer shows "Fetching metadata · n left"; quit mid-fetch and relaunch → the queue resumes; relaunch is instant and covers persist.
- [ ] "metal gear solid legacy" offers **Add as compilation** and creates the member games; "bloodb" and "chevaliers de baphomet" both find their game (search fallback).
- [ ] Drop an image on a cell / the inspector cover → custom cover; **Refresh metadata** must not replace it.
- [ ] **Library grid one-key actions need ⇧.** Select game(s), then `⇧S ⇧A ⇧B ⇧C ⇧D ⇧F` set the tier, `0` (plain) clears it, `⇧O` toggles owned, `⇧P` toggles played, `⇧M` repeats the last "Mark Played As" value. Plain letters *always* type-to-select (typing "s" jumps to a title, never tiers; "ze" finds Zelda even with a selection). Caps Lock on must not tier — a Caps-Locked "S" still type-selects. ⇧K (a non-action letter) type-selects like a plain letter. Arrows / space / ⌘I / ⌫ / ↩ unchanged. Tier Board, Triage, Duel and Quick Add keep their own (unshifted) keys.
- [ ] **Mark Played As.** Select game(s) → context menu shows **"Mark as ‹Last›   ⇧M"** at the top (the shortcut is text, NOT a live key equivalent) and a **"Mark Played As"** submenu (Played · Playing · Finished · 100% · Abandoned) with a checkmark on the current "last" value; choosing one applies it AND becomes the new last value. The **Game** menu carries the same two commands (the repeat item shows "⇧M" as text, no key equivalent), enabled only with a selection in a grid view. Verify a banner ("12 games marked Finished", "3 already Finished — unchanged"), one Edit ▸ Undo step ("Undo Mark as Finished") restoring each game's prior played/status, and — crucial — that **`⇧M` fired in the grid marks the selection but a capital "M" typed in the search field or Quick Add types an "M"** (the menu shortcut must never steal it). In the Backlog list the marked games leave and the selection moves to the game now at the first vacated slot (no stale inspector).
- [ ] **Batch Mark Owned (ask once).** Select several games → context-menu "Mark Owned" (or `⇧O`) opens ONE "Mark N Games as Owned" sheet: a format picker for the whole batch (Physical · Digital · ROM; defaults to the last format you picked and remembers it), ambiguous games (several platforms) listed first each with their own platform popup, single-platform games collapsed under a disclosure, and an "N already owned — unchanged" note. "Mark Owned" (↩) writes every copy in one go; Cancel (esc) writes nothing. A single game keeps the old behaviour (multi-platform → the small picker; single-platform → immediate). Multi-selection ⇧O to *un-own* shows a banner ("un-own one game at a time") — by design: the owner decided on 2026-09-19 that bulk un-own will not be built.

### M4 — Ranking (tagged `m4` 2026-09-18)
Logic is exhaustively tested; the *feel* is not. With a few dozen played games:
- [ ] **Triage** (Duel ▸ Triage): `S…F` tiers the current game, `0`/`space` skips, `←` goes back. ~2 s per game?
- [ ] **Duel**: `←`/`→` pick, `↓` skip, `space` peek, `⌘Z` undo; "Placing X · 3 of ~6" reads right; quit mid-placement and relaunch → it resumes. Keys must not leak into the search field or re-tier the grid.
- [ ] Border duel card (promote/demote): `↩` accept, `esc` dismiss. Disputes chip lists cycles ("Settle" re-places the games involved — a precise "duel this pair" API is a follow-up).
- [ ] **Tier Board**: drag within a row, across rows, onto the dimmed unplaced tail; multi-select drag (a 5-game drop is currently 5 undo steps — batch move is a follow-up); `⌥←/→` nudge, `⌥↑/↓` change tier; insertion bar placement feels right?
- [ ] **The Top**: podium proportions, inline dividers; select a platform/decade in the library → Top shows derived *and* overall positions; drag reorder when unfiltered; `⌘E` CSV opens cleanly in Numbers/Excel.
- [ ] **Movable dividers**: drag the S/A line in The Top — is 44 pt per game a good feel? live "S 7 → 9 · A 14 → 12" preview, `esc` cancels, one `⌘Z` undoes; `⌥↑/↓` on a focused divider.
- [ ] **Derived scores** ("#4 · 9.6"): do the bands feel right? S 9.0–10 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9 (one constant file: `VGN/Ranking/DerivedScore.swift`).
- Console note "type com.videogamenerd.ranking-item is not declared" during drags is benign (fix = declare an exported type in Info.plist, milestone 9 polish).

### M5b — Play Next + Ask Claude, M6 — Photo scan (code merged 2026-09-19)
- [ ] **Play Next** (sidebar): `1–5` brackets, `R` re-roll, `↩` start playing, arrows between cards, `⌫` not this one, `space`/`⌘I` inspect. Do the picks and the *reason sentences* read naturally on your real library? (Needs ≥ 15 ranked games to be more than crowd-prior.)
- [ ] **Personal length / play style** (2026-09-19, wave 10 lane C): the BY LENGTH header popover (and Settings ▸ General) has a **"How do you play?"** picker — *Story first · Some side quests · Lots of side quests (default) · Completionist* — each with a one-line note and a live example ("A 30 h story / 90 h completionist game counts as 60 h for you"). Changing it re-bands the BY LENGTH shelves, the Length sort, the Playtime filter's unplayed fallback and Play Next's picks (a 30 h/90 h game sits in *A Few Weeks* at Story first, *A Season* at Lots of side quests). The **rushed** HLTB/IGDB time is never used for length — a game with only that is *Unmeasured*. The pace header button reads "8 h / week · lots of side quests" when it fits. In Play Next, reasons read "≈ 52 h for you" and the **Plan for 100%** toggle is forced on + disabled when the style is already Completionist.
- [ ] **Play Next time brackets = the BY LENGTH shelves** (2026-09-19, wave 10 lane C): the top control shows *One Evening · A Weekend · A Few Weeks · A Season · Epics · Custom…*, each covering the **same hours** as its sidebar shelf. The selected bracket's range shows as a caption ("A Few Weeks · 10–40 h at 8 h a week"). Changing the **weekly play pace** (BY LENGTH header popover / Settings ▸ General) shifts the bracket ranges and refreshes the picks. **Custom…**'s hours/week starts from your pace. Opening Play Next right after selecting a BY LENGTH sidebar shelf preselects the matching bracket. The "Ask Claude" prompt and the "fits …" reason name the bracket with its range.
- [ ] **Ask Claude**: the disclosure line, latency (~10 s), Cancel, the two-column Engine | Claude layout at narrow widths, the failure path when the CLI is logged out. First call in an hour costs ≈ $0.70 *notional* of subscription usage (the CLI's own system prompt gets cached; later calls are cheaper).
- [ ] **Scan Photos…** (File menu, `⇧⌘O`, or drop images on the window): progress rows per tile, the review sheet (photo pane zoom/pan, region highlight alignment on a full-size photo, include/played toggles, alternatives, "seen in 3 photos" collapse, greyed duplicates), one "Add n games" commit, summary.
- [ ] **Continuity Camera** "Take Photo" from the scan sheet — needs your iPhone nearby; cannot be tested any other way.
- [ ] Settings ▸ Photo Scan: detected `claude` path + version, **Check** button, model and parallelism settings persist.

## Hardening pass (wave 6, lane C) — needs owner eyes on the new UI hooks
- **Cover "Remove custom cover" re-fetch** — once the orchestrator wires
  `CoverStore.clearNegativeCache(gameID:)` into `AppEnvironment.onRemoveCover`, confirm
  that removing a custom cover set *before* metadata arrived re-fetches promptly.
- **File ▸ Export Library…** — once wired, confirm the JSON/CSV files open and look complete.
- **Restore from backup** — a destructive action; confirm the confirmation copy and that
  it restores at next launch. `AppDatabase.restore` never clobbers from a bad file, but the
  UI should still confirm and ideally snapshot first.

### Hardening (2026-09-19) — quick checks
- [ ] Activity Monitor: VGN idles at ~0 % CPU on every screen (it used to sit at 100 % — fixed; worth one glance with your real library and real covers).
- [ ] Right-click a game that is *not* selected → it becomes the selection when you pick an action (not merely on opening the menu); right-click inside a multi-selection → the action applies to all.
- [ ] File ▸ **Export Library as JSON… / CSV…** writes a file; open the CSV in Numbers.
- [ ] File ▸ **Restore from Backup…**: pick a snapshot → VGN quits → on reopening, the banner confirms the restore and a fresh pre-restore snapshot exists in Backups. (Try it once *before* you depend on it.)
- [ ] Inspector ▸ **Remove custom cover** re-fetches a cover right away.
- [ ] `scripts/snapshots.sh --generate` then open `.build/snapshots/index.html` — the fastest way to look at every screen.

### Choose Cover… sheet (wave 7, lane B) — needs owner eyes
- [ ] Inspector ▸ **Choose Cover…** (button next to Refresh metadata): opens a sheet that lists real box art from libretro (retro platforms) and IGDB. Check the grouping, the per-tile `provider · region · size` labels, and that thumbnails load without stutter.
- [ ] Pick a candidate → **Use This Cover** (or **double-click** a tile): the grid + inspector cover update immediately, and a subsequent **Refresh metadata** does *not* replace it (it's marked user-edited).
- [ ] **Choose File…** (or drag an image onto the inspector cover) sets a local image the same way.
- [ ] The **current** cover is shown for reference; **Cancel** (esc) and the empty state ("no covers found" → Choose File…) read correctly.
- [ ] Sample mode (`--args -VGNSampleData YES`): the sheet opens and offers **Choose File…** but lists no remote candidates (no network in sample mode). This is expected.
- [ ] After using the sheet, VGN still idles at ~0 % CPU (no render loop from the sheet).

### Choose Cover… grid entry + Play Next Undo (wave 7, lane B, feature 2) — needs owner eyes
- [ ] Right-click a single game in the grid → **Choose Cover…** appears and opens the same sheet as the inspector button. Right-click inside a multi-selection → the item is hidden (cover is per-game). Confirm no CPU spike when the context menu is built over a large grid.
- [ ] Play Next ▸ **Start playing** a suggestion → an inline "Started *Title* — **Undo**" toast appears. Clicking **Undo** puts the game back in the list with its old status; the toast fades after ~10 s or when you take another action / leave the screen.
- [ ] After Start playing, **Edit ▸ Undo "Start Playing"** (⌘Z) does the same. Undo is single-shot (a second ⌘Z does nothing).
- [ ] Start a suggestion, then **rank it** (open its inspector, set a tier), then Undo → it refuses ("Kept — you've ranked it since starting") and the tier is untouched.

### Library Stats window (wave 7, lane D) — needs owner eyes
- [ ] Open it three ways and confirm each works: **Window ▸ Library Stats**, the shortcut **⌥⌘S**, and **"Show All Stats…"** at the bottom of the sidebar stats popover (the popover should dismiss and the window come forward). Re-opening focuses the single window, not a second one.
- [ ] The dashboard reads well in **light and dark**: overview, playtime (total, by platform/decade/tier, most played, me vs. average, backlog to beat), platforms grouped by manufacturer with owned/played, decades & years, tiers (tier colours), scores, genres, status/completion, and the 12-month activity chart. Charts are legible; no clipped labels or white-on-white.
- [ ] The **All · Owned · Played** scope picker updates every section; switching scope is instant and does not flicker.
- [ ] Add/rank/mark-played a game in the main window while the stats window is open → the stats **reload automatically** within a moment.
- [ ] Empty state: launch with `--args -VGNSampleData YES` on a fresh DB (or pick a scope with no games) and confirm the "Add some games first" / "Nothing <scope>" message, not a blank grid.
- [ ] With the stats window open and idle, VGN still sits at ~0 % CPU (no render loop). *(Verified headless: sample launch idles at 0.0 %; the window itself must be opened by a human to confirm the open state idles — agents cannot drive it.)*
- [ ] Clicking a bar does nothing yet (by design, v1 — see `docs/LIMITATIONS.md`).

### Filters & tier tooltips (2026-09-19, wave 7 lane C)
- [ ] Toolbar **Tier ▸ "Unrated"**, **Status ▸ "Played, No Status" / "Not Played"**, **Format ▸ "Not Owned"**: each finds the right games, OR-combines with the real values (e.g. S + Unrated), shows a removable chip, fills the menu icon, and clears with the menu's Clear / "Clear all". The Status menu lists the real statuses, a divider, then **"Played, No Status"** (played but no completion status — how you find games to "Mark Played As") and **"Not Played"** — two genuinely different sets.
- [ ] Toolbar **Playtime ▾** bands *(2026-09-19: gained a "< 4 h" band)*: < 4 h · 4–10 h · 10–40 h · 40–60 h · 60–80 h · 80–100 h · 100–150 h · 150–200 h · > 200 h, over the effective playtime (manual over PSN) falling back to the best IGDB estimate (main → rushed → completionist) when unplayed; plus **"No Estimate"** (below a divider) for games with no time info at all. Bands OR-combine within the facet, AND across facets, each shows a removable chip, fill the menu icon, and clear with the menu's Clear / "Clear all". Spot-check that a game whose estimate is 3 h lands in "< 4 h" and a 5 h game in "4–10 h", and that a game with only an IGDB *hastily* or *completely* estimate still appears in a band and not under "No Estimate".

### "Multiple Copies" filter (2026-09-19, wave 9 lane C; folded into Format menu wave 10 lane C)
- [ ] Toolbar **Format ▾ ▸ "Multiple Copies"** (below "Not Owned") narrows the grid to games you own in **more than one** copy or format (≥ 2 owned products — e.g. physical + digital). It is its own facet that **ANDs** with a chosen format ("Physical" + "Multiple Copies" = a game that has a physical copy and is owned several times). It shows a removable **"Multiple Copies"** chip, fills the Format menu icon, ANDs with the other facets and the scope, and clears via the Format menu's Clear / "Clear all". A game owned once (or only played) does not appear.

### BY LENGTH shelves + weekly play pace (2026-09-19, wave 9 lane C) — needs owner eyes
- [ ] The sidebar has a **BY LENGTH** section after RANKINGS, before PLATFORMS: five rows **One Evening · A Weekend · A Few Weeks · A Season · Epics**, each a symbol + literary name + the hour range as caption + a live count. Selecting one scopes the grid to games whose **time-to-beat estimate** falls in that range; the window title is the literary name; search and every filter still work inside it. Empty shelves stay visible but **dimmed**; the **Unmeasured** row appears **only** when it has games and is a sensible place to fetch missing estimates.
- [ ] A game is shelved by **how long the game is** (its estimate), **not** how long *you* played it: a long RPG you dropped after 2 h shows under One Evening / A Weekend, not Epics. Hover a row: the tooltip explains the shelf and names the estimate.
- [ ] The **BY LENGTH** header shows the current pace ("8 h / week", or "Set your pace…" the first time). Clicking it opens a popover — "How much can you play in a typical week?" — with a slider (1–40, stepper to 60), a **live preview** of the five ranges that updates as you drag, and **Reset to 8 h**. Committing changes the shelf ranges everywhere (e.g. at 2 h/week "A Few Weeks" becomes 10 h) and re-runs the grid/counts without a stutter; the same control lives in **Settings ▸ General ▸ Weekly play time** and both stay in sync. Does the range vocabulary and the pace feel right? (Names are placeholders — easy to tweak; every string comes from one table.)
- [ ] **Tier badge hover** shows the tier label everywhere a tier is drawn: the **grid cell badge** (also shows the derived score, e.g. "S — Masterpiece · 9.4"; an unplaced game shows "~8.5"), the **inspector** tier picker (the current tier's chip shows the score), the **Tier Board** row headers, **The Top** rows (with score) and dividers, **Triage** and **Duel** empty-state tiers, the **border-suggestion** card, and the sidebar **stats popover** per-tier letters. The **legend** keeps its "(press S)" text; the **Duel** side badge shows the label from the environment.

### The Top — insertion line while reordering (2026-09-19, wave 7 lane F)
- [ ] Drag a game in **The Top** (unfiltered): a 2 pt accent insertion line with a small leading knob appears in the gap where it would land — **above** the hovered row when the pointer is in its upper half, **below** in the lower half; exactly one line at a time; it vanishes on drop, on leaving the list, and on `esc` / dropping outside. Does the half-row boundary feel right? (Only a human drag can confirm the `DropInfo.location` coordinate assumption.)
- [ ] The game **lands exactly where the line showed** (same up/down-half rule), and dropping a game directly above or below itself shows **no line and does nothing**.
- [ ] Dragging **across a divider** changes the tier as before; near a divider the line distinguishes **last of the upper tier** (above the divider) from **first of the lower tier** (below it), and when the destination tier differs from the source it takes the **destination tier's colour + letter** in the knob (check light *and* dark).
- [ ] With a **filter active** no drag/line/divider-move happens (unchanged). Note the residual: **no auto-scroll** near the top/bottom edge while dragging (drag to a visible row, or scroll first).

### GOG import UI (2026-09-19, wave 8 lane B) — needs owner eyes, runs against real GOG
> These require the **live build with the owner present** (`docs/gog-import.md` runbook, PLAN §14.5). They cannot be checked in `-VGNSampleData` mode (sign-in is disabled there). Do them as part of the gated live steps G1–G7.
- [ ] **Sign in** (Settings ▸ Accounts ▸ GOG ▸ *Sign In to GOG…*): the private window shows GOG's own login page, the read-only address line shows only the host, and on success the window closes itself and the pane shows the owner's **username** (never the user id). The owner's password never leaves GOG's page.
- [ ] The login window **blocks off-allow-list hosts** with a "Blocked a page from …" note and opens nothing externally. If a captcha host is blocked, that is the expected stop-and-ask (add the host, retry).
- [ ] **Sync Now** shows the small progress sheet (with Cancel) then opens the review sheet. The header reads "n from cache · m from network" and any owned-gap note; the **Mac when available / Always PC** switch re-maps rows; the three buckets (*New / Already matched / Ignored*) look right; DLC/soundtrack/demo land in **Ignored** with a reason and restore in one click; **Linux-only → PC** chip shows where expected.
- [ ] **Import N Games** commits once; the banner reads "N games imported from GOG · M already in your library"; the games appear **owned, not played** (Backlog), no tier touched. A second **Sync Now** makes **0** requests and proposes nothing new.
- [ ] **Force Refresh…** on a data set states the request cost and the cached age before confirming; after a new purchase, forcing the **Library** set re-fetches only the pages and only the new title appears.
- [ ] Each **reject** path (sign out mid-sync, a 403/HTML, etc.) surfaces a clear message in the GOG pane with "VGN stopped and made no further requests." and a redacted excerpt disclosure; the last good cache survives.
- [ ] **Sign Out…** removes the tokens (pane returns to signed-out); with the **"Also delete cached GOG responses"** tick, the cache is wiped too.
- [ ] File ▸ **Import from GOG…** starts a sync when signed in, and opens Settings ▸ Accounts when signed out.
- [ ] With the app idle after a sync, VGN still sits at ~0 % CPU (sample-mode idle already verified headless).

## HowLongToBeat fallback (wave 9, PLAN §5.3) — live only
The request shape was **verified live 2026-09-19** (wave 10, lane B) and the fixtures are recorded from real searches; the checks below still need the **real site** through the app (live mode) because the unit suite runs offline.
- [x] Port verified against the live endpoint 2026-09-19: `scripts/record-hltb-fixtures.swift` discovered `api/search/site`, fetched a per-session token, and recorded Bloodborne / Celeste / Final Fantasy VII / Wind Waker + a miss (9 requests). To re-verify after a future rotation, re-run it (≤ 25 requests, ≥ 2 s apart); **if it STOPS** (HTML/captcha/403/non-JSON/shape) the endpoint or token scheme has rotated — fix `HLTBEndpoint.swift` per `docs/hltb.md`, then re-run.
- [ ] Inspector ▸ a game with a missing time shows **Fetch from HowLongToBeat**. A clear match fills the three rows and shows a banner; **⌘Z undoes** it. The source line reads **HowLongToBeat**; "Open on HowLongToBeat" now goes to the **exact game page**.
- [ ] A title with two same-name games (different years) opens the **picker sheet** (name, year, platforms, the three times, "Open page"); picking one fills it.
- [ ] Game ▸ **Fetch Missing Time Estimates…** with nothing selected runs over every game with no estimate: progress "n of m" + current title + **Cancel**, then the summary "n filled · m not found · k ambiguous"; ambiguous games list for a one-by-one pick. With a selection, it scopes to that.
- [ ] Re-running the bulk fetch makes **no requests** for anything already cached (180 d for a hit, 30 d for a miss) — only still-missing, not-negatively-cached games are queried.
- [ ] A forced stop (kill the network mid-run, or a captcha) ends the run with a clear message and **"VGN stopped and made no further requests."**
- [ ] In `-VGNSampleData` mode the button + sheet still work but make **no network calls** (every game resolves "not found") — the inert search.
- [ ] Inspector footer shows **"Added <date> · via <origin>"**; the CSV/JSON export carries `origin` (and each copy's `source` / `external_id`).

## PSN import (§13) — S0 built offline; live steps S1–S8 are gated (owner + orchestrator)
S0 (scaffolding) is done and unit-tested on synthetic fixtures — **no PSN request has been
made**. The runbook, the exact tiny probe per step, and the stop-and-ask rules are in
`docs/psn-import.md`. The checks below are **live** and run one probe at a time, test account
first, then the real account; **stop and report on anything unexpected** before continuing.
- [ ] **S1 sign-in (test account):** the owner logs in on Sony's page in the WKWebView; VGN reads
  the `npsso` cookie (or pasted NPSSO), exchanges it for tokens, stores only tokens in the
  Keychain (`psn.tokens`). The NPSSO/code/tokens appear in **no** log, fixture, dev-cache index or
  error. Confirm which account was used.
- [ ] **S2 profile:** shows the test online id. **S3a** trophy probe (`trophy2`, `limit=10`) returns
  ≤10 titles + a `totalItemCount` (empty is valid for a fresh account); **S3b** full page is
  coherent. **S4** `npServiceName=trophy` returns PS3/Vita titles.
- [ ] **S5 game list** returns ISO-8601 `playDuration`s that parse to sensible hours. **S6 purchases**
  (GraphQL, test account first) returns entitlements incl. `membership` (test's free games → `NONE`);
  if the persisted-query hash has moved, read the current one from `library.playstation.com`'s
  network tab (stop-and-ask, not a retry).
- [ ] **S5b real account:** re-probe each data set with ONE tiny request before its full fetch;
  first sight of `PS_PLUS`. **S7** full sync imports through the review sheet in ≤ 20 requests; **S8**
  an immediate second sync makes **0** requests and proposes nothing new.
- [ ] A game owned **only** through PS Plus shows the yellow-circle "+" badge and appears under
  Format ▸ **PS Plus**; a game also on disc shows no badge. A lapsed Plus claim is **proposed** for
  removal in the review sheet, never removed silently.
- [ ] Every reject path (login page, error envelope, rate limit, schema mismatch) shows a clear
  message, leaves the last good cache intact, and stops. Sign out removes the tokens; the dev cache
  (`~/Library/Application Support/VGN/dev-import-cache/`) is deleted at milestone end.

## Delicious Library import (§5.5)
- [ ] File ▸ **Import from Delicious Library…** → pick the `.deliciouslibrary2` file **or** the "Delicious Library 2" folder that contains it. It reads (no network) and opens the review sheet titled **Import from Delicious Library** with "103 games read from Delicious Library".
- [ ] The **platform policy** switch (Mac when available / Always PC) is shown and only re-maps the PC/Mac hybrid discs; console games (PS3, Wii, GameCube…) keep their platform. Each row's platform popup offers **every** VGN platform.
- [ ] Matched rows show the IGDB title with the original noisy title underneath ("Delicious Library: …"); an extracted **edition** chip appears (e.g. *Special Edition*, *Collector's Edition*). French titles like *Cérébrale Académie* match via alt-names.
- [ ] A game already on your shelf as the **same physical copy on the same platform** appears under *Already matched* / "Already on your shelf", unticked; committing never adds a second copy. Re-running the import adds nothing.
- [ ] With **Use my Delicious Library covers…** ticked (default), games imported without a cover show the owner's own box art after commit; a later, better enrichment cover is still allowed to replace it.
- [ ] Import works the same in `-VGNSampleData YES` mode (no account, no network except IGDB matching — which is inert there).
- [ ] Confirm the real file's bytes are untouched after an import (it is opened read-only).

## Reconciling unlinked games (§5.1, wave 11) [owner]
- [ ] The sidebar shows an **Unlinked** row (under LIBRARY) only when you have games with no IGDB link; its count matches the real library (the owner has ~8: *Cérébrale Académie*, *Dragon Quest IV : L'épopée des Elus*, *Evolution Worlds - GameCube - US*, *The Nomad Soul*, *Myst V: End of Ages Limited Edition*, *Obduction ®*, *The Bard's Tale IV: Barrows Deep*, *Uru: Complete Chronicles*). Selecting it lists exactly those games. It disappears once all are linked.
- [ ] An unlinked game's inspector shows the "Not linked to IGDB" notice and a **Link to IGDB…** button; a linked game shows **Change IGDB Match…** instead. The grid context menu and File menu offer the same.
- [ ] **Link…** opens a search prefilled with a cleaned title; typing the English name (e.g. "Big Brain Academy") finds the game. The "Only <platform>" toggle narrows / widens results. Choosing it fills metadata, cover and time estimates within a few seconds, and the game leaves the Unlinked list (selection moves to the next row). Search still finds the old title (e.g. "Cérébrale Académie").
- [ ] Linking a game whose IGDB entry you **already own** (a duplicate) shows the merge sheet spelling out what moves; confirming leaves one game with both platforms' copies, and Undo restores both games exactly. Re-running a Delicious import proposes no second copy of it.
- [ ] **Change IGDB Match…** on a wrongly-matched game (weird edition) replaces the entry and refreshes metadata; a genre/year from the wrong match does not linger.
- [ ] In the import review sheet, a ticked row with no IGDB match shows a quiet "will import unlinked" warning; **Find…** opens the search and, on choose, attaches the match to that row.

## PSN import UI (§13, wave 11) [owner — most items are LIVE steps, run with the orchestrator]
Read `docs/psn-import.md` first. As of wave 12 the **build-steps panel** exists (see the wave-12 section below) — prefer it for S1–S8; the ordinary Sync Now flow is DEBUG-gated behind it.
- [ ] **Settings ▸ PlayStation** signed-out shows *Sign In to PlayStation…*, a *Paste NPSSO instead* disclosure, and the three-line risk note. The NPSSO is never shown back to you and the field clears after use; an implausible paste is rejected without echoing what you typed.
- [ ] **Sign in (S1).** The login sheet loads Sony's page in a private window, the address line shows only the host, and off-Sony pages are blocked. After you log in it reads the `npsso` cookie and signs in; the tab now shows your **online id** (never the account id), the session-renewal date, and per-data-set cache ages. (If the cookie can't be read, *Paste NPSSO instead* works.)
- [ ] **Probes then full fetches (S2–S6), test account.** Sync Now fetches profile → trophy titles → game list → purchases, each probed first. A test account with a few free games and **no PS Plus** produces a coherent review; the free games appear as owned digital, none as PS Plus.
- [ ] **Stop-and-ask is real.** If any response is off (login page, error envelope, schema mismatch, rate limit, the `getPurchasedGameList` hash moved…), the sync **stops**, shows "VGN stopped and made no further requests." with the reject reason and a redacted excerpt, and makes no further requests. Nothing is committed.
- [ ] **Real account (S5b–S8).** One tiny probe per data set before each full fetch; the first real PS Plus title shows the yellow **+** badge in the grid and "PS Plus — expires with the subscription" in the inspector. A second Sync inside the cache window makes **zero** requests.
- [ ] **Review & commit.** Committing imports the games (owned digital for purchases, played for trophy titles with their last-played date and 100 % status where earned) and shows a banner; re-committing adds nothing new. Decisions persist across syncs.
- [ ] **PS Plus facet.** Format ▸ **PS Plus** shows only games you own solely through PS Plus; with Status ▸ Not Played it is the "finish before unsubscribing" list. A removable *PS Plus* chip appears.
- [ ] **Change Copy Format.** Selecting several games and Game ▸ **Change Copy Format ▸ Physical** reclassifies each single-copy game and reports "N changed · M skipped (several copies)"; Undo reverts them in one step. A PS Plus copy is never changed.
- [ ] **Last played.** A played PSN game shows "Last played <date>" in the inspector; sorting by **Last Played** orders by it (never-played-by-an-importer games last). CSV/JSON export carry the dates.
- [ ] **Force Refresh / Sign Out.** Force Refresh on one data set states the request cost + cached age before spending anything; Sign Out (optionally deleting cached responses) returns to the signed-out pane.

## Batocera ROM catalogue (§15, phase 1 — lane B, wave 12)
Phase 1 has no UI, so these are checks the phase-2 lane and the owner make once the browser /
review / Settings exist. What phase 1 can be eyeballed today is the **dry-run** in the hand-off.
- [ ] **Sync reads the real share.** With `/Volumes/share` mounted, a sync reports ~35 systems
  read, the arcade/port systems (mame, fbneo, daphne, prboom, steam…) skipped, **0 unknown**, and
  ~10 900 catalogue entries — and re-running with no file change reads **0** systems (unchanged).
- [ ] **The catalogue never leaks into the library.** After a sync, All / Owned / Backlog / stats /
  ranking / grid counts and CSV/JSON export are **unchanged** — the ~10 900 ROMs are invisible until
  promoted.
- [ ] **Promotion is the played/favourite set.** The promotion review offers ~290 candidates (the
  games with > 5 min or a favourite star), not the whole shelf; a 5-minute launch that never crossed
  300 s does not appear.
- [ ] **Duplicate rule.** A candidate whose IGDB match already owns a hand-entered ROM copy on the
  same platform commits **no second copy** — it just gains the Batocera play time / last-played date
  and links to the catalogue row ("Already in your library").
- [ ] **Play time coexistence.** Confirm the eventual `imported_playtime_s` decision (see LIMITATIONS
  5d): a game with both a PSN time and a Batocera time should show both once the neutral column lands.
- [ ] **Play Next ▸ Discover** surfaces never-played catalogue games scored by taste, rotates weekly,
  and "Not interested" retires a title for good.

## Batocera ROM catalogue UI (§15, phase 2 — lane A, wave 13) [owner — live, run once]
The UI is built; these need the owner + a mounted share (agents can't drive windows or read the
owner's `/Volumes`). See `docs/batocera-import.md` for the first-run walkthrough.
- [ ] **Settings ▸ Batocera.** Choose the share folder (`/Volumes/share` suggested); the status
  shows *Mounted*, systems + catalogue size + candidates waiting. **Sync Now** shows progress and a
  cancel; a second run reads 0 systems (unchanged). The **skip list** is editable (remove one and it
  gets read next sync; `mame*`/`cps*` stay skipped). Unmounting the share → *Not mounted*, and a sync
  reports "Batocera share not mounted" quietly.
- [ ] **Auto-sync + review banner.** With auto-sync on and the share mounted, launching VGN runs the
  sync in the background (no launch delay). With *"Add my favourites automatically"* **off** it shows
  **"N Batocera games ready to review"** with **Review…** and adds nothing on its own; with it **on**
  (default) the confident favourites are added (see below) and only the rest wait for review.
- [ ] **Auto-add my favourites (§15, wave 13).** With *"Add my favourites automatically"* on and IGDB
  configured, a sync adds your ★ favourites that get a confident match. First sync over ~247
  favourites shows **"60 added · 187 still to match"** (the 60-per-run cap) — and adds no more than 60
  in that pass; relaunch/Sync Now adds the next batch, and **no favourite is matched twice**. The
  banner's **Undo** removes exactly what that batch added (and un-links the catalogue rows). Ambiguous
  or unmatched favourites (and anything played > 5 min) still appear only in *Review…*. A favourite
  whose IGDB match is a game you already own on that platform gets play time only, no second copy.
  Un-favouriting on the box then re-syncing never removes a game from the library.
- [ ] **Favourite in the picks + Discover.** An unplayed favourite you own shows **"★ a favourite on
  your Batocera"** in Play Next's regular picks (and is nudged up among near-ties). A never-played
  favourite still only in the catalogue is **pinned at the top** of *Discover on your Batocera* with
  **"★ your favourite"**, but never more than half the row.
- [ ] **Promotion review.** *Review…* opens *Import from Batocera*: the ~290 candidates match to IGDB
  (a progress sheet with a cancel; a couple of minutes the first time), each row shows the play-time
  line and, where you already own the ROM, "Already in your library — adds play time only".
  Untick/Find…/Ignore work; **Import** creates ROM copies with the box's play data and links the
  catalogue rows. Reopening does not re-query matched rows.
- [ ] **Sidebar ▸ Batocera ▸ ROM Catalogue.** The section appears only when the catalogue is
  non-empty. Browse per system, search (instant), sort, filter chips; thumbnails load from the share
  (placeholder when unmounted); **In Library** marks promoted games; **Add to Library… / Not
  Interested / Show in Finder** work. The library's All/Owned/Backlog/stats/ranking counts are
  **unchanged** with the catalogue present.
- [ ] **Play Next ▸ Discover on your Batocera.** A row below the picks with 5–8 never-played ROMs
  scored by your taste (reasons like "Part of *Zelda*, like *A Link to the Past* (S)"); **Shuffle**
  re-rolls within the week; **Not Interested** retires a title; **Show in Catalogue** jumps to it.
  Hidden when you have no rankings.
- [ ] **Idle CPU.** With the ROM Catalogue open (and after a sync), the app idles at ~0 % CPU (no
  polling of the mount).

## PSN build-steps panel + review groups + Play Next (§13, wave 12) [owner]
The DEBUG build-steps panel, the richer review groups, and the Play Next PS Plus option landed in wave 12. Read `docs/psn-import.md`'s "panel runbook".
- [ ] **The safety latch is a visible switch (all builds).** With sync off, Settings ▸ PlayStation reads "PlayStation sync is off" + the risk note + **Enable PlayStation sync (unofficial API)…**; enabling confirms, then says **"Relaunch VGN to apply"** (nothing hot-swaps). File ▸ **Import from PlayStation…** is disabled ("Enable it in Settings ▸ PlayStation") while off. Once on, a **Turn off…** action clears it (tokens survive until Sign Out).
- [ ] **The build-steps panel (DEBUG live).** **PSN build steps…** opens the panel: the **test/real** picker (a red **REAL ACCOUNT** marker on `real`), the S2–S6 steps in order, each **disabled until its prerequisite passed** for the current label, **one running at a time**, a full fetch asking "up to N — continue?" (and a **second** confirm on `real`), and a live **requests this session: k / 40**. Each result row shows status, item count, cache-vs-network, bytes, and a **dev-cache path you can click to reveal in Finder**.
- [ ] **The reject lock.** Force an odd response (or watch one happen): every button disables and the panel shows **"VGN stopped and made no further requests."** with a redacted excerpt. **Acknowledge** re-enables only steps whose prerequisites still hold; the failed step needs an explicit **Try this step again**. **Copy report** pastes a redacted summary (no token / NPSSO / account id). **Wipe dev cache (this account)** clears just that label's bodies.
- [ ] **DEBUG Sync gate.** Before the panel has passed every probe + full fetch for a label, **Sync Now** / File ▸ Import refuse with "Run the PSN build steps first". After they pass, the ordinary cache-first sync runs (and a second one inside the window makes **zero** requests).
- [ ] **PSN review groups.** After a sync the sheet groups rows: **Played**, **Launched, 0 %** (unticked), **Played — no purchase found** (with **Own the ticked rows as ▸ Physical / Digital**), **Purchased**, **PS Plus** (blue +, "expires with the subscription"), **Already in your library** (each row states "+ played" / "+ N h" / "+ last played YYYY"), **Ignored**. Banner reads "N imported · M updated".
- [ ] **Proposed removals.** After a PS Plus claim disappears from a later sync, a **Proposed removals** section lists it (unticked); ticking + confirming removes only those copies (a game you played survives as *played, not owned*).
- [ ] **Play Next ▸ Prefer expiring PS Plus games.** Off by default; a game owned only via PS Plus shows a **"Leaves with PS Plus"** reason. Turning the option on nudges such games up among near-ties but never over a clearly better fit.
- [ ] **The Vault ▸ PS Plus (wave 14, PLAN §16).** After a real PSN sync, the sidebar shows a **THE VAULT** section with a **PS Plus** row (count = barely-touched claims), separate from the library counts; the row opens the Vault browser scoped to PS Plus. A `PS_PLUS` claim played ≤ 10 min (incl. never launched) is in the Vault, not the review sheet; a bought (`NONE`) game never is; a claim played > 10 min imports as the "+" copy. Cross-gen twins are one entry. Watch the counts and names on the real 581-entitlement account. *(Note: the IGDB trait pass, the PS-Plus browser row, the "From the vault" Play Next row, and the Settings deadline picker are not wired yet — see `docs/LIMITATIONS.md §5b`.)*
- [ ] **PS Plus deadline ramp (partial).** Engine + scorer apply the ramp when a date is passed, but the Settings *"I plan to leave PS Plus around…"* picker is not built yet, so there is nothing to set in the UI this wave.

## The Vault ▸ PS Plus — wave 15 (UI wired, PLAN §16) [owner]
After a real PSN sync (needs IGDB configured for matching), check on the real account:
- [ ] **Trait matching + status line.** Settings ▸ PlayStation shows **"Vault: N of M matched · next batch at the next sync"**; it climbs after each sync and at launch. **Match more now** runs one more capped (60) batch. Watch the ™-stripped names match sensibly and that no entry is re-queried once matched or marked no-match. Rough cost: ≈ 62 IGDB requests per 60-entry batch.
- [ ] **PS Plus browser row.** The Vault ▸ PS Plus browser shows the remote cover (loaded live, never saved to `covers/`), the title, a platform pill, the blue **+** on yellow marker, any "PS4 & PS5 versions" note, and — once matched — the IGDB year / genre / rating. Unmatched rows read "not matched yet" / "no IGDB match". **Add to Library…** adds an owned-via-subscription copy and the row flips to **In Library**; **Find match…** opens the search sheet and, on picking a game, fills its traits; **Not Interested** removes it. There is **no** "Open in PlayStation Store" (not derivable).
- [ ] **Deadline picker → both scorers.** Settings ▸ PlayStation ▸ *"I plan to leave PS Plus around [month] [year]"* — with a future date, Play Next's regular picks and **"From the vault"** both lead with PS Plus games showing **"leaves with PS Plus · ~N months left · about H h for you"**, more strongly as the date nears and only for games that still fit; a past date shows a gentle hint; **Clear** removes every effect. The Play Next option now reads **"Prioritise PS Plus games"** (on by default).
- [ ] **Review sheet.** A PSN sync's barely-played claims appear in a collapsed, read-only **"In the Vault (N)"** group (not under *Ignored*) with **Show in the Vault**; the pc/mac platform switch is gone from the PSN (and Batocera) sheet; each PSN group header reads **"ticked / total"**. A claim that later crosses the 10-minute gate imports as the "+" copy and its Vault row flips to **In Library**.
- [ ] **Matching progress.** During a big first sync the progress sheet shows a determinate bar, **"Matching 137 of 412 · <title>"** and, after ~10 titles, **"about N min left"**; **Cancel** stops promptly. *(Cancelling then re-syncing currently re-matches unmatched rows — resume is not persisted, see LIMITATIONS §5b.)*

## Bundle expansion — import + reconcile (§5.1, wave 15) [owner]
Fixes the 2026-09-20 reports: bundles imported as single games, and the reconcile sheet refusing a bundle. All undoable (⌘Z).
- [ ] **Repair the four existing bundles.** For each of *God of War Collection* (ps3), *The Tomb Raider Trilogy* (ps3), *Metroid Prime: Trilogy* (wii) and *The Bard's Tale Trilogy* (mac/GOG): select the game, then **Expand Bundle into Games…** (inspector, or File menu). Confirm the member list looks right and press **Expand into N Games**. The single becomes a compilation whose members are the individual games; if the game carried a tier/rank/playtime, the confirm step's *"Your play data stays on:"* picker moves it to the member you choose (default the first). Verify each member appears individually, the compilation copy shows all members, and no game was duplicated. **⌘Z** should fully restore the original single.
- [ ] **Link *Evolution Worlds* (GameCube) as a bundle.** Open its inspector, **Link to IGDB…**, search — the only right result is the **Bundle** entry. It is now selectable (subtitle "Bundle — links as a compilation"); choosing it fetches the members and shows the confirm sheet ("Expand into N Games"). Confirm; *Evolution Worlds* becomes a compilation of its member games.
- [ ] **Fresh Delicious / GOG import expands bundles.** Re-run a Delicious (or GOG) import that contains a bundle: the review row reads "Bundle · N games — imports as a compilation" and committing creates one compilation Product with the member games (existing members linked, not duplicated). A bundle IGDB has no member list for falls back to a single (row still imports). A second import of the same item adds nothing.
- [ ] **Not-a-bundle is a clean no-op.** "Expand Bundle into Games…" on an ordinary linked game (e.g. *The Dark Pictures Anthology: House of Ashes*, a single game on IGDB) shows "That's not a bundle on IGDB — nothing to expand." and changes nothing. *(wave 16)* Doing this from the Bundles-to-Expand list also **removes it from the list for good** (a persisted "not a bundle" dismissal).

## Send to the Vault + resume after cancel (§16 / §5.1, wave 16) [owner]
- [ ] **Send a review row to the Vault.** In any import review sheet (GOG / Delicious / PlayStation), a row's **⋯ ▸ Send to the Vault** (and the header **Send N to the Vault** group action) moves it out of the importable buckets into a collapsed **In the Vault (N)** group. **Show in the Vault** jumps to that source's Vault browser; the row's **Bring back** returns it to its bucket. An in-sheet **Undo** reverses the last send. Re-run the same sync: a vaulted row does **not** come back.
- [ ] **Owned vs subscription.** A GOG / Delicious game (or a bought PSN copy) sent to the Vault is remembered as **owned** (it shows an "Owned" marker in the browser, gets no PS Plus deadline boost). A **PS Plus claim** sent by hand keeps its subscription (the "+" marker) and still gets the deadline boost.
- [ ] **GOG / Delicious Vault rows.** After sending some, the sidebar **THE VAULT** section shows **GOG** and/or **Delicious** rows (only when count > 0); each opens its own Vault browser, and the games appear in Play Next ▸ **From the vault** once you have rankings.
- [ ] **Resume a cancelled sync.** Start a big sync, **Cancel** partway. Re-sync: the progress reads **"Matching K of N · … · M already matched"** — only the not-yet-attempted titles are re-queried; the ones matched before keep their proposals and alternatives. A title IGDB found no match for is retried after 30 days (or immediately after a Re-match). *(There is no per-row "Re-match" button in the sheet yet — the store seam exists; see LIMITATIONS §5b.)*
- [ ] **Bundles to Expand list — placement.** The list model + view exist and are unit-tested, but are **not yet mounted** in the app shell (where they sit next to the Unlinked list is a shell decision). Nothing to eyeball until a UI lane mounts `BundlesToExpandView`.

## Covers, compilation order, stats & sample-mode prefs (wave 17, lane A) [owner]
- [ ] **IGDB artworks in Choose Cover…** For a modern game with key art (e.g. a PS5 title), open the inspector's **Choose Cover…** sheet (live mode). The IGDB section now shows the cover **and** several artworks, each labelled kind · size ("artwork · 1920×1080"). A landscape artwork previews cropped the way the grid crops it (so a wide image doesn't look different once chosen). Picking one files it as the cover. In sample mode the sheet lists no remote candidates (network-free) — only "Choose File…".
- [ ] **A Delicious cover gets upgraded.** After a Delicious import where a game got its box art from the Delicious store, once enrichment runs (live, credentials set) the cover should be **replaced by the IGDB/libretro cover** when one exists — you shouldn't have to use "Choose Cover…" for it. A game the providers can't cover keeps the Delicious box art (no flicker/refetch loop). A cover you picked by hand is never changed. *(Existing libraries were backfilled at first launch on this build — Delicious-origin covers that never went through a cover fetch become provisional and get one attempt.)*
- [ ] **Compilation member order.** Add a compilation from an IGDB bundle (Quick Add a bundle, or a photo-scan / import-review bundle). Its members should be listed **oldest-first by release date**, not IGDB's order (e.g. *Mass Effect 1 · 2 · 3*). A compilation you hand-ordered earlier in the editor keeps its order.
- [ ] **Stats "Backlog to beat".** Open Library Stats (⌥⌘S). The **Backlog to beat** figure reads "≈ H h" with "At your play style" and a basis line "N games, M without an estimate". Change your play style (BY LENGTH header popover or Settings ▸ General) and the figure updates while the window is open. "Me vs. average" still uses the plain advertised IGDB time.
- [ ] **Sample mode leaves your real prefs alone.** Launch with `-VGNSampleData YES`, change the play pace / play style, then quit and launch the real app — your real pace/style/sort/PS-Plus-deadline should be unchanged.

## Known issues / watch list
- ~~**Title normaliser over-strips budget labels**~~ **Fixed (wave 6, lane C):** budget-line
  labels strip only at `.core` now; *Pokémon Platinum* survives at the fuzzy-matching level.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

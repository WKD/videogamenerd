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

## Suspicious estimates (wave 18, lane B — PLAN §5.3) — filter offline, refresh is live-only
The rule, filter, dismissals and personal-length fallback are exercised offline by the unit suite; the **refresh** touches the real site, so run it in live mode.
- [ ] Toolbar **Playtime ▾ ▸ Suspicious Estimate** (below the divider, next to *No Estimate*) shows the reviewable list — on the owner's real library expect roughly **30–40 games**, including **LittleBigPlanet** (54 h main → 1 000 h completionist) and **Resident Evil 6**. It composes with every other facet (e.g. + a platform), shows a removable chip, fills the menu icon and clears with the menu's Clear / "Clear all".
- [ ] Inspector on a flagged game shows a small **⚠︎ "Suspicious estimate"** next to the estimates table; hovering it shows the reason ("Completionist (1 000 h) is more than 4× the main story (54 h)"). The raw stored times are still shown.
- [ ] Filter to Suspicious Estimate, select a handful (or select-all), then **Game ▸ / right-click ▸ Refresh Time Estimates from HowLongToBeat…**: a confirmation states the count and that values will be **replaced**; running it overwrites the three times where HLTB has the game, the game leaves the filter, and **⌘Z** undoes the whole batch in one step. A game HLTB doesn't know **stays flagged**.
- [ ] On a game whose estimate is actually fine, the inspector's **Estimate Looks Right** dismisses it (⚠︎ gone, leaves the filter); the same place then offers **Flag again**, which restores it. The dismissal sticks across relaunches.
- [ ] A flagged completionist no longer inflates planning: a BY LENGTH shelf / Play Next pick for such a game reads a shorter "≈ … for you" (main × 1.5) until it is refreshed or dismissed; dismissing restores the raw completionist length.

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
- [ ] **"Played — no purchase found" own-as control** *(three-segment, wave 18 lane C — the owner's
  "clicking Digital does not make Digital the default" fix)*: the segment reads **`Not owned | Physical
  | Digital`** with **Not owned selected by default**. Picking **Digital** sticks (the segment stays on
  Digital), those rows commit as digital copies, and rows you tick *afterwards* adopt Digital too —
  **including when you'd unticked the whole group first** (the old bug: with nothing ticked the pick
  snapped back). Picking **Not owned** again returns them to played-not-owned (no copy created). A
  per-row **Own as** override that differs shows the segment as *mixed* (no segment highlighted);
  choosing a segment again re-unifies the group.
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
- [ ] **Resume a cancelled sync.** Start a big sync, **Cancel** partway. Re-sync: the progress reads **"Matching K of N · … · M already matched"** — only the not-yet-attempted titles are re-queried; the ones matched before keep their proposals and alternatives. A title IGDB found no match for is retried after 30 days (or immediately after a Re-match).
- [ ] **Per-row Re-match (wave 16).** In a GOG / Delicious / PlayStation review sheet, a **New** row (one with no confident match) shows a small **Re-match** button and a **⋯ ▸ Re-match** item. Clicking it re-queries just that title against IGDB: the row shows a spinner (click it to cancel), then updates with the fresh proposal + alternatives. It never re-matches the whole sheet. Batocera's review shows **no** Re-match (its ROM rows match by filename). With IGDB not configured the button is absent.
- [ ] **Bundles to Expand list (wave 16).** When the library has any bundle-looking games (Trilogy / Collection / Pack / "N-in-1"), the sidebar shows a **Bundles to Expand (N)** row right under **Unlinked** (hidden when zero). Selecting it lists exactly those games under a header "These look like bundles imported as one game…". Right-click a game ▸ **Expand Bundle into Games…** (also in the inspector / File menu); after expanding — or dismissing a non-bundle with "That's not a bundle on IGDB" — the game leaves the list and the badge drops. A fully-clean library never shows the row.

## Batocera "Review…" entry points (§15, wave 16) [owner]
Fixes the 2026-09-20 report ("I clicked Sync and got this UI, no match window").
- [ ] **Review from Settings.** In Settings ▸ Batocera, after a sync that leaves candidates, the status line shows **"… N waiting to review"** with a **Review…** button, and the post-sync summary shows **"· N to review"** with a Review… button. Clicking either brings the **main window forward** and opens the Batocera promotion review (the same as File ▸ Import from Batocera…). When nothing is waiting, no Review… button appears.
- [ ] **Review from the banner.** When favourites were auto-added, the banner reads **"N favourites added from Batocera · M to review"** and now offers **both** **Undo** and **Review…**; Review… opens the review, Undo reverses the add. *(Wave 17 adds the "Matching favourites… X of Y · Stop" progress line in Settings and makes the pass finish in one sync — see the wave-17 checks below.)*

## Covers, compilation order, stats & sample-mode prefs (wave 17, lane A) [owner]
- [ ] **IGDB artworks in Choose Cover…** For a modern game with key art (e.g. a PS5 title), open the inspector's **Choose Cover…** sheet (live mode). The IGDB section now shows the cover **and** several artworks, each labelled kind · size ("artwork · 1920×1080"). A landscape artwork previews cropped the way the grid crops it (so a wide image doesn't look different once chosen). Picking one files it as the cover. In sample mode the sheet lists no remote candidates (network-free) — only "Choose File…".
- [ ] **A Delicious cover gets upgraded.** After a Delicious import where a game got its box art from the Delicious store, once enrichment runs (live, credentials set) the cover should be **replaced by the IGDB/libretro cover** when one exists — you shouldn't have to use "Choose Cover…" for it. A game the providers can't cover keeps the Delicious box art (no flicker/refetch loop). A cover you picked by hand is never changed. *(Existing libraries were backfilled at first launch on this build — Delicious-origin covers that never went through a cover fetch become provisional and get one attempt.)*
- [ ] **Compilation member order.** Add a compilation from an IGDB bundle (Quick Add a bundle, or a photo-scan / import-review bundle). Its members should be listed **oldest-first by release date**, not IGDB's order (e.g. *Mass Effect 1 · 2 · 3*). A compilation you hand-ordered earlier in the editor keeps its order.
- [ ] **Stats "Backlog to beat".** Open Library Stats (⌥⌘S). The **Backlog to beat** figure reads "≈ H h" with "At your play style" and a basis line "N games, M without an estimate". Change your play style (BY LENGTH header popover or Settings ▸ General) and the figure updates while the window is open. "Me vs. average" still uses the plain advertised IGDB time.
- [ ] **Sample mode leaves your real prefs alone.** Launch with `-VGNSampleData YES`, change the play pace / play style, then quit and launch the real app — your real pace/style/sort/PS-Plus-deadline should be unchanged.

## Empty states · progress modal · narrow inspector · Open on IGDB (wave 17 — lane B) [owner]
- [ ] **Import progress modal doesn't resize.** Run a real GOG / PlayStation / Delicious / Batocera
  sync. While it matches, the sheet stays a **fixed width** — it does **not** grow/shrink as each game
  title appears. The counter reads "Matching N of M" (steady, monospaced), the game title middle-
  truncates on one line, and after ~10 titles an "about N min left" line appears. Resuming a cancelled
  sync also shows "· K already matched". Batocera now shows the title + ETA like the others.
- [ ] **Inspector at the minimum width.** Drag the inspector column as narrow as it goes (min is now
  300 pt). The action buttons (Change IGDB Match… · Refresh metadata · Choose Cover… · Expand Bundle…)
  stack **one per line**, each fully readable — never squeezed letter-by-letter. The Playtime section
  reads as one table (Main / Completionist / Rushed, values right-aligned, "—" when missing) and the
  me-vs-average line ("You 84 h 49 · 141 % of completionist") does not wrap; hover a bar tick for its
  "Main ≈ 39 h" tooltip.
- [ ] **A tour of empty states.** Launch with `-VGNSampleData YES` and also with an **empty profile**
  (a throwaway run with no games). Visit: an empty library (Quick Add), a search/filter with no
  matches (Clear filters / Search all), each empty sidebar smart list (Backlog, Unranked → Start
  ranking, Unlinked, Owned/Played, Unmeasured & BY LENGTH → Fetch Missing Time Estimates…), Play Next
  with nothing ranked (says how many more to rank) and with an over-long bracket, Stats with a scope
  that has no games, The Top with nothing ranked, and both Vault browsers when nothing is set up /
  everything is filtered. Copy should read cleanly (second person, no exclamation marks) and each
  button should do the right thing.
- [ ] **Open on IGDB from Play Next.** On a Play Next pick that is matched to IGDB, the small
  "Open on IGDB" icon button opens the game's IGDB page in your browser (and does **not** select the
  card). A manual / unmatched pick shows **no** such button.

## Grid badges, mixed-state menus, PSN review, sidebar scroll (wave 17) [owner]
- [ ] **Format badges on the grid tile.** A game shows one badge per distinct format it is really owned in, in order: **disc** (blue) for physical, **download** (teal) for digital, **purple chip** for ROM, then the green played controller. The old generic blue "Owned" box is gone. A cartridge + ROM game shows disc + chip. Hover a badge → "Physical · PS3" / "Digital · PS5, PC". *(Wave 19, W19-E: the **PS Plus** badge moved to the top-left corner — see that section.)* *(Known: the disc icon also appears on cartridge games — no media field in `platforms.json`.)*
- [ ] **PS Plus badge asset everywhere.** The blue-cross-in-yellow-circle drawing is replaced by the supplied `psplus.png` badge on the grid tile, the inspector copy row, the Vault browser row, and the import review PS Plus header. It reads clearly at small sizes over a cover.
- [ ] **Mixed-state menus.** Select several games, right-click (and the menu-bar **Game** menu): Set Tier, Mark Owned, Mark Played As, and Change Copy Format show a **✓** on an option every selected game has, a **–** on one only some have, nothing on none. Change Copy Format ticks over single-copy games only and says "N games with several copies not changed" when some are multi-copy.
- [ ] **BY LENGTH title.** The sidebar section header reads "BY LENGTH · 6 h / week" (pace only, no "lots of side quests"); the play style is in the header tooltip and the pace popover.
- [ ] **PSN review — own the ticked rows as.** In *Played — no purchase found*, the header has a **Physical | Digital** toggle. It starts neutral (played, not owned); clicking a segment applies to every ticked row and highlights, later-ticked rows adopt it, and a per-row ⋯ ▸ **Own as** override makes the toggle read neutral/mixed.
- [ ] **PSN review — Launched rows go to the Vault.** The *Launched* group (trophies 0 % **or** play time ≤ 10 min — e.g. *Prey*, 8 min) is unticked by default with "Unticked rows go to the Vault" + a switch. Committing shows "N imported · M sent to the Vault"; ticking a Launched row imports it normally; turning the switch off vaults nothing; **Undo Vault Sends** (committed footer) reverses the vault part (the import itself is final).
- [ ] **Sidebar scrolls at any height (bug fix).** With a tall sidebar (many platforms, Unlinked, Bundles to Expand, The Vault) in a short window, selecting **Bundles to Expand** no longer pushes rows under the title bar or blocks scrolling up — the sidebar scrolls normally, top rows reachable, same as any other selection.

## Batocera bundles · favourites-to-completion · toolbar · IGDB link (wave 17, lane D) [owner]
- [ ] **Dead toolbar controls are gone (D1).** Select **Play Next**, **Tier Board**, **The Top**, **Duel**, or a **Vault** row: the window toolbar no longer shows the library grid's search field, filter menus, sort menu or size slider (they did nothing there). The **Inspector** and **Add Game (⌘N)** buttons still show everywhere. On an ordinary grid list (All / a platform / By Length / Unlinked / Bundles to Expand) all the controls are back. Switching between a grid list and the Vault must **not** make the sidebar shift under the title bar.
- [ ] **Batocera bundles expand (D2).** Promote a Batocera ROM whose IGDB match is a bundle (e.g. *Super Mario All-Stars*, *Sonic Mega Collection*) — through the review, or auto-added as a confident favourite (≥ 2 members). It lands as a **compilation** with its member games (a `rom` copy, not one lonely single), shows **In Library** in the Vault browser, and — if the ROM had play time and the bundle resolved to a single member — that member is marked played. Undo of an auto-add batch removes the whole compilation.
- [ ] **Everything from Batocera is a ROM (D3).** Check a promoted Batocera game in the inspector: its copy is **ROM** (Format ▸ ROM), never Physical/Digital, for a review promotion, a favourite auto-add, a compilation, and a Vault ▸ Add to Library…. The Batocera review sheet offers no Physical/Digital choice.
- [ ] **Favourites finish by themselves (D4).** With *Add my favourites automatically* on and IGDB configured, one sync of your ~247 favourites now matches them **all** (no more 4–5 syncs). While it runs, Settings ▸ Batocera shows **"Matching favourites… N of M · Stop"** (Stop halts it cleanly); the app stays idle (~0 % CPU). It ends with **one** banner: **"N favourites added from Batocera · M need your review"** with **Undo** (undoes the whole run) and **Review…**. If IGDB hiccups mid-run it pauses (the banner says so) and the rest retry next sync — no request storm. Quit mid-run and re-sync: it resumes where it left off, nothing matched twice.
- [ ] **Open on IGDB from "From the vault" (D7).** In Play Next ▸ **From the vault**, a matched card (PS Plus / GOG / Delicious with an IGDB match, or a matched Batocera entry) shows a small **↗ Open on IGDB** button that opens the game's IGDB page in your browser; a card with no IGDB match shows no such button. *(Interim: the link is an IGDB search-by-name until the shared per-id helper is merged — see LIMITATIONS.)*

## PSN bundles expand too (wave 18, §13.3) [owner]
- [ ] **A fresh PSN sync expands bundles.** In the `psn-test` profile, run a PSN sync that contains a
  collection (e.g. *Castlevania Advance Collection*, *BioShock: The Collection*, *Uncharted: The
  Nathan Drake Collection*). The review row reads **"Bundle · N games — imports as a compilation"**;
  committing creates **one** compilation Product (digital for a purchase, the PS Plus copy for a
  claim, physical/digital per *own-as* for a played-no-purchase disc), with the member games listed
  individually and existing library games linked, not duplicated. A second sync adds nothing.
- [ ] **"Which did you play?" once, in the row.** For a collection PSN reports as played, the row
  shows a per-member played tick with **All / None** (default none). Tick exactly one member → its
  play time / last-played / 100 % status land on that member only; tick several → all are played but
  none gets the collection's play time; tick none → all owned backlog, play time stays on the record.
  A collection PSN never played asks nothing.
- [ ] **Played, not owned.** A played-no-purchase collection left with *own-as* neutral reads
  "not owned: only the games you tick are added" and creates only the ticked members (as played, not
  owned) — no compilation Product, and the un-ticked members are not created.
- [ ] **Title tails.** A cross-gen twin like *The Dark Pictures Anthology: Man of Medan PS4 & PS5*
  matches the same IGDB game as its sibling (the platform tail is dropped for matching; the shown
  title still reads "… PS4 & PS5").
- [ ] **Empty review.** A sync with nothing to review shows "Everything is already in your library."
  rather than an empty list.
- [ ] **Expand All Unplayed (N)… (wave 18).** Select **Bundles to Expand**; the header shows an
  **Expand All Unplayed (N)…** button (only when there are candidates with no play data). Clicking it
  checks IGDB one game at a time (a cancellable progress sheet), then shows one confirmation listing
  each "Title → its games", with a tick per row (untick any to keep as one game) and a "Not a bundle"
  list for candidates IGDB has no members for (those leave the list for good). Confirming expands them
  all; **⌘Z** undoes the whole batch in one step. Played bundles are **not** in this batch — expand
  them one at a time (below).
- [ ] **Candidate by IGDB type.** A bundle imported as one game whose **title has no hint** (e.g.
  *Castlevania Requiem: Symphony of the Night & Rondo of Blood*) still appears in **Bundles to
  Expand** because its saved IGDB match says "bundle".
- [ ] **Played bundle → per-member ticks.** For a **played** bundle already imported as a single (e.g.
  *Castlevania Advance Collection* 75 h, *BioShock: The Collection* 52 h), **Expand Bundle into
  Games…** shows the members with a **played tick each (All / None, default none)**; ticking exactly
  one routes the play time / dates to it; the tier/rank target picker appears only when the placeholder
  was ranked.
- [ ] **Re-sync keeps the play time on the chosen member.** After a bundle whose single played member
  you picked at import is committed, a later PSN sync keeps sending its play-time/date updates to that
  same member (it does not re-ask).
- [ ] **Cross-gen twin folding.** A PSN twin like *Man of Medan PS4* / *Man of Medan PS5* that PSN did
  not already merge shows as **one** row with an "also: PS4 & PS5 version" note, not two New rows.
- [ ] **"N h on the whole collection (PSN)" (wave 18 part 3).** Open a PSN compilation whose play
  time stayed on the whole collection (several members played, or none picked). The inspector's copy
  row shows "**75 h on the whole collection (PSN)**" under the "Part of …" line. It does not appear
  when the play time was routed to a single member, nor for a non-PSN compilation. At the inspector's
  narrowest width it stays one line (scales down, never wraps).

## Wave 19 — badge legibility & the one HLTB button

- [ ] **Format badges are recognisable at a glance (D1).** In the real library, on real covers,
  light and dark, at the smallest and largest grid tile sizes: the **physical** badge reads as a
  disc, the **digital** badge as a download arrow, the **ROM** badge as a chip, played as the green
  controller — none reads as a blank white blob. A game owned physical + digital + ROM + played shows
  all four in the bottom row without overflowing the tile. *(Wave 19, W19-E: PS Plus is no longer a
  bottom badge — it sits in the top-left corner, so the bottom row is at most four.)*
- [ ] **No placeholder-label collision (D2).** A game with no cover no longer prints a big "PS4"/"PS5"
  label over the badge row; the platform still shows in the pill under the title.
- [ ] **One HowLongToBeat button in the inspector (D6).** The Playtime section has exactly **one**
  HLTB action, always labelled **"Refresh from HowLongToBeat"**, in the same place, and it looks like
  a button (bordered), not grey text. Clicking it on a game with a bad estimate replaces the times;
  on a game HLTB doesn't know, it says so and changes nothing; it never touches your own "Mine" time.
  The ⚠︎ suspicious row no longer carries its own button — it points at this one. "Open on
  HowLongToBeat" is a blue link with the ↗ icon.
- [ ] **Inspector actions read as buttons (D6).** Change IGDB Match… / Refresh metadata / Choose
  Cover… / Add copy… / Edit compilation… / trash all look like real (bordered) buttons; the inspector
  still lays out correctly at its narrowest width (they stack, each with a visible button shape).
- [ ] **Deleting a copy updates the platform pills (wave 19, lane C).** Take a game owned on **Mac + PC**
  (two digital copies). Delete the **Mac** copy (⇧O, pick the Mac copy — or the inspector). The **"Mac"
  pill under the title disappears**, leaving only "PC"; the **Digital** badge stays, and its tooltip now
  reads "Digital · PC" (was "Digital · Mac, PC"). The inspector's platform list and the sidebar Mac count
  drop Mac too. (One-time: on the first launch after this build, any already-stale platform pills from
  older copy deletions are cleaned up silently.)
  - *Note:* un-owning / removing a copy is **not** an undoable action today (like Delete — see wave-19
    handoff), so ⌘Z does **not** bring the copy back. Where a copy change **is** undoable — a **merge**,
    **bundle expansion** or **IGDB link/relink** — ⌘Z restores every platform row exactly (the row-level
    snapshot always covered `game_platforms`). Making plain copy removal undoable is a separate follow-up.

## Wave 19 — what counts as a game + PS Plus corner (W19-E) [owner]

- [ ] **PS Plus badge in the top-left corner.** On the grid, a PS Plus game shows its badge in the
  **cover's top-left corner**, right after the tier chip (or alone there when the game has no tier),
  vertically centred with the chip and legible at the smallest tile. It is **no longer** in the bottom
  format row. A game owned on disc *and* claimed on PS Plus shows the disc badge at the bottom and the
  PS Plus badge in the corner; a PS-Plus-only game shows just the corner badge, no bottom format badge.
  The inspector copy row and Vault browser still show the PS Plus marker next to the title.
- [ ] **Arkham Knight Steelbook no longer adds Season of Infamy.** Do a fresh scan/expand of the
  *Batman: Arkham Knight* Special Edition Steelbook (or Quick Add it as a compilation). It becomes a
  compilation of the **base game only** — the *Season of Infamy* expansion is **left out** and the
  confirm step says so ("Left out: Season of Infamy — expansion"). (Any *Season of Infamy* already in
  your library is **not** removed automatically — use Edit Compilation… / the reconcile lists.)
- [ ] **3D All-Stars members are the originals.** Expand *Super Mario 3D All-Stars* — its three members
  are the **original** *Super Mario 64* / *Sunshine* / *Galaxy* (IGDB's port entries fold onto the
  originals), oldest-first, and the confirm step lists what was folded ("Super Mario Galaxy → the 2007
  original").
- [ ] **A boxed expansion / DLC is still addable, just labelled.** In Quick Add and Link-to-IGDB, an
  expansion or DLC result (e.g. *Diablo II: Lord of Destruction*) shows an "Expansion"/"DLC" chip but is
  **still selectable** (a boxed expansion is a real thing you own). In an import review, a DLC-type best
  match is **not** pre-ticked — the row stays, labelled, for you to decide.

## Known issues / watch list
- ~~**Title normaliser over-strips budget labels**~~ **Fixed (wave 6, lane C):** budget-line
  labels strip only at `.core` now; *Pokémon Platinum* survives at the fuzzy-matching level.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

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
- [ ] **Play Next** (sidebar): `1–4` brackets, `R` re-roll, `↩` start playing, arrows between cards, `⌫` not this one, `space`/`⌘I` inspect. Do the picks and the *reason sentences* read naturally on your real library? (Needs ≥ 15 ranked games to be more than crowd-prior.)
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
- [ ] Toolbar **Tier ▸ "Unrated"**, **Status ▸ "Not Played" / "No Status"**, **Format ▸ "Not Owned"**: each finds the right games, OR-combines with the real values (e.g. S + Unrated), shows a removable chip, fills the menu icon, and clears with the menu's Clear / "Clear all".
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

## Known issues / watch list
- ~~**Title normaliser over-strips budget labels**~~ **Fixed (wave 6, lane C):** budget-line
  labels strip only at `.core` now; *Pokémon Platinum* survives at the fuzzy-matching level.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

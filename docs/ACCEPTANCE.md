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
- [ ] `⌘N` opens the palette; typing streams results (library instantly, IGDB ~200 ms later); `↑↓` select, `Tab`/`⇧Tab` cycle platform, `⌘O` owned, `⌘P` played, `⌘D` physical → digital → ROM, `⌃S…⌃F` tier (`⌃0` clears), `↩` adds and stays open, `⌘↩` opens the inspector, `esc` clears then closes.
- [ ] **50 games by keyboard in < 5 minutes**, the palette never waiting on the network.
- [ ] Covers appear in the grid within seconds; the sidebar footer shows "Fetching metadata · n left"; quit mid-fetch and relaunch → the queue resumes; relaunch is instant and covers persist.
- [ ] "metal gear solid legacy" offers **Add as compilation** and creates the member games; "bloodb" and "chevaliers de baphomet" both find their game (search fallback).
- [ ] Drop an image on a cell / the inspector cover → custom cover; **Refresh metadata** must not replace it.
- [ ] Bulk **Mark Owned** adds a physical copy on each game's primary platform — acceptable default, or do you want a picker?

### M4 — Ranking (tagged `m4` 2026-09-18)
Logic is exhaustively tested; the *feel* is not. With a few dozen played games:
- [ ] **Triage** (Duel ▸ Triage): `S…F` tiers the current game, `0`/`space` skips, `←` goes back. ~2 s per game?
- [ ] **Duel**: `←`/`→` pick, `↓` skip, `space` peek, `⌘Z` undo; "Placing X · 3 of ~6" reads right; quit mid-placement and relaunch → it resumes. Keys must not leak into the search field or re-tier the grid.
- [ ] Border duel card (promote/demote): `↩` accept, `esc` dismiss. Disputes chip lists cycles ("Settle" re-places the games involved — a precise "duel this pair" API is a follow-up).
- [ ] **Tier Board**: drag within a row, across rows, onto the dimmed unplaced tail; multi-select drag (a 5-game drop is currently 5 undo steps — batch move is a follow-up); `⌥←/→` nudge, `⌥↑/↓` change tier; insertion bar placement feels right?
- [ ] **The Top**: podium proportions, inline dividers; select a platform/decade in the library → Top shows derived *and* overall positions; drag reorder when unfiltered (no insertion line while hovering — known limitation); `⌘E` CSV opens cleanly in Numbers/Excel.
- [ ] **Movable dividers**: drag the S/A line in The Top — is 44 pt per game a good feel? live "S 7 → 9 · A 14 → 12" preview, `esc` cancels, one `⌘Z` undoes; `⌥↑/↓` on a focused divider.
- [ ] **Derived scores** ("#4 · 9.6"): do the bands feel right? S 9.0–10 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9 (one constant file: `VGN/Ranking/DerivedScore.swift`).
- Console note "type com.videogamenerd.ranking-item is not declared" during drags is benign (fix = declare an exported type in Info.plist, milestone 9 polish).

## Known issues / watch list
- **Title normaliser over-strips budget labels**: the `.articleless` level strips trailing "Platinum / Essentials / Greatest Hits / Player's Choice", so *Pokémon Platinum* collapses to "pokemon". Exact `.canonical` matching protects precision; only bites if two real titles collapse to the same form. Fix if seen: gate budget-label stripping behind a flag in `TitleNormalizer`.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

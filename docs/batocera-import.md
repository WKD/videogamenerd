# Batocera ROM catalogue & promotion (PLAN §15, phase 1)

> **Wave 14 (PLAN §16 — The Vault):** the "ROM Catalogue" is now one of two sources in **The
> Vault** (the other is PS Plus, `docs/psn-import.md`). The sidebar section is **THE VAULT**
> with a **Batocera ROMs** row and a **PS Plus** row; the shared table is still `rom_catalog`
> (migration v11 added the nullable PS Plus columns). Batocera behaviour is otherwise
> unchanged. The Play Next "Discover on your Batocera" row will become **"From the vault"**
> over both sources (scorer done; the row's UI rewrite is pending — see `docs/LIMITATIONS.md`).


Phase 1 = **services + database + model + tests**, no UI. It reads the owner's Batocera
share read-only, keeps every ROM in a **separate catalogue** (`rom_catalog`), and promotes
only the ROMs actually played (> 5 min) or favourited into the real library through the
existing importer path. Phase 2 (another wave) builds the sidebar browser, the promotion
review, Settings ▸ Batocera and Play Next ▸ Discover.

## The two tiers (PLAN §15)

- **Library** — a ROM becomes an ordinary game (owned, format **ROM**, `source = batocera`)
  only when the box says it was **played > 5 min** (`gametime > 300 s`), marked **favourite**,
  or promoted by hand. Never counts, never floods the grid until promoted.
- **Catalogue (`rom_catalog`)** — "the shelf in the cellar". Every non-skipped ROM, browsable
  and searchable, **never** seen by Library / grid / counts / stats / ranking / exports. The
  only bridge to `games` is `promoted_game_id` (set on promotion; `ON DELETE SET NULL` — a
  promoted game deleted from the library just unlinks, the catalogue row survives).

## Read-only, offline

Access is a read-only SMB mount at `/Volumes/share/roms/<system>/gamelist.xml`. Nothing under
the share is ever written. The scraped `gamelist.xml` (ScreenScraper) already carries genre,
family, developer, year, rating and the play data, so the catalogue is **browsable, searchable
and taste-scorable with no IGDB call**; IGDB is only needed when a ROM is *promoted* (phase 2,
for the id + dedupe). Everything works from tests with the share absent.

## gamelist.xml format notes

Per `<game id="…">` (the id is the ScreenScraper id): `path` (No-Intro file name with region,
`./Parodius (Europe).zip`), `name` (clean title), `desc`, `rating` (0–1), `releasedate`
(`YYYYMMDDT000000`), `developer`, `publisher`, `genre` (`Shoot'em Up / Horizontal`), `family`
(series, ~30 %), `players`, `region`/`lang` (lowercased codes `us`/`eu`/`jp`/`wr`…), `md5`,
`playcount`, `gametime` (seconds), `lastplayed` (`YYYYMMDDTHHMMSS`), `favorite`/`hidden`
(`true` when set), local `image`/`thumbnail`/`boxback`/`video` paths, plus tags VGN ignores
(`bezel`, `map`, `marquee`, `multidisk`, `cheevosId`, `cheevosHash`, `arcadesystemname`,
`scrap`). XML entities (`&amp;`) are decoded; `<folder>` nodes and unknown tags are tolerated.
The reader (`BatoceraGamelistReader`) is a **streaming `XMLParser`** — a 4 MB gamelist is never
a DOM string soup. `hidden` entries are dropped.

## System → platform table (`BatoceraSystems`)

Batocera system folder → VGN platform slug (all slugs exist in `platforms.json`). Aliases fold
(`megadrive`/`genesis` → `genesis`, `msx1`/`msx2` → `msx`, `supergrafx` → `pcengine`). Mapped
on the owner's box: `snes nes gb gbc gba n64 megadrive→genesis mastersystem→sms gamegear
pcengine pcenginecd megacd→segacd sega32x→32x saturn dreamcast psx→ps1 ps2 psp gamecube wii
wiiu nds→ds 3ds msx1/2→msx colecovision jaguar wswan→wonderswan wswanc→wonderswancolor
virtualboy scummvm→pc dos→pc c64 amstradcpc→cpc xbox360`. An **unknown** system is reported in
the sync summary, never guessed onto a slug (slugs are permanent DB keys).

**Skip list** (constant, phase-2-overridable): arcade romsets (`mame*`, `fbneo`, `daphne`,
`neogeo`, `naomi`/`naomi2`, `atomiswave`, `model2`/`model3`, `chihiro`, `cps*` …) and
non-collection ports/engines/launchers (`prboom`, `mrboom`, `pygame`, `sdlpop`, `steam`,
`flatpak`, `ports`, `kodi`, `moonlight`, `flash`, `odcommander` …). Skip wins over any slug
(`neogeo` has an AES slug but is skipped as an arcade romset). `scummvm`/`dos` are **not**
skipped — they map to `pc` (the owner really plays those).

## Folding (`BatoceraFolding`)

The owner's set is 1G1R, so folding is a safety net, not the main mechanism. Entries are
grouped by the **libretro key** of the file-name stem (the same `LibretroFilenameParser` /
`LibretroIndex.libretroKey` the cover matcher uses — region/disc/revision tags stripped,
punctuation folded, articles + "and" dropped). Multi-disc, revisions, hacks/translations and
leftover regional twins collapse to one row. Representative = the entry **with play data**
(most `gametime`, then favourite), else the preferred region **EU > US > JP**, then Disc 1,
then the first path. The dropped twins are simply not inserted (never a second catalogue row).

## Change detection & sync (`BatoceraSync`, an actor)

For each non-skipped system whose `gamelist.xml` mtime **and** size are unchanged since the
last read (`rom_catalog_sync`), the system is skipped; changed/new systems (or a `force`d run)
are read → folded → upserted. New paths get `first_seen_at`; present paths refresh metadata /
play data + `last_seen_at`; vanished paths get `removed_at` (**never deleted**, even when
promoted). A malformed/unreadable system is reported and the sync **continues** (one bad file
never loses the run). An unmounted share yields a quiet `.shareUnavailable` summary, not an
error storm. The summary carries systems read/skipped/unchanged/failed, unknown systems,
entries added/updated/removed, folded count, promotion candidates and duration.

## Promotion (`BatoceraImporter` / `BatoceraPromotionBuilder` / `BatoceraPromoter`)

`BatoceraImporter: LibraryImporter` (source id `batocera`, no network/auth like Delicious):
`fetch` yields staging rows for the promotion candidates (or an explicit catalogue-id list for
a hand "Add to Library"). Promotion commits through the **existing** `ImportStagingStore.commit`
path:
- owned copy, **format ROM**, `external_id = <system>/<relativePath>`, platform from the table;
- **played** data reuses the PSN commit fields (`PSNCommit`): `markPlayed` when `gametime > 300`,
  play time, last-played date; a favourite with no play time is owned-not-played;
- **duplicate rule**: if the matched IGDB game already owns a ROM copy on the same platform,
  no second copy is created — the play data still lands and the catalogue row is linked
  ("Already in your library");
- after commit, `promoted_game_id` is set on each catalogue row (`BatoceraPromoter`).

`playcount` alone never promotes; the 5-minute threshold is one constant
(`BatoceraPromotion.playedThresholdSeconds = 300`, `> 300` exclusive).

### How Batocera play time is stored (v17, wave 21)

Three columns, one per source: `my_playtime_s` (manual, typed — never written by an importer),
`psn_playtime_s` (PSN only) and **`batocera_playtime_s`** (Batocera only, migration v17). The
promotion commit (`PSNCommit.playtimeColumn = .batocera`), the favourites auto-add and a
one-member bundle all write it through `LibraryStore.setBatoceraPlaytime` — **monotonic max**
(a re-promotion never lowers it) and never touching PSN's or the manual value.

Read side, everywhere play time is used (grid sort + playtime filter, Stats, Play Next remaining
time, CSV export, inspector bar): **manual if set, else MAX(PSN, Batocera)** — the same act
measured on two machines, never summed (`LibraryQuery.effectivePlaytimeSQL` + the Swift mirror
`EffectivePlaytime`). The inspector's Playtime section lists "PSN" and "Batocera" on their own
rows. The JSON export carries `batocera_playtime_s`, the CSV a `batocera_playtime_hours` column.

Until v17 the Batocera time was parked in `psn_playtime_s` when both columns were empty (the
phase-1 interim). v17 moved it once, on the owner's request: Batocera-tied games with no PSN copy /
PSN import row / promoted PS Plus Vault row had `psn_playtime_s` moved to `batocera_playtime_s`;
then every game with a promoted catalogue row got the largest catalogue `game_time_s` > 0 when
still unset (games that also have a PSN time keep PSN's in `psn_playtime_s`).

## Taste-ready queries (`RomCatalogStore` + `RomCatalogTraits`)

Read-only API for phase 2 (no UI): `entries(system:…)`, `search(_:system:…)` (diacritics-
insensitive FTS5), `countsPerSystem()`, `neverPlayedPool(…)`, `promotionCandidates(…)`.
`RomCatalogTraits` maps a ScreenScraper genre onto the IGDB-style `GameTrait` vocabulary the
recommendation engine consumes (`RomCatalogEntry.traits`): the top-level genre → a `.genre`/
`.theme` trait via a table (`Platform`, `Role Playing Game` → `Role-playing (RPG)`, `Shoot'em
Up` → `Shooter`, `Action` → theme `Action`…), every segment also a `.keyword`; `family` →
`.franchise`, `developer` → `.developer`, year → `.decade`. On the owner's box **91.6 %** of
entries' top-level genres map to a known trait. `Recommendation/**` was **not** touched.

## What phase 2 needs (wiring — this lane wrote no UI)

- **Settings ▸ Batocera**: pick the share root (remembered), Sync Now (`BatoceraSync.sync`),
  skip-list override, an automatic sync at launch when the share is reachable.
- **Sidebar "Batocera"** browser: per-system list/search via `RomCatalogStore.entries/search/
  countsPerSystem`, with "Add to Library" → `BatoceraImporter(store:, catalogIDs:)` +
  `BatoceraPromoter.promote`.
- **Promotion review** after a sync: `BatoceraSyncSummary.candidateCatalogIDs` → build
  `BatoceraPromoter.Plan`s (IGDB-match each candidate; `gameHasROMCopy` gives the duplicate
  flag) → `promote` → banner + Undo.
- **Play Next ▸ Discover**: intersect the platform best-ofs with `neverPlayedPool`, score with
  `RomCatalogEntry.traits` + the crowd `rating`; "Not interested" → `setNotInterested`.
- **Lane-A schema ask**: the neutral `imported_playtime_s` column (above).

## Privacy / read-only rules

Nothing derived from the share is committed except aggregate facts and a handful of game
titles in tests/docs (titles are product names). No ROMs, images or videos are copied. The
share is opened read-only; the mount may vanish and everything still works from tests (no test
reads `/Volumes/…`; all gamelists in the suite are built in code).

---

# Phase 2 — UI as built (wave 13, PLAN §15)

Phase 2 adds the whole owner-facing surface on top of the phase-1 services. Nothing here
changes the schema (v10 already carries `dismissed_at` / `not_interested` / `promoted_game_id`).
Every promotion still goes through the **review sheet** — nothing is ever auto-committed into
the library (the owner has ~134 hand-entered ROM copies and IGDB matching can be wrong).

## What runs automatically vs. never

- **Auto-sync at launch (live only).** If the share is mounted and *"Sync automatically at
  launch"* is on (default), a change-detecting sync runs **after the UI is up**, off the main
  actor, one at a time, cancellable. It updates the catalogue only; when it finds new promotion
  candidates it shows a quiet banner **"N Batocera games ready to review"** with a **Review…**
  action. Sample / seeded / test runs get an **inert** backend and **never touch `/Volumes`**.
- **Never automatic:** promotion into the library. The banner's *Review…*, the File ▸ *Import
  from Batocera…* command, and the browser / Discover *Add to Library…* all open the shared
  review sheet; a game is added only when the owner commits it.

## Settings ▸ Batocera (`BatoceraSettingsPane`)

Share folder (an `NSOpenPanel` that picks the folder containing `roms/`, default suggestion
`/Volumes/share`, stored in `AppPreferences.defaults`), a status block (mounted / not mounted,
last sync, systems + catalogue size + candidates waiting), **Sync Now** with progress + cancel,
the **"Sync automatically at launch"** toggle (default on), the **editable skip list** (defaults
from `BatoceraSystems.defaultSkipList`; removing a non-arcade entry un-skips it; `mame*`/`cps*`
families are always skipped), and the read-only promotion threshold. Errors are quiet and
specific ("Batocera share not mounted"). The pane is `settingsPane()`-sized (≈ 570 pt,
`SettingsPaneSizingTests`).

## Sidebar "Batocera ▸ ROM Catalogue" + the browser (`RomCatalogueView`)

A **"Batocera"** section after *By Length*, before *Platforms*, shown **only when the catalogue
is non-empty**. Its count comes from a **separate** `rom_catalog` observation
(`vm.romCatalogueCount`), never the library counts — so 11 000 ROMs never touch any library
number (`SidebarSelection.romCatalogue` returns `nil` from `SidebarCounts.count(for:)`; a test
asserts the library counts are byte-identical with a 10 000-row catalogue). The row routes to a
**separate** view (not the grid): a system picker with counts, an FTS search field, a sort menu
(title / rating / year / recently added / most played), filter chips (Never played · Played ·
Favourites · In my library) and a paged list — thumbnail (read from the share off-main through a
small bounded cache keyed by path + mtime; placeholder when unmounted, never copied), title,
system pill, year, genre, ★ rating, play time and an **In Library** marker linking to the
promoted game. Row / selection actions: **Add to Library…**, **Not Interested**, **Show in
Finder** (when mounted).

## Promotion review (`BatoceraImportHookup`)

Reuses the shared `ImportReviewSheet` ("Import from Batocera"). Candidates (played > 5 min or
favourite, not promoted, not dismissed) or a hand-picked set → each staged row is IGDB-matched
by the existing `ImportSyncCoordinator` + `ImportMatcher` (platform-constrained, release-year
tie-breaker) **while a progress sheet with a cancel shows the `completed/total`**; matched
results persist in the staging table, so reopening does not re-query. Rows show the platform,
the play-time line ("4 h 12 · last played Apr 2025 · ★") and the duplicate state **"Already in
your library — adds play time only"** when the matched game already owns a ROM copy on that
platform (`gameHasROMCopy`). Commit runs through **`BatoceraPromoter`** (not the shared
`commitItems()`): a ROM copy (`source = batocera`, format `.rom`), played + playtime + last
played per phase-1 rules, favourites-with-no-playtime owned-not-played, and the catalogue row
linked (`promoted_game_id`). The shared model got two small additive seams for this: a
`romPromotion` flag (the duplicate note) and a `customCommit` closure (the Promoter path);
GOG / PSN / Delicious are unaffected.

**First-run cost.** ~290 candidates on the owner's box → ~290 IGDB autocomplete requests
(one per new row, through the rate limiter), a few minutes; already-matched rows on a re-run
cost nothing.

## Play Next ▸ "Discover on your Batocera" (`DiscoverScorer` + `DiscoverRow`)

A separate row **below** the regular picks, hidden when the catalogue is empty or Play Next has
"not enough data" (no ranked games). Candidates = never-played, not-promoted, not-dismissed
catalogue entries (`neverPlayedPool`). Scored by **my taste, not popularity**, by a **new**
pure scorer next to the engine (the engine's weights and backtest are untouched):

- trait affinity (`RomCatalogTraits` genre/theme/keyword/franchise/developer/decade vs my ranked
  games weighted by tier/derived score) via the engine's `TraitProfile`;
- direct links ("same series as *X* (your S tier)", "from the makers of *Y*") via `DirectLinks`;
- the crowd `rating` only as a **prior** (a small, capped weight that shrinks as I rank more
  games — ScreenScraper gives no rating count, so the engine's crowd term is replaced here);
- **system affinity** (a small constant nudge for systems I actually play);
- time fit is **neutral** (catalogue entries have no length — never a penalty);
- minus anything **Not Interested**.

**Rotation:** a deterministic weekly seed (ISO week) mixes exploration into the top so the row
changes week to week without being random on every refresh; **Shuffle** re-rolls within the
week. 5–8 cards: thumbnail, title, system, year, genre, taste reason(s), ★ rating; actions
**Add to Library…**, **Not Interested**, **Show in Catalogue**. Excluded from the taste backtest
(no ground truth). Scoring runs off the main actor (≈ 0.36 s for 11 300 entries).

**"Ask Claude" (wave 21).** The row (now "From the vault") has the same on-demand second opinion
as the regular picks: **Ask Claude** sends the tier list + the vault shortlist (the scorer's top 10
for the Play Next bracket) through the shared `claude` CLI provider; an Engine vs Claude panel
shows Claude's re-ordering with a reason and optional caveat, cancellable, cached per (shortlist,
bracket) for the session. A matched entry is described (source, IGDB genres/themes/year/rating,
time estimate, PS Plus months left); an **unmatched ROM goes as title + system only** and Claude
may say it doesn't know it. Nothing is stored. See `docs/LIMITATIONS.md` §5j.

## Favourites — the ★ you set on the box (`BatoceraFavouriteAutoAdd` + wave 13)

A ★ on Batocera is curation, not noise (PLAN §15), so a favourite gets special treatment at
three levels — all built in wave 13.

### 1. Auto-added to the library on a confident match

After **every** sync (manual or automatic), and only when *"Add my favourites automatically"*
is on (Settings ▸ Batocera, default **on**) **and** IGDB is configured, VGN runs a background
pass (`BatoceraFavouriteAutoAdd`, off the main actor, cancellable):

- it takes the favourites that are **not promoted, not dismissed and not already staged**
  (`RomCatalogStore.favouritesNeedingMatch`) — a favourite that has been through matching once
  has an `import_titles` row, so **it is never queried twice**;
- each is **staged first** (so a crash before the promotion commits still doesn't re-query it),
  then matched through the shared `ImportMatcher` (the same IGDB ladder + rate limiter the review
  sheet uses);
- a match is **confident** — the rule in `BatoceraFavouriteMatch` — when it is in the **top
  confidence bucket** (the same the review sheet pre-ticks), is **platform-consistent** (the
  match lists the ROM's platform when both are known), and is **release-year-consistent** (a gap
  of **more than one year downgrades it to "needs review"**);
- confident favourites are promoted through `BatoceraPromoter` in **one batch** (`source =
  batocera`, `format = rom` — everything from Batocera is a ROM, PLAN §16; owned-not-played unless
  `gametime > 600`; a game that already owns a ROM copy on that platform gets the link + play data
  only, never a second copy);
- a confident match that is a **bundle** (wave 17, D2) expands into its members and is auto-added
  as a `rom` **compilation** — but only when it has **≥ 2 members** (a 0/1-member bundle is
  ambiguous and waits for review); `promoted_game_id` points at the first member (In-Library
  detection works for a compilation);
- everything else (ambiguous, unmatched, year-mismatched, played-but-not-favourite) **stays for
  the review sheet** — auto-add never commits anything but a confident favourite.

**The run finishes by itself (wave 17, D4).** `batchCap = 60` is now the **batch size**, not the
run limit: after a sync the presenter (`BatoceraImportPresenter.runFavouriteMatching`) runs
batches back-to-back — one IGDB request stream, the same rate limiter — until no un-attempted
favourite remains, so one sync matches all ~247. It is **cancellable** and **pauses cleanly on any
IGDB error** (the pass uses the *throwing* matcher, not the resilient wrapper the review uses; the
first failure stops the whole run — no retry storm — and the not-yet-attempted favourites wait for
the next sync). Because each processed favourite is staged, a quit/cancel/error resumes on the
next sync without re-querying (nothing is queried twice).

**Progress + banner.** While it runs, Settings ▸ Batocera shows **"Matching favourites… N of M ·
Stop"** — the presenter and the settings model share one `@MainActor @Observable`
`BatoceraFavouriteProgress` (no timer, no polling: values change only when a batch finishes, so
the app idles at ~0 % CPU); **Stop** cancels the run. When it ends, **one** final banner:
**"N favourites added from Batocera · M need your review"** with **Undo** (the whole run is a
single undo step — it removes exactly the games/ROM copies every batch created and clears
`promoted_game_id`; idempotent, so the button and ⌘Z can't double-undo) and **Review…**. When
auto-add is **off**, the old **"N ready to review · Review…"** banner shows instead. *(The in-window
progress banner was skipped — the banner API is one-shot messages, so a live-updating one would
fight the other banners; the Settings line + the final banner cover it.)*

### 2. A boost in Play Next's regular picks

An **unplayed** library game that is still a favourite on the box carries
`Candidate.isBatoceraFavourite` (loaded by one additive `EXISTS` join on `rom_catalog` in the
candidate query — no N+1). The engine adds a **small constant bonus** (below the taste/crowd
terms, so it only reorders near-ties) and the reason **"★ a favourite on your Batocera"**. Like
the PS Plus term it is applied in the engine only, never in the taste backtest's `predict`, so
it is backtest-neutral. It is gone the moment the game is played/finished or un-favourited on
the next sync.

### 3. Pinned in Discover

A never-played favourite still in the catalogue (no confident match, or auto-add off) is
**pinned at the head** of the "From the vault" row, ordered among the favourites by taste
score, **exempt from the weekly rotation jitter**, and led by the reason **"★ your favourite"**.
At most **half the visible cards** may be pinned favourites (`DiscoverModel` passes
`cardCount / 2`), so the row still discovers. **Not Interested** retires them like any other row.

## Owner first-run walkthrough

1. **Settings ▸ Batocera ▸ Choose…** the share folder (the one with `roms/`; `/Volumes/share`
   is suggested). Leave *"Sync automatically at launch"* on.
2. **Sync Now** (or just relaunch). The catalogue fills; with *"Add my favourites
   automatically"* on, your ★ favourites with a confident IGDB match are added straight away —
   **"60 added · 187 still to match"** on the very first sync (the 60-per-run cap), with an
   **Undo**. Relaunch or Sync Now again to keep adding the rest; nothing is ever matched twice.
   Without auto-add (or with IGDB not configured) you get the **"N Batocera games ready to
   review"** banner instead.
3. **Review…** → the *Import from Batocera* sheet matches the remaining played/favourite ROMs
   (ambiguous or unmatched favourites, and everything played > 5 min) to IGDB. Untick anything
   wrong, use **Find…** on a no-match row, then **Import**. Duplicates you already own get play
   time only.
4. Browse the rest under **Sidebar ▸ Batocera ▸ ROM Catalogue**; **Add to Library…** anything
   you want, **Not Interested** on anything you don't.
5. Open **Play Next** for the **Discover on your Batocera** row — retro games you own but never
   played, ranked by your taste. **Shuffle** for a new set.

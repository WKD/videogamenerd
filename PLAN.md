# VGN — Video Game Nerd · Implementation Plan

Native macOS app to catalogue every game I've owned or played, and rank them (tiers + one ultimate Top).

Repo: https://github.com/WKD/videogamenerd.git · Local: `~/Code/videogamenerd`

---

## 1. Key decisions (TL;DR)

| Topic | Decision | Why |
|---|---|---|
| OS target | **Deploy to macOS 15, build against the macOS 26 SDK** | Dev Mac runs 15.7.7. The 26 SDK is already installed (CLT), so the app picks up Liquid Glass + the big SwiftUI list/grid perf gains automatically when run on 26. See §2. |
| Toolchain | **Plain committed Xcode project** (`VGN.xcodeproj`, folder-synchronised groups, no XcodeGen), Swift 6 language mode, GRDB as the only SwiftPM dependency | Xcode is being installed. Synchronised groups mean files created on disk show up automatically — no regenerate step (romlord's XcodeGen pain point). Real app target: asset catalog, previews, Instruments, proper signing. |
| UI | SwiftUI (`NavigationSplitView`, `LazyVGrid`, `@Observable`), AppKit only where SwiftUI falls short | Modern, fast enough with the image pipeline in §9. |
| Persistence | **GRDB 7 (SQLite, WAL, `DatabasePool`)** + FTS5 | SwiftData becomes possible with Xcode, but GRDB stays: FTS5 instant search, explicit migrations, async `ValueObservation`, raw SQL for the filter/rank queries, and it is already proven in romlord. |
| Metadata | **IGDB** (Twitch client-credentials) | Best coverage console + PC, genres, dates, platforms, bundles, *and* time-to-beat, one set of credentials. |
| Box art | Provider chain: platform-specific box art first, IGDB cover fallback, manual override | See §5.2. |
| Photo scan | **Claude vision through the local `claude` CLI (headless, subscription-billed)**, on-device Apple Vision OCR as offline fallback / serial-code booster | Shelf spines are rotated, stylised logos, mixed platforms, French editions — OCR alone won't cut it. No API key, no extra cost. See §6.2. |
| PSN | Native Swift client over the unofficial PSN mobile API (NPSSO → tokens). Trophies are only a **"did I play this?" signal** — no trophy data is stored or shown | No official API exists. Isolated behind a protocol; import is always review-then-confirm. |
| Ranking | **Tiers = dividers inside one ordered list.** Fine rank by **binary-insertion duels inside the tier**, plus drag-reorder. | Incremental by design: a new game costs 1 keystroke (tier) + ~5–7 duels, forever. See §7. |
| Tiers | **S A B C D F**, labels/colours editable | Decided. |
| Play Next | **Local, explainable recommendation engine**: taste profile learned from my own tiers/ranks + a time-commitment bracket → one pick (and a few alternatives) among library games I haven't completed | No ML service, no network at recommendation time; every suggestion says *why*. See §7b. |
| Ownership formats | **physical · digital · ROM** | A ROM is a first-class way to own a game (added manually for now; no importer). |
| Tests | Swift Testing, unit-test target `VGNTests`, run with `xcodebuild test` | Pure-logic layers (ranking, matching, DB queries) are tested without UI or network. |

---

## 2. macOS 15 vs 26 vs 27 — what you'd actually gain

**Recommendation: minimum macOS 15, compiled with the 26 SDK, `if #available` for the extras.** Your Mac is on 15.7.7, so a 26 minimum would lock you out of your own app today.

- **macOS 26** (free when the app runs on 26, no min-target bump needed): Liquid Glass sidebar/toolbar, much faster SwiftUI lists & lazy containers, native SwiftUI `WebView` (we wrap `WKWebView` in ~20 lines on 15 for the PSN login), Foundation Models on-device LLM (text-only — could clean OCR text into titles, marginal).
- **macOS 27** (per WWDC26 coverage): `.reorderable()` / `.reorderContainer(for:)` drag-reorder that works in `LazyVGrid` (would simplify the tier board), `AsyncImage` caching + custom `URLSession`, `ContentBuilder` compile-time gains (that one is Xcode 27-side, any target). Nice, not essential: we need our own image pipeline anyway (downsampling, permanent storage), and tier-board reordering is doable on 15 with `draggable`/`dropDestination`.
- **Verdict:** nothing in 26/27 changes the architecture. If you upgrade the Mac to 26+ later, bumping the minimum is a one-line change and lets us delete the fallbacks.

---

## 3. Project layout

```
videogamenerd/
├── VGN.xcodeproj                 # committed; app target "VGN" + test target "VGNTests"; macOS 15.0 deployment
├── CLAUDE.md                     # build/run/test commands, conventions
├── VGN/                          # ONE app target, synchronised folder (internal-by-default)
│   ├── VGNApp.swift
│   ├── Model/                    # Game, Product, Platform, Tier, Comparison…
│   ├── Database/                 # AppDatabase, migrations (one closure per version), queries, FTS
│   ├── Ranking/                  # RankingEngine (binary insertion, keys, invariants) — pure logic
│   ├── Matching/                 # title normalisation, fuzzy match, dedupe
│   ├── Services/
│   │   ├── IGDB/                 # token actor, rate limiter, Apicalypse queries
│   │   ├── Covers/               # CoverProvider chain, CoverStore actor
│   │   ├── Importers/            # LibraryImporter protocol · PSN/ (auth, played list, purchased) · GOG/ (later)
│   │   ├── Recognition/          # ShelfRecognizer: ClaudeCLI + Apple Vision
│   │   └── TimeToBeat/           # IGDB provider (+ optional HLTB provider)
│   ├── UI/                       # Sidebar/ Library/ QuickAdd/ Detail/ Ranking/ Import/ Settings/
│   ├── Resources/                # platforms.json, LibretroRepoMapping.plist
│   └── Assets.xcassets           # app icon, accent colour, tier colours
├── VGNTests/                     # Swift Testing, fixtures (incl. small shelf JPEGs), no network
└── samples/                      # original shelf photos — git-ignored
```

Build / test from the CLI (what I'll use while developing):
`xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' build` · same with `test`.

**One target on purpose.** romlord started as several SwiftPM packages and collapsed them mid-flight (its PLAN.md: "boilerplate tax — every type `public`, `Bundle.module` friction — outweighed the benefit… one consumer, no library use case"). Layering is kept by folders and by keeping `Ranking/`, `Model/`, `Matching/` free of UI/network imports; tests use `@testable import VGN`.

**Carried over from romlord** (all proven there): GRDB + FTS5 with sync triggers and one-migration-per-version; the actor-based three-layer artwork store with negative-cache sentinels and in-flight de-dup; data-driven platform list in JSON (not a Swift enum); `List(.sidebar)` with an `.all` / `.platform(id)` selection enum (its documented gotcha: `.tag()` type must match the selection type exactly); `LazyVGrid` adaptive 140–180 pt, fixed 3:4 tile, `lineLimit(2, reservesSpace: true)` titles, corner badge overlays, per-cell `.task(id:)` loading — confirmed smooth to 5–10 k cells, so no `NSCollectionView`. **Done differently:** plain `NavigationSplitView` instead of an AppKit split-view shell (romlord only kept that for a collection view it never needed); ImageIO downsampling (romlord decodes full-res PNGs); strict concurrency from day one; no XcodeGen (synchronised folder groups remove the need for it).

**Signing & sandbox:** signed with your Apple Development identity ("Sign to Run Locally" as fallback) so Keychain items (IGDB secret, PSN tokens) don't re-prompt on every build. **App Sandbox off** — a personal, non-App-Store app, and the photo scanner must spawn the `claude` CLI, which a sandboxed app cannot do. Hardened runtime on.

**Xcode to install:** the latest Xcode that runs on macOS 15.7 (the Xcode 26.x line; Xcode 27 may require macOS 26 — check before downloading). Then `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch`.

---

## 4. Data model

The central idea: **separate the *work* you rank from the *thing* you own.**

- **Game** — the unit that is played, tiered and ranked. One rank slot per game.
- **Product** — a thing you own: a disc, cartridge, digital licence **or ROM** on one platform. A product contains 1..n games.
  - A standalone copy = product with one game. A **compilation = product with n games.**
  - "Owned" is *derived*: a game is owned iff it belongs to ≥ 1 product. So a compilation is all-or-nothing **by construction** — there is no way to own half of it — while each member game still has its own played flag, tier and rank.
- Remasters/remakes are separate Games (as IGDB models them): *The Last of Us* (PS3), *Remastered* (PS4), *Part I* (PS5) rank independently. Same game on two platforms (Elden Ring PS4 + PS5) = one Game, two Products.

```
platforms      id(slug) · name · short · manufacturer · kind(console|handheld|computer|arcade) · generation · igdb_id · sort
games          id · igdb_id? · title · sort_title · release_date · year · decade(generated)
               played · status(playing|finished|completed|abandoned)? 
               tier_id? · rank_key?                       -- §7
               my_playtime_s? · psn_playtime_s? · ttb_hastily_s? · ttb_normally_s? · ttb_completely_s? · ttb_source
               cover_file? · added_at · updated_at
game_platforms game_id · platform_id · played             -- where I played it (not owned case)
genres / game_genres
products       id · title · platform_id · kind(single|compilation) · format(physical|digital|rom)
               edition? · region? · igdb_id? · cover_file? · source(manual|photo|psn) · psn_entitlement? · acquired_at?
product_games  product_id · game_id · position
tiers          id · letter · label · color · sort        -- S Masterpiece / A Excellent / B Good / C Average / D Bad / F Awful, editable
comparisons    id · winner_id · loser_id · context(placement|refine) · created_at   -- full duel log, never deleted
import_titles  source(psn|gog|…) · external_id · name · platform · signals(played|owned) · play_duration?
               first/last played? · matched_game_id? · ignored
                                                   -- generic staging table for every importer: re-sync is idempotent,
                                                   -- mappings persist. No trophy details are kept.
games_fts      FTS5(title, alt_titles)             -- instant search
catalog_cache  igdb_id · json · fetched_at         -- makes repeat autocomplete instant/offline
game_traits    game_id · kind(franchise|series|developer|theme|mode|perspective|keyword|similar) · value
                                                   -- generic taste features for §7b, filled by enrichment
games          + igdb_rating? · igdb_rating_count?  -- prior for unranked candidates (§7b)
rec_feedback   game_id · action(snooze|never|picked) · created_at   -- "not this one" memory for §7b
```

Invariants (enforced in `VGNCore`, unit-tested):
1. A game must be **played or owned** (≥ 1 product). Removing the last of the two asks to delete the game.
2. Only **played** games can have a tier / rank. Owned-unplayed = **Backlog**.
3. Rank order is always consistent with tiers (§7).

---

## 5. Data sources

### 5.1 IGDB (metadata, autocomplete, compilations, time-to-beat)
- Auth: Twitch app client id/secret → app token (actor with auto-refresh). Entered once in Settings, stored in Keychain.
- Rate limit 4 req/s → token-bucket limiter actor; all calls cancellable.
- Search: `search "…"; fields name, first_release_date, platforms.abbreviation, cover.image_id, genres.name, game_type, alternative_names.name; limit 12;`
- Compilations: IGDB `game_type = bundle` + `bundles` relation pre-fills member games; coverage is imperfect, so the compilation editor lets me add/remove members with the same quick-search.
- **Average completion times:** IGDB `game_time_to_beats` (`hastily` / `normally` / `completely`, in seconds, + submission count). Official, stable, same credentials, batchable by game id.

### 5.2 Box art
`CoverProvider` protocol, tried in order, first good hit wins; all candidates remain browsable:
1. **libretro-thumbnails** (romlord's source — free, no key, real per-platform box scans, covers everything retro up to roughly PS3/Vita/Wii U/3DS): `raw.githubusercontent.com/libretro-thumbnails/{repo}/master/Named_Boxarts/{name}.png`. Reuse romlord's `LibretroRepoMapping.plist` and repo-name rules. Difference from romlord: it had exact No-Intro/Redump names from DATs; VGN only has an IGDB title. So per platform we fetch the repo's file listing **once** (GitHub tree API, cached), index it locally, and fuzzy-match title + preferred region (Europe/France first, then USA, Japan), reusing romlord's tag-stripping ladder (`(En,Fr)`, `(Disc 1)`, edition tags) in reverse.
2. **IGDB cover** (`images.igdb.com/…/t_cover_big_2x/{image_id}.jpg`) — always available, the answer for PS4/PS5/Switch/PC where libretro has nothing. Platform-agnostic key art.
3. *(Optional, later)* TheGamesDB — API key, per-platform/region front box art for modern platforms, if IGDB art looks too inconsistent next to real boxes.
4. Manual: "Choose cover…" sheet showing every candidate from every provider, or drag any image onto the game.

Tiles are a fixed 3:4 (romlord's cell); box shapes vary wildly by platform (SNES landscape, PS1 square, DVD-tall), so art is aspect-*fit* on a neutral backing rather than cropped. Misses write a negative-cache sentinel (7-day TTL) so the grid never re-hits the network on every render.

Covers are **library assets, not cache**: stored permanently in `~/Library/Application Support/VGN/covers/`, plus pre-downsampled grid thumbnails (§8).

### 5.3 HowLongToBeat
No official API. Every wrapper scrapes an internal search endpoint whose path/key rotates and breaks regularly. Plan: IGDB time-to-beat is the default; HLTB is an **optional, experimental provider** behind the same `TimeToBeatProvider` protocol (off by default, fails soft), and the inspector always has an "Open on HowLongToBeat" link. Values are editable by hand either way.

### 5.4 PlayStation Network (unofficial)
- Auth: in-app web login → read `npsso` cookie → exchange for access code → access + refresh tokens (Keychain). Paste-NPSSO fallback.
- **Trophy titles** `m.np.playstation.com/api/trophy/v1/users/me/trophyTitles` (paged, max 800; PS3/Vita included with `npServiceName=trophy`) → used **only as a "played" signal**: a title with ≥ 1 earned trophy = a game I played. This is the one way to recover PS3/Vita history. We keep title, platform and last-activity date; trophy counts/details are discarded and never shown. (Caveat: pre-2008 PS3 games and a few others have no trophies, so they won't appear — manual/photo add covers those.)
- **Game list** `…/api/gamelist/v2/users/me/titles` → **play duration**, play count, first/last played. **PS4/PS5 only** — Sony doesn't expose PS3/Vita playtime.
- **Purchased list** (web GraphQL `getPurchasedGameList`) → *Owned (digital)*, with the PS Plus-claimed vs bought distinction so Plus freebies can be excluded.
- Risk: unofficial, can break or change; ToS grey zone for personal use. Hence: isolated module, fixtures-based tests, never blocks the rest of the app.

### 5.5 Other libraries (later)
All importers implement one `LibraryImporter` protocol (authenticate → fetch → emit `import_titles` rows → shared review sheet), so adding a source never touches the core.
- **GOG** (wanted): unofficial but long-stable account API (`embed.gog.com/user/data/games` + `account/gameDetails`), web login like PSN → *Owned (digital)*, PC/Mac. No play time.
- Steam / Xbox / Nintendo: not planned. The protocol leaves the door open.

### 5.6 Platforms
Data-driven `platforms.json`, grouped by manufacturer in the sidebar: Sony, Nintendo, Sega, Microsoft, Atari, NEC, SNK…, **Computers** = one **Mac** platform (classic Mac OS + macOS together), one **PC** (DOS + Windows), plus distinct retro machines as needed (Amiga, Atari ST, Amstrad CPC, C64, Apple II…), and Arcade. Each maps to IGDB platform id(s) and, where one exists, a libretro-thumbnails repo.

---

## 6. Adding games

### 6.1 Quick Add (⌘N) — the fast path
Spotlight-style palette, keyboard only:
1. Type 3+ letters → results stream in (local library + catalog cache instantly, IGDB ~200 ms later; 150 ms debounce, previous request cancelled). Rows: cover, title, year, platform chips. Already-in-library rows are marked.
2. `↑↓` select · `Tab` cycles platform (defaults to the sidebar's current platform, else the game's most likely one) · `⌘O` owned / `⌘P` played (sticky from last add) · `⌘D` cycles the owned format **physical → digital → ROM** (sticky too) · optional `S A B C D` sets the tier right away.
3. `↩` adds; the field clears and **stays open** for the next game. `⌘↩` adds and opens the inspector. `esc` closes.
- Picking a bundle result offers "Add as compilation (n games)".
- Fully manual entry (no IGDB match) is one more row at the bottom: "Create '…' manually".
- Metadata, cover and time-to-beat are fetched in the background *after* insertion — adding never waits on the network.

### 6.2 Photo scan
Your samples set the requirements: shelf shots with 40+ vertical spines (rotated 90°, stylised logos, PS3/PS4/PS5/Xbox 360 mixed, French titles like *Les Chevaliers de Baphomet*, collector boxes, steelbooks with no text), and single front-cover shots.

Pipeline (`ShelfRecognizer` protocol, two engines):
1. Input: drag-drop / file picker / Continuity Camera ("Take Photo" from iPhone). HEIC/PNG/JPEG. Photos are split into overlapping **~1 500 px JPEG tiles** (per shelf row) written to a temp folder: Claude Code's image reader works best under ~2 000 px a side and does not reliably downscale a 5 712 × 4 284 original, and tiling keeps spine text legible.
2. **Claude vision via the local `claude` CLI** (`ClaudeCLIRecognizer`). The app spawns, per tile, in parallel (bounded):
   ```
   claude -p "Read <tile.jpg> and list every video game visible…" \
     --output-format json --json-schema '<schema>' \
     --allowedTools Read --permission-mode dontAsk --max-turns 3 --model <configurable>
   ```
   and decodes structured JSON per item — title as printed, normalised title guess, platform (from the spine banner), edition hints (Collector's, GOTY, Deluxe), is-compilation guess. Overlap duplicates are merged afterwards.
   - **Billing:** uses the OAuth login of your Claude Code install → counts against your subscription limits, no API cost. The spawned process gets a scrubbed environment (no `ANTHROPIC_API_KEY`, which would silently switch it to API billing) and must *not* use `--bare` (that skips the subscription login).
   - **Why not ACP:** the Agent Client Protocol (Zed's JSON-RPC editor↔agent protocol, via a Node adapter over the Agent SDK) is built for long interactive agent sessions inside editors. For a one-shot "image in → JSON out" call it adds a Node server and a protocol layer for nothing; headless `claude -p` is the supported, simpler path to the same subscription.
   - **Policy:** fine — Anthropic's terms allow an end user to run the unmodified Claude Code binary with their own subscription; what's prohibited is third-party products offering Claude login to *other* users. VGN is personal, so this engine is simply "requires Claude Code installed and logged in".
   - Practicalities: GUI apps don't inherit the shell `PATH`, so Settings auto-detects the binary (`zsh -lc 'command -v claude'`) with a manual override; needs App Sandbox off (§3); ~10–30 s per photo, shown as a progress row per tile; `--max-turns 3` because reading the file is itself a tool turn. A `ClaudeAPIRecognizer` (API key) can be added behind the same protocol if ever needed.
3. **Apple Vision** `RecognizeTextRequest` on both 90° rotations: offline fallback, and extracts spine **product codes** (`CUSA 00194`, `PPSA 04609`, `BLES 01402`) — an exact title+region key when a serial database has it; used as a confidence booster.
4. Each candidate → IGDB search constrained by platform → fuzzy score → best match + alternatives.
5. **Review sheet** (nothing is added blindly): photo on the left, detected list on the right; per row: matched cover, confidence, alternatives menu, include checkbox, played toggle (`space`). Defaults: owned ✓ (it's on my shelf), physical, platform from spine. Duplicates already in the library are greyed out. One "Add 37 games" button → single DB transaction.

### 6.3 PSN import
Sync → staging table → review sheet grouped as *New / Already matched / Ignored*. Has trophies ⇒ played (that's all trophies are used for); purchased ⇒ owned digital; game list ⇒ playtime + last played. Matches are remembered, so re-sync only surfaces new titles and refreshes playtime. Noise (apps, demos, betas, PS Plus claims never launched) is one keystroke to ignore, remembered forever.

### 6.4 Playtime
- **Average:** IGDB hastily / normally / completely shown in the inspector ("Main ≈ 32 h · Completionist ≈ 61 h").
- **Mine:** manual field (type `45h`, `45:30`, `2d`) — or PSN-sourced for PS4/PS5. Manual value wins over PSN when both exist; both are kept.
- Shown as a "me vs. average" bar; sortable/filterable; feeds a stats view (total hours, by platform/decade/tier).

---

## 7. Ranking — recommendation

### The model: one list, tiers are dividers in it
There is a single total order of played games. Tiers S/A/B/C/D/F are **contiguous slices** of that order (all S above all A …). So the two ranking methods are two *resolutions of the same truth* and can never contradict each other:
- global rank = `ORDER BY tier.sort, rank_key`
- moving a game across a divider in the Top list changes its tier; changing its tier moves it in the Top.

### Coarse: tiers — 1 keystroke, anywhere
Select game(s) in any view → press `S` `A` `B` `C` `D` `F` (`0` clears). Also context menu, inspector, drag onto the tier board. For bulk backfill there's **Triage mode**: one big cover at a time, press a letter, next — ~2 s per game.

### Fine: binary-insertion duels, inside the tier
To place game X in tier A (say 60 games already ordered): "X or Y?" against the middle game, then the middle of the remaining half… **⌈log₂ n⌉ ≈ 6 duels** and X has its exact spot. Tier first is what keeps this cheap: you never compare a masterpiece against shovelware.

Why this over the alternatives:
| Method | Verdict |
|---|---|
| Merge sort (your `*-ranker` pages) | Optimal for a one-shot list, but adding game #301 later means starting over. ✗ incremental |
| Elo / Glicko / Bradley-Terry | Tolerates inconsistent answers and is fun, but needs ~10+ duels *per game* to converge, ranks wobble, and "one spot per game" is only approximate. ✗ effort |
| Pure drag-and-drop | Fine at 30 games, unusable at 800. Kept as an *override*, not the engine. |
| **Tier → binary insertion** | Same total cost as merge sort for the backlog (~n log n), but **every game is fully placed after ≤ 7 answers**, so sessions can stop anytime, and new games slot in forever. ✓ |

Its one weakness — a single wrong answer misplaces a game — is covered by:
- **Drag-reorder** anywhere (board or Top) as a direct override.
- **Re-place** action on any game (re-runs its duels).
- **Refine mode**: duels between *neighbours* in the list, prioritising pairs never compared or compared long ago; a loss swaps them. Includes **border duels** (bottom of S vs top of A) that suggest promotions/demotions.
- Every answer is logged in `comparisons`, so later we can detect contradictions (A>B>C>A) and surface them as "disputes to settle".

Mechanics: `rank_key` is a sparse sortable key per tier (insert = midpoint of neighbours, renumber the tier in one transaction when gaps run out — trivial at this scale). A game with a tier but no key is **unplaced**: shown dimmed at the end of its tier, unnumbered in the Top, and queued for duels. Changing tier clears the key (unless dropped at an exact position).

### Tuning the buckets: movable tier dividers *(added 2026-09-18)*
Because tiers are slices of one ordered list, a tier boundary is just a **position** in that list — so it can be dragged. In The Top (and as a handle between rows on the Tier Board) the S/A, A/B… dividers are draggable: sliding the S/A line down by three turns the top three A games into the bottom three S games, order untouched; sliding it up does the reverse. Live counts while dragging ("S: 7 → 9"), one transaction, one undo step. Only *placed* games move with a divider; unplaced tails stay with their tier. This is how the ultimate Top gets tuned: rank first, decide afterwards how exclusive S should be. A small distribution strip (games per tier) sits above The Top.

### Scores are derived, never typed *(added 2026-09-18)*
A 1–10 score is an **output** of the ranking, not an input (absolute scores drift and cluster; pairwise duels don't). Every placed game gets a score from its tier's band and its position inside the tier: **S 9.0–10 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9**, interpolated linearly from the top of the tier to the bottom (a lone game sits mid-band); unplaced games show their band's midpoint with a "~". Bands are constants in one place (pure, in `VGN/Ranking/`). Shown in the inspector ("9.6 · #4 overall"), in The Top, on the Tier Board tooltip, and in the CSV export; it moves by itself when I re-rank or drag a divider. Never stored.

### The three ranking views
1. **Tier Board** — classic tier-list rows (coloured letter + label, wrapping covers). Drag between rows = change tier; drag within a row = fine order. Unplaced games sit in a dimmed tail with a "Place n games" button.
2. **The Top** — numbered #1…#N list, podium treatment for the top 10, tier dividers inline. **Respects the library filters**, which gives derived charts for free: *Top PS2*, *Top 90s*, *Top RPGs*. Export as image/CSV.
3. **Duel** — two big covers, `←` / `→` pick, `↓` skip, `⌘Z` undo, progress ("Placing Bloodborne · 3 of ~6"). Queue = unplaced games first, then refine pairs. Resumable, state lives in the DB.

---

## 7b. Play Next — recommendation engine

**Question it answers:** *"I have roughly this much time over the next few weeks — what should I play from my library?"* The answer is always a game I own and have **not completed before**.

### Local or external? — local computation, external *facts*
- **The engine itself is 100 % local**: a pure, deterministic Swift module (`VGN/Recommendation/`, Foundation only, like `Ranking/`). Picking a game makes **no network call**, works offline, takes milliseconds, and the same inputs always give the same pick. No ML service, no account, nothing about my taste leaves the Mac.
- **What it knows about each game comes from IGDB**, fetched once by the normal background enrichment job and stored in the local DB: genres, themes, franchise / series, developer, game modes, player perspective, `similar_games`, aggregated rating (+ count), and time-to-beat. My taste comes **only from my own tiers and ranks** (§7). So: *external facts about games, local judgement about me*.
- Consequence: a game with no IGDB match (manual entry, obscure ROM) has no traits — it can still be recommended on time fit alone, and is labelled "no metadata" instead of being silently ranked last.

### Inputs
- **Time commitment bracket** (one click): *An evening* (≤ 5 h) · *A week or two* (5–15 h) · *A month* (15–40 h) · *A long haul* (40 h+). Optional precise mode: hours per week × weeks → a budget. A *completionist* toggle switches the estimate from IGDB `normally` to `completely`.
- **Taste profile** from my rankings: every ranked game gets a score in 0…1 from its global position (percentile), tiered-but-unplaced games get their tier's midpoint. The ranking work *is* the training data — nothing is asked twice.

### Candidates
Owned games (any format, incl. ROMs and compilation members) whose status is not *finished* / *completed*: the backlog (owned, unplayed), games marked *playing* (remaining time = estimate − my playtime) and, opt-in, *abandoned* ones ("give it another go?"). Played games with no status are excluded by default (toggle) — "played" may well mean "finished". Games with no time estimate go to a separate **"unknown length"** lane rather than being guessed at.

### How a pick is made
1. **Filter by time.** Keep candidates whose estimate (or remaining time) fits the bracket; smooth falloff just outside it, hard exclusion beyond ~1.5× the upper bound. At my library size this step does most of the work: ~50 candidates become a **shortlist of roughly 5–15**.
2. **Score the shortlist for taste** — three signals, blended:
   - **Trait affinities.** For each trait value (genre, theme, franchise, developer, mode, perspective, platform, decade): the average score of my ranked games that have it, *shrunk toward my overall average* (Bayesian average, prior strength ≈ 4 games). With 3 souls-likes all in S, "souls-like" becomes a strong positive; with a single S-tier racing game, "racing" barely moves. Consistently low-ranked traits count *against* a candidate just as strongly. A candidate's affinity = confidence-weighted mean over its traits.
   - **Direct links** (the strongest, most legible signal at small scale): same franchise / sequel of a game in my S–A tiers; listed in IGDB `similar_games` of my top-ranked games (this borrows IGDB's crowd-level "people who like X like Y" knowledge, which my 50 rankings could never produce on their own); same developer as a top game. Links to games I ranked D–F subtract.
   - **Crowd prior.** IGDB aggregated rating, weighted by its rating count. Its weight *shrinks as my ranked count grows* — dominant with 10 ranked games, a tie-breaker with 200.
3. **Rotate.** Small freshness term so the same game isn't pitched forever; **Not this one** snoozes a game for a few weeks, **Never** removes it (`rec_feedback`). `R` re-rolls among near-ties.
4. **Explain.** Every suggestion lists the 2–3 contributions that actually drove its score, in plain words — *"Because you ranked Bloodborne S and Dark Souls A · FromSoftware · ≈ 32 h fits 'A month'"* — plus a **match strength** (strong / fair / weak) derived from how much evidence backed the score. A weak match says so.

All weights are constants in one file, unit-tested on synthetic libraries (a souls-like lover gets the unplayed souls-like; a 60 h JRPG never appears in "An evening"; one outlier never crowns a genre).

### Will it work with ~100 games, half of them played? — yes, as a shortlist-ranker, not as a "learning" system
Honest sizing: ~50 ranked games is far too little for anything statistical in the Netflix sense, and the design doesn't pretend otherwise.
- **What works well at this size:** the time filter (needs no taste data at all), direct links (one S-tier game is enough to surface its sequel or its `similar_games`), and genre/theme affinities for my *dominant* tastes — IGDB has ~20 genres and ~20 themes, so 50 ranked games give 5–15 samples for the ones I play most, which is enough with shrinkage.
- **What stays weak:** niche traits with 1–2 samples (shrunk to near-neutral on purpose), developers/franchises I've never touched (only the crowd prior speaks), and fine ordering *within* the shortlist — positions 2 to 5 are close calls, which is why the UI shows a hero pick **plus alternatives with reasons** instead of a single verdict.
- **Why that is still useful:** the real decision is "which of these ~10 games that fit my month?", and the combination *fits the time + resembles what I ranked high + well regarded* orders ten games sensibly even with thin data. The reasons let me overrule it in two seconds.
- **It checks itself:** a built-in **leave-one-out backtest** — hide each ranked game, predict its score from the others, compare with where I actually ranked it (Spearman correlation). Cheap at this size, run on demand; the Play Next view shows the result as "taste model: good / rough / not enough data", and it is how the weights get tuned on my real library rather than on guesses. Under ~15 ranked games the view says so and leans on the crowd prior.
- **It improves for free:** every newly ranked game sharpens the affinities; the crowd prior fades out automatically.

### Second opinion: "Ask Claude" *(decided 2026-09-18 — built, on demand)*
The one thing sparse statistics cannot supply is *knowledge of what the games are actually like* (pacing, tone, difficulty, "plays like…"). An **Ask Claude** button next to the deterministic pick sends the **shortlist only** to the local `claude` CLI — the same headless, subscription-billed mechanism as photo scan (§6.2: no API key, scrubbed environment, binary path from Settings, `--output-format json` + `--json-schema`, no tools allowed since there is nothing to read).
- **Prompt content:** my tier list (titles + tier, top ~60 by rank, plus the D–F tiers as "didn't click"), the 5–15 shortlisted candidates with platform, time estimate and status, the chosen bracket, and the engine's own ordering. Nothing else leaves the app; no library dump.
- **Response (structured):** an ordered pick of up to 5 candidate ids, each with a 1–2 sentence reason and an optional caveat ("slow first 10 hours", "needs the first game"). Ids outside the shortlist are discarded — Claude can re-rank, never add.
- **UI:** the deterministic result shows instantly; the second opinion streams in beside it as a separate column ("Engine" vs "Claude"), agreement between the two is highlighted. ~10–20 s, cancellable, cached per (shortlist, bracket) for the session.
- **Boundaries:** never the default path, never automatic, non-deterministic by nature; if the CLI is missing, logged out or times out, the button explains why and the engine's pick stands. Behind a `SecondOpinionProviding` protocol so tests use a stub and an API-key variant stays a drop-in.

### UI
Sidebar entry **Play Next** (LIBRARY section). Bracket picker on top; one **hero pick** (big cover, estimate-vs-bracket bar, the platform/format I own it on, reasons, match strength) + up to 4 alternatives + the "unknown length" lane. Actions: **Start playing** (status = playing), **Not this one**, **Never**, open in inspector.

---

## 8. Main UI

```
┌ Sidebar ────────────┬ Toolbar: [search] [Genre▾] [Decade▾] [Tier▾] [Status▾] [sort▾] [size ─o─] [+] ┐
│ LIBRARY             │                                                                              │
│  All          812   │   ▢ ▢ ▢ ▢ ▢ ▢ ▢     LazyVGrid of game boxes                                   │
│  Owned        540   │   ▢ ▢ ▢ ▢ ▢ ▢ ▢     box art · title · tier chip · owned/played badges ·       │
│  Played       655   │   ▢ ▢ ▢ ▢ ▢ ▢ ▢     compilation marker                                         │
│  Backlog      157   │                                                         ┌ Inspector (⌘I) ───┐ │
│  Unranked      43   │                                                         │ cover, metadata,  │ │
│  Play Next          │                                                                              │
│ RANKINGS            │                                                         │ owned copies,     │ │
│  Tier Board         │                                                         │ played, tier/rank,│ │
│  The Top            │                                                         │ playtime vs avg   │ │
│  Duel          12   │                                                         └───────────────────┘ │
│ PLATFORMS           │                                                                              │
│  Sony ▸ PS5 PS4 PS3…│                                                                              │
│  Nintendo ▸ …       │                                                                              │
│  Computer ▸ PC Mac… │                                                                              │
└─────────────────────┴──────────────────────────────────────────────────────────────────────────────┘
```
- Sidebar platforms grouped by manufacturer, only platforms with ≥ 1 game, live counts (one observed aggregate query). Selecting a platform scopes grid, search, filters, Top *and* Quick Add's default platform.
- Search = FTS5 prefix match on title + alt titles (finds "Baphomet" → *Broken Sword*), results as you type.
- Filters combine (AND across kinds, OR within a kind), compile to one SQL query, shown as removable chips. Ownership **format** (physical / digital / ROM) is a filter kind too, and ROM copies carry a small badge in the grid.
- Compilation members appear individually in the grid with a small stack marker; the inspector shows "Part of *Metal Gear Solid: The Legacy Collection* (PS3)" and toggling ownership there applies to the whole product, listing affected games.
- Multi-select + keyboard everywhere: `S`…`F` tier, `O`/`P` toggle owned/played, `⌘I` inspector, `⌘F` search, `⌘N` quick add, `space` Quick Look-style big cover.

---

## 9. Performance & concurrency

- **Swift 6 strict concurrency.** UI state in `@MainActor @Observable` stores; all I/O in actors (`IGDBClient`, `CoverStore`, `PSNClient`, `RateLimiter`); parallel work via `TaskGroup` with bounded width.
- **DB:** `DatabasePool` (WAL → reads never block writes). Views subscribe through GRDB `ValueObservation` as `AsyncSequence` → the grid updates itself after any import, no manual refresh. Grid query returns a slim row struct (id, title, cover file, tier, flags), not full records. Indices on platform, tier+rank_key, decade, played; FTS5 for text.
- **Images:** `CoverStore` actor — disk originals + thumbnails pre-downsampled with `CGImageSourceCreateThumbnailAtIndex` at the cell's pixel size (never decode a 1000 px cover for a 160 pt cell), `NSCache` with cost limit, in-flight request de-duplication, ≤ 6 concurrent downloads, cancel on cell disappear, prefetch just beyond the viewport. Fixed-size cells so `LazyVGrid` never measures content.
- **Per-cell invalidation:** each cell observes its own small `@Observable` box (romlord's fix: "a tick re-renders one cell, not the grid"), so a cover arriving or a tier change never re-diffs 1 000 cells.
- **Escape hatch:** romlord ran `LazyVGrid` fine to 5–10 k cells; if it ever stutters, swap in an `NSCollectionView` wrapper behind the same view-model (contained change).
- **Never block on network:** inserts are local and instant; enrichment (metadata, cover, time-to-beat) is a background job queue persisted in the DB, resumes after relaunch, retries with backoff.
- **Safety:** automatic DB snapshot on launch (keep last 10), JSON/CSV export — this library will represent years of curation.

---

## 10. Milestones

Each ends with a runnable app and a commit/push.

| # | Milestone | Contents | Done when |
|---|---|---|---|
| 0 | **Bootstrap** | *(after Xcode is installed)* git init + remote, `VGN.xcodeproj` (app + test targets, synchronised folders, GRDB package, sandbox off), app shell (split view), GRDB + migrations v1, `platforms.json` seed, CLAUDE.md, `.gitignore` (sample originals) + downsized JPEG fixtures, Settings with Keychain-backed credentials | `xcodebuild build` + `test` green from the CLI; app launches to an empty library; first push |
| 1 | **Library core** | IGDB client, Quick Add, background enrichment queue, CoverStore + provider chain, grid, sidebar + counts, inspector, owned/played logic & invariants | 50 games added by keyboard in < 5 min, covers appear, relaunch is instant |
| 2 | **Find things** | FTS search, genre/decade/tier/status filters, sorts, grid size slider, multi-select actions | Any game reachable in < 3 s at 1 000 games |
| 3 | **Compilations** | Product model UI, bundle prefill from IGDB, compilation editor, all-or-nothing ownership UX | *MGS Legacy Collection* / *ICO & SotC HD* behave correctly |
| 4 | **Ranking** | Tier keys + Triage, RankingEngine (+ exhaustive tests), Duel, Tier Board with drag, The Top with filters, Refine + border duels, comparison log | New game → tier → 6 duels → correct slot in both views |
| 5 | **Playtime** | IGDB time-to-beat, manual playtime + status, me-vs-average UI, (optional HLTB provider) | Inspector shows averages for matched games |
| 5b | **Play Next + ROM format** | `format = rom` end to end (schema, Quick Add `⌘D`, inspector, badge, filter); `game_traits` + IGDB rating enrichment; `RecommendationEngine` (+ tests on synthetic libraries); Play Next view with brackets, reasons, snooze/never, Start playing; "Ask Claude" second opinion on the shortlist | With ≥ 15 ranked games, each bracket proposes a sensible unfinished game with a reason I agree with |
| 6 | **Photo scan** | Tiling, Claude recogniser, Vision fallback + serial extraction, matching, review sheet | The 6 sample photos import with ≥ 90 % correct pre-matches |
| 7 | **PSN import** | Web login, token store, `LibraryImporter` protocol + shared review sheet, played list (from trophies) / game list / purchased, playtime, re-sync | Full PSN history imported; second sync shows only deltas |
| 8 | **GOG import** | Second `LibraryImporter`: web login, owned list → review sheet | GOG library imported as owned PC/Mac games |
| 9 | **Polish** | Liquid Glass touches under `#available(macOS 26)`, stats view, Top export as image, backups, app icon, empty states | — |

Order rationale: 0–4 deliver the whole core loop (add → browse → rank) with manual entry only; 5–8 are independent accelerators and can be reordered freely (e.g. PSN before photos).

---

## 11. Risks

- **PSN & HLTB are unofficial** → isolated, optional, fixture-tested, fail soft.
- **Spine recognition quality** (steelbooks without text, glare) → review sheet is mandatory; unmatched items fall through to Quick Add prefilled with the guessed text.
- **IGDB bundle data gaps** → manual compilation editor from day one.
- **`claude` CLI as a dependency of photo scan** → flags/behaviour can change between Claude Code versions; the recogniser checks `claude --version`, fails soft to on-device OCR, and the engine sits behind a protocol (API-key variant is a drop-in).
- **Title matching across regions/languages** (French box titles) → match on IGDB `alternative_names` + localised names, normalisation (diacritics, ™/®, roman numerals, subtitles).

## 12. Decisions log (settled 2026-09-18)

| Question | Decision |
|---|---|
| Game identity | One ranked **Game**, many owned **Products** (Elden Ring PS4 + PS5 = one rank slot). Remasters/remakes are separate Games. |
| Photo-scan engine | Local **`claude` CLI headless**, subscription-billed (not ACP, not an API key). On-device Vision OCR as fallback. |
| Tier scale | **S A B C D F** — labels/colours editable later. |
| Completion status | **Yes, optional**: Playing / Finished / 100 % / Abandoned. Filterable, never required. |
| Trophies | Only a "played" signal for PSN import (key for PS3). No trophy data stored or displayed. |
| Project type | **Plain Xcode project**, folder-synchronised groups, single app target. |
| Computers | One **Mac** platform, one **PC**, plus distinct retro computers. |
| Other importers | **GOG** later; Steam / Xbox / Nintendo not planned. |
| Sample photos | Originals git-ignored; **downsized JPEG fixtures committed**. |
| Persistence | GRDB stays even with Xcode available (see §1). |
| ROMs *(added 2026-09-18)* | Third ownership format next to physical/digital. Manual entry only for now — no romlord/emulator import. |
| 1–10 scores *(decided 2026-09-18)* | Not an input. Tiers + duels stay the way rankings are entered; a 1–10 score is **derived** from tier band + position, and tier **dividers are draggable** to tune bucket sizes (§7). |
| Recommendations *(added 2026-09-18)* | **Play Next** (§7b): local, explainable, driven by my own rankings + a time bracket; only suggests owned, not-yet-completed games. Built as milestone 5b. **\"Ask Claude\" second opinion: yes** — on-demand re-ranking of the shortlist through the local `claude` CLI, never the default path. |

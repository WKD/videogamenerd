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
- **Reconciling unlinked games** *(2026-09-19)*: an import can validate a match with no IGDB entry (weird editions, French/localised titles), leaving a game with `igdb_id IS NULL` — no metadata, cover, time-to-beat or traits, invisible to the `igdb_id` dedupe (a later photo scan / PSN / GOG import duplicates it). A sidebar **Unlinked** smart list (shown only when > 0, §8) collects them; the inspector shows a "not linked" notice. **Link to IGDB…** / **Change IGDB Match…** (inspector, grid context menu, File menu) opens a search sheet prefilled with a cleaned query (the owner edits it to the English title), reusing the Quick Add autocomplete (platform toggle, typed-year + alt-name fallbacks); each result is marked when a library game already holds it. Linking sets `igdb_id`, adopts the IGDB title (pushing the old title into `alt_titles` so search still finds it) unless the title was hand-edited, and enqueues the normal enrichment; re-linking also clears the stale non-user-edited metadata. If the chosen IGDB game is already in the library the two **merge** into one (platform-agnostic game): copies are kept when they differ in platform/format (or are digital copies from different stores), collapsed when the same platform+format physical copy is catalogued twice (with an "I really own two copies" override), and the target's played/status/playtime/tier win; duel history, feedback, traits and importer links re-point, and the emptied game is deleted. Every link/merge/relink is one transaction and fully undoable. The import review sheet warns on a ticked row with no match and offers an inline **Find…**. *(2026-09-20)* A chosen IGDB result that is itself a **bundle/pack** is no longer refused — it **expands**: the members are fetched on demand (reverse lookup, §5.1) and a confirm step shows them ("Expand into N Games"); the game's product(s) become a `compilation` titled with the bundle name, members are upserted/deduped as games (an existing member is linked, never duplicated), and the placeholder is deleted after re-pointing — unless it carries play data (played/status/tier/rank/playtime), which is moved to a chosen member first (default the first, respecting "only played games carry a tier/rank"). This is how a wrongly-single bundle like *Evolution Worlds* gets imported. The same store method backs an **"Expand Bundle into Games…"** repair action (inspector / File menu) on any library game linked to an IGDB bundle; it verifies against IGDB on click and no-ops with a note when the entry is not a bundle (e.g. *The Dark Pictures Anthology: House of Ashes* is a single game). Fully undoable. *(2026-09-20, wave 16)* A **Bundles to Expand** list surfaces every library game whose title looks like an unexpanded bundle (`bundleExpansionCandidates()`, the Trilogy/Collection/Pack heuristic) so they can be found without hunting; a game that turns out not to be a bundle on the on-demand IGDB check is **dismissed for good** (persisted in `app_state`, `reconcile.notBundle`) and leaves the list. IGDB is queried only on click, never in bulk.

### 5.2 Box art
`CoverProvider` protocol, tried in order, first good hit wins; all candidates remain browsable:
1. **libretro-thumbnails** (romlord's source — free, no key, real per-platform box scans, covers everything retro up to roughly PS3/Vita/Wii U/3DS): `raw.githubusercontent.com/libretro-thumbnails/{repo}/master/Named_Boxarts/{name}.png`. Reuse romlord's `LibretroRepoMapping.plist` and repo-name rules. Difference from romlord: it had exact No-Intro/Redump names from DATs; VGN only has an IGDB title. So per platform we fetch the repo's file listing **once** (GitHub tree API, cached), index it locally, and fuzzy-match title + preferred region (Europe/France first, then USA, Japan), reusing romlord's tag-stripping ladder (`(En,Fr)`, `(Disc 1)`, edition tags) in reverse.
2. **IGDB cover** (`images.igdb.com/…/t_cover_big_2x/{image_id}.jpg`) — always available, the answer for PS4/PS5/Switch/PC where libretro has nothing. Platform-agnostic key art.
3. *(Optional, later)* TheGamesDB — API key, per-platform/region front box art for modern platforms, if IGDB art looks too inconsistent next to real boxes.
4. Manual: "Choose cover…" sheet showing every candidate from every provider, or drag any image onto the game.

Tiles are a fixed 3:4 (romlord's cell); box shapes vary wildly by platform (SNES landscape, PS1 square, DVD-tall), so art is aspect-*fit* on a neutral backing rather than cropped. Misses write a negative-cache sentinel (7-day TTL) so the grid never re-hits the network on every render.

Covers are **library assets, not cache**: stored permanently in `~/Library/Application Support/VGN/covers/`, plus pre-downsampled grid thumbnails (§8).

### 5.3 HowLongToBeat
No official API. Every wrapper scrapes an internal search endpoint whose path/key rotates and breaks regularly. IGDB time-to-beat stays the default, and the inspector always has an "Open on HowLongToBeat" link; values are editable by hand either way.

**HLTB fallback fetch** *(decided 2026-09-19 — measured on my library: IGDB has an estimate for 231 of 376 games; the 145 without one are invisible to Play Next's time fit)*. HLTB fills **only the gaps**, on demand:
- **Triggers**: inspector ▸ "Fetch from HowLongToBeat" for one game (with a picker when the match is not obvious), and Game ▸ **"Fetch Missing Time Estimates…"** for the selection or the whole library (progress, cancel, summary "n filled · m not found · k ambiguous"). Never automatic, never at launch.
- **Matching**: `TitleNormalizer` + `FuzzyMatch` on name and aliases, release year ± 1 as the tie-breaker. Bulk mode only accepts confident matches; ambiguous ones are listed for a one-by-one pick.
- **Mapping**: HLTB *Main* → `ttb_hastily_s`, *Main + Extra* → `ttb_normally_s`, *Completionist* → `ttb_completely_s`, `ttb_source = 'hltb'`. Only empty fields are filled (an IGDB or hand-typed value is never overwritten, `user_edited` respected); the HLTB game id is kept so the "Open on HowLongToBeat" link goes straight to the page.
- **Politeness and frailty**: a public site with no account at stake, so no ban risk to my data — but the same machinery as the importers: URL allow-list, serial requests ≥ 1.5 s apart, a budget per run, results cached (hits 180 days, "not found" 30 days) in the shared `import_cache` (`source = 'hltb'`), and **stop on the first unexpected response** (HTML, captcha, 403/429, schema mismatch) with a clear message — no retries, no variants. The request shape (key/token discovery included) is ported from a maintained open-source client pinned to a commit, isolated in one file, so that when HLTB changes it again there is exactly one place to fix. If it breaks for good the feature degrades to the link, nothing else is affected.
- **Finding the gaps**: the Playtime filter gets a **"No Estimate"** entry (games with no time-to-beat at all).

### 5.4 PlayStation Network (unofficial)
- Auth: in-app web login → read `npsso` cookie → exchange for access code → access + refresh tokens (Keychain). Paste-NPSSO fallback.
- **Trophy titles** `m.np.playstation.com/api/trophy/v1/users/me/trophyTitles` (paged, max 800; PS3/Vita included with `npServiceName=trophy`) → used **only as a "played" signal**: a title with ≥ 1 earned trophy = a game I played. This is the one way to recover PS3/Vita history. We keep title, platform and last-activity date; trophy counts/details are discarded and never shown. (Caveat: pre-2008 PS3 games and a few others have no trophies, so they won't appear — manual/photo add covers those.)
- **Game list** `…/api/gamelist/v2/users/me/titles` → **play duration**, play count, first/last played. **PS4/PS5 only** — Sony doesn't expose PS3/Vita playtime.
- **Purchased list** (web GraphQL `getPurchasedGameList`) → *Owned (digital)*; PS Plus claims are imported too, **flagged as subscription copies** (they vanish when the subscription ends — §13.3).
- Risk: unofficial, can break or change; ToS grey zone for personal use. Hence: isolated module, fixtures-based tests, never blocks the rest of the app.
- **Detailed design, caching rules and the build protocol: §13.**

### 5.5 Other libraries (later)
All importers implement one `LibraryImporter` protocol (authenticate → fetch → emit `import_titles` rows → shared review sheet), so adding a source never touches the core.
- **GOG** (wanted): unofficial but long-stable account API (`embed.gog.com/user/data/games` + `account/gameDetails`), web login like PSN → *Owned (digital)*, PC/Mac. No play time.
- **Delicious Library 2** (done, the first *file* importer): reads an old `.deliciouslibrary2` Core Data SQLite catalogue **read-only + immutable** (never the store's private movies/books/music), resolving the `Medium` entity by name and reading only `ZTYPE = 'VideoGame'` rows → *Owned (physical)*, one copy each. `authenticate` is a no-op and there is no network/cache/budget; it still runs through the shared coordinator (staging → matching → review → commit). Platform labels map to VGN slugs (Windows→pc, Mac→mac, a PC/Mac hybrid disc follows the same policy switch GOG uses, consoles keep their slug); titles are cleaned for **matching only** (platform/media/edition/bundle noise stripped, the edition extracted onto the copy) while the noisy original is kept and shown; release year is the IGDB tie-breaker; `ZCREATIONDATE` becomes the acquired date and the store's box-art JPEG fills a game left without a cover (not marked user-chosen, so enrichment may still upgrade it). Because the owner catalogued his shelf by photo scan, a row whose match already owns the same physical copy on the same platform is dropped as a duplicate. Re-import is idempotent on `(source='delicious', external_id=ZUUIDSTRING)`. *(2026-09-20)* A row whose IGDB match is a **bundle/pack** ("The Tomb Raider Trilogy", "God of War Collection") is expanded during matching (§5.1 reverse lookup, on the shared IGDB client) and committed as a **compilation** Product whose members are the individual games — each deduped against the library; an empty member list falls back to a single and flags the row, never blocking the import. Same for GOG (§14.2).
- Steam / Xbox / Nintendo: not planned. The protocol leaves the door open.

### 5.6 Platforms
Data-driven `platforms.json`, grouped by manufacturer in the sidebar: Sony, Nintendo, Sega, Microsoft, Atari, NEC, SNK…, **Computers** = one **Mac** platform (classic Mac OS + macOS together), one **PC** (DOS + Windows), plus distinct retro machines as needed (Amiga, Atari ST, Amstrad CPC, C64, Apple II…), and Arcade. Each maps to IGDB platform id(s) and, where one exists, a libretro-thumbnails repo.

---

## 6. Adding games

### 6.1 Quick Add (⌘N) — the fast path
Spotlight-style palette, keyboard only:
1. Type 3+ letters → results stream in (a **year in the query disambiguates long series**: "super mario bros 1985" asks IGDB for entries released that year — any region/platform — and lists them first; local and cached rows are narrowed the same way; titles that merely contain a number, "Cyberpunk 2077", still work) (local library + catalog cache instantly, IGDB ~200 ms later; 150 ms debounce, previous request cancelled). Rows: cover, title, year, platform chips. Already-in-library rows are marked.
2. `↑↓` select · `Tab` cycles platform (defaults to the sidebar's current platform, else the game's most likely one) · `⌘O` owned / `⌘P` played (sticky from last add) · copy format **physical / digital / ROM**: an always-visible three-way picker in the footer (clickable), `⌘1` `⌘2` `⌘3` pick it directly, `⌘D` cycles it; picking a format switches Owned on (sticky too) · optional `S A B C D` sets the tier right away.
3. `↩` adds; the field clears and **stays open** for the next game. `⇧↩` adds but **keeps the query and the result list** and steps to the next row — for entering a whole series ("yakuza" → `⇧↩ ⇧↩ ⇧↩`). `⌘↩` adds and opens the inspector. `esc` closes.
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
*(Detailed plan: §13.)* Sync → staging table → review sheet grouped as *New / Already matched / Ignored*. Has trophies ⇒ played (that's all trophies are used for); purchased ⇒ owned digital; game list ⇒ playtime + last played. Matches are remembered, so re-sync only surfaces new titles and refreshes playtime. Noise (apps, demos, betas, PS Plus claims never launched (still listed, under *Ignored*, restorable)) is one keystroke to ignore, remembered forever.

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
Select game(s) → press the tier letter (`0` clears): plain `S` `A` `B` `C` `D` `F` on the Tier Board and in Triage; **`⇧S`…`⇧F` in the library grid**, where plain letters are type-to-select *(decided 2026-09-19)*; `⌃S`…`⌃F` in Quick Add. Also context menu, inspector, drag onto the tier board. For bulk backfill there's **Triage mode**: one big cover at a time, press a letter, next — ~2 s per game.

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
- **Time commitment bracket** (one click) *(2026-09-19: the brackets are the five "By Length" shelves so a bracket and its sidebar shelf cover the same hours)*: *One Evening* · *A Weekend* · *A Few Weeks* · *A Season* · *Epics*. Their hour ranges are **not fixed** — they derive from the same weekly **play pace** the sidebar uses (§8), so at 8 h/week the edges are 4 / 10 / 40 / 80 h; "One Evening" is open below and "Epics" open above. The selected bracket's range is shown as a caption ("A Few Weeks · 10–40 h at 8 h a week"). Optional precise mode: hours per week × weeks → a budget (its hours/week pre-filled from the pace). Each candidate's estimate is its **personal length** at my play style (§8), so the reason reads "≈ 52 h for you"; a *Plan for 100%* toggle overrides it to completionist (t = 1) for the session (shown on and disabled when my style is already Completionist). Opening Play Next straight from a BY LENGTH sidebar shelf preselects the matching bracket.
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

All weights are constants in one file, unit-tested on synthetic libraries (a souls-like lover gets the unplayed souls-like; a 60 h JRPG never appears in "One Evening"; one outlier never crowns a genre).

### Will it work with ~100 games, half of them played? — yes, as a shortlist-ranker, not as a "learning" system
Honest sizing: ~50 ranked games is far too little for anything statistical in the Netflix sense, and the design doesn't pretend otherwise.
- **What works well at this size:** the time filter (needs no taste data at all), direct links (one S-tier game is enough to surface its sequel or its `similar_games`), and genre/theme affinities for my *dominant* tastes — IGDB has ~20 genres and ~20 themes, so 50 ranked games give 5–15 samples for the ones I play most, which is enough with shrinkage.
- **What stays weak:** niche traits with 1–2 samples (shrunk to near-neutral on purpose), developers/franchises I've never touched (only the crowd prior speaks), and fine ordering *within* the shortlist — positions 2 to 5 are close calls, which is why the UI shows a hero pick **plus alternatives with reasons** instead of a single verdict.
- **Why that is still useful:** the real decision is "which of these ~10 games that fit my month?", and the combination *fits the time + resembles what I ranked high + well regarded* orders ten games sensibly even with thin data. The reasons let me overrule it in two seconds.
- **It checks itself:** a built-in **leave-one-out backtest** — hide each ranked game, predict its score from the others, compare with where I actually ranked it (Spearman correlation). Cheap at this size, run on demand; the Play Next view shows the result as "taste model: good / rough / not enough data", and it is how the weights get tuned on my real library rather than on guesses. Under ~15 ranked games the view says so and leans on the crowd prior.
- **It improves for free:** every newly ranked game sharpens the affinities; the crowd prior fades out automatically.

### Ideas filed for later *(owner, 2026-09-19 — not scheduled)*
- **Personal pace factor — inflate the advertised times.** I usually take longer than IGDB / HowLongToBeat say. Instead of a fixed fudge, *measure* it: for every game I finished that has both my playtime and an estimate, take the ratio mine ÷ advertised; the **median** of those ratios (clamped to 0.8–2.0, shown in Settings with the number of games it rests on, overridable by hand, 1.0 until there are ≥ 5 such games) multiplies every estimate wherever time is used *for planning*: Play Next's time fit, the BY LENGTH shelves, "backlog in hours" in Stats. The raw estimate stays what is stored and displayed (the inspector shows both: "≈ 38 h for you · 30 h advertised"). Could later be refined per genre or per length band (long RPGs drift more than short games). Needs playtime data first — i.e. after the PSN import (§13).
- **"Finish what you started" in Play Next.** Two extra candidate pools, shown as their own row above or beside the regular picks rather than mixed into them:
  - *Almost there* — played, not finished/100 %, with my playtime ≥ ~70 % of the (pace-adjusted) estimate: the remaining time = estimate − my playtime is what gets fitted to the chosen time bracket, and the reason reads "about 4 h left". Status *Playing* counts; *Abandoned* counts too, with a gentler nudge.
  - *Worth another try* — abandoned early (playtime < ~25 % of the estimate) but whose traits score high against my taste profile, or that sit in a franchise I ranked S/A since: "you dropped it after 3 h — you loved its sequel".
  Today Play Next only considers never-completed games by status and ignores my playtime; both pools need playtime per game (PSN import or hand-entered) and should respect the existing snooze / "not interested" feedback so a nudge never nags. Weighting must be backtestable like the rest (§7b), and the pools are hidden until enough playtime data exists.

- **"Play it again" — replay suggestions** *(owner, 2026-09-19)*. A third extra pool in Play Next: games I already **finished** that are worth revisiting, shown as their own row ("Worth replaying"), never mixed into the backlog picks. Two things decide whether this is worth building:
  - *A replay-value score, so low-replay games do not keep coming back.* No public source publishes one (IGDB, HowLongToBeat and Metacritic have no such field), so it has to be inferred, from signals the app already has or can get cheaply: **my own tier** (S/A only — I replay what I loved); **genre / keyword priors** (roguelikes, arcade, fighting, racing, sandbox, strategy, platformers and "New Game Plus / multiple endings / procedurally generated" keywords score high; linear narrative adventures, visual novels and puzzle games whose solution I know score low); **length** (a 6 h game is an easy revisit, a 100 h RPG is a commitment — fitted to the chosen time bracket like any other pick, using the *main* time rather than my completionist-leaning personal length); the **completionist ÷ main ratio** (a large ratio means content I probably left behind); an available **remaster / remake / definitive edition I own or that exists** (IGDB `remakes` / `remasters` / `expanded_games` links) as an explicit reason ("you finished the PS3 version in 2012 — you own the remaster"); and, if I use it, "Ask Claude" as the taste judge over a short list. The score must be backtestable like the rest of §7b, and one "not interested" on a replay suggestion retires that game for a long time (a year), not the usual three weeks.
  - *Knowing when I last played it, without me typing it.* Replay only makes sense after a long gap (years), so the pool needs a trustworthy "last played": **PSN supplies it** — `lastPlayedDateTime` per title in the game list (PS4/PS5) and the last trophy date (`lastUpdatedDateTime`) for PS3/Vita — and both are already kept by the PSN import (§13.3). For everything else the app only has weak proxies (the date I marked it finished *in VGN*, the date a copy was acquired, the release year). **Decision rule: build this only if, after the PSN import, a useful share of my finished games (say ≥ 60 %) has a machine-known last-played date; games without one are simply not eligible. If it would depend on me maintaining "last played" by hand, leave the feature out.** Until then nothing is scheduled.

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
│ BY LENGTH  8h/week▸ │                                                                              │
│  🌙 One Evening  12 │   under 4 h · A Weekend 4–10 h · A Few Weeks 10–40 h · A Season 40–80 h ·     │
│  📖 Epics       205 │   Epics 80 h+ · (Unmeasured, shown only when > 0)                             │
│ BATOCERA            │   (shown only when the ROM catalogue is non-empty — §15)                     │
│  ROM Catalogue 11k  │                                                                              │
│ PLATFORMS           │                                                                              │
│  Sony ▸ PS5 PS4 PS3…│                                                                              │
│  Nintendo ▸ …       │                                                                              │
│  Computer ▸ PC Mac… │                                                                              │
└─────────────────────┴──────────────────────────────────────────────────────────────────────────────┘
```
- Sidebar platforms grouped by manufacturer, only platforms with ≥ 1 game, live counts (one observed aggregate query). Selecting a platform scopes grid, search, filters, Top *and* Quick Add's default platform.
- LIBRARY also carries an **Unlinked** row *(2026-09-19)* — games with no IGDB link (`igdb_id IS NULL`), shown **only when its count > 0** (like "Unmeasured"), counted by the same single aggregate query. It is the entry point for reconciling them (§5.1).
- Search = FTS5 prefix match on title + alt titles (finds "Baphomet" → *Broken Sword*), results as you type.
- Filters combine (AND across kinds, OR within a kind), compile to one SQL query, shown as removable chips. **Playtime bands** *(2026-09-19)*: < 4 h · 4–10 h · 10–40 h · 40–60 h · 60–80 h · 80–100 h · 100–150 h · 150–200 h · > 200 h, plus "No Estimate" — this filter buckets **effective playtime** first (falling back to the game's **personal length** — see BY LENGTH below — only when unplayed). Ownership **format** (physical / digital / ROM) is a filter kind too, and ROM copies carry a small badge in the grid. The **Format ▾** menu also carries **"Multiple Copies"** *(2026-09-19 — folded in from a separate Copies menu to save toolbar space)* — its own facet that narrows to games owned in more than one copy/format (≥ 2 owned products) and **ANDs** with a chosen format ("Physical" + "Multiple Copies" = a game with a physical copy that is owned several times).
- **BATOCERA ▸ ROM Catalogue** *(§15, wave 13)* — a sidebar section after BY LENGTH and before PLATFORMS, **shown only when the ROM catalogue is non-empty**. It routes to a **separate** browser (`RomCatalogueView`), never the grid, and its count comes from a **separate** `rom_catalog` observation, so the catalogue is invisible to every library count, stat, ranking and export (a 10 000-row test proves it).
- **BY LENGTH shelves** *(2026-09-19)* — a sidebar section after RANKINGS: five literary smart lists (One Evening · A Weekend · A Few Weeks · A Season · Epics) grouping games by **how long the game is *for me*** — its **personal length**, never my own playtime (a 100-hour RPG dropped after 2 h is still an epic — deliberately different from the Playtime *filter*). **Personal length** *(2026-09-19)* blends the *main-story* (`ttb_normally_s`) and *completionist* (`ttb_completely_s`) estimates by a **play style** (`normally + t·(completely − normally)`, missing side inflated by a constant ratio R = 1.5, `completely < normally` clamped up): *Story first* (t = 0) · *Some side quests* (0.25) · *Lots of side quests* (0.5, the default — I do a lot of side quests) · *Completionist* (1). The **rushed** time (`ttb_hastily_s`) is **never** used — a game whose only estimate is rushed is *Unmeasured* (so the HLTB fetch fills it). One SQL expression (in `LibraryQuery`, taking t and R as arguments) computes it everywhere length is asked: the shelves + Unmeasured, the Length sort, Play Next's time fit, and the Playtime filter's unplayed fallback; a pure Swift mirror (`PersonalLength`) agrees with it (parity-tested). A sixth "Unmeasured" row (no personal length) appears only when it has games and is the entry point to fetch missing time estimates. Empty shelves stay visible but dimmed; counts come from the one observed aggregate query. The shelf hour edges are **not fixed constants**: they derive from a **weekly play pace** setting ("how much I can play in a week", 1–60 h, default 8) — at 8 h/week the edges are 4/10/40/80; at 2 h/week "a few weeks" is only 10 h. The pace **and** the play style are edited from the section header (a popover with a live preview) and from Settings ▸ General, both bound to the same store; changing either re-runs the grid + counts like a filter change.
- Compilation members appear individually in the grid with a small stack marker; the inspector shows "Part of *Metal Gear Solid: The Legacy Collection* (PS3)" and toggling ownership there applies to the whole product, listing affected games.
- Multi-select + keyboard everywhere. In the grid, **plain letters always type-to-select**; the one-key actions take ⇧: `⇧S`…`⇧F` tier (`0` clears), `⇧O`/`⇧P` toggle owned/played, `⇧M` repeats the last "Mark Played As" value on the selection *(decided 2026-09-19 — before, a letter did one or the other depending on timing)*. **Mark Played As** (context menu + Game menu) marks the selection played with an optional completion status (Played · Playing · Finished · 100% · Abandoned) in one undoable batch; the top-level "Mark as ‹Last›" item repeats the last choice (⇧M). Marking several games owned asks **once for the batch** (format for all; each game's primary platform, ambiguous ones listed). `⌘I` inspector, `⌘F` search, `⌘N` quick add, `space` Quick Look-style big cover.
- **Library Stats** — a separate window (Window ▸ Library Stats, `⌥⌘S`, or "Show All Stats…" in the sidebar stats popover): a scrollable dashboard (Swift Charts) of overview, playtime (total, by platform/decade/tier, top played, me vs. average, backlog to beat), platforms, decades & years, tiers & derived scores, genres, status/completion and a 12-month activity chart, with an All · Owned · Played scope picker *(pulled forward from Polish, 2026-09-19)*.

---

## 9. Performance & concurrency

- **Swift 6 strict concurrency.** UI state in `@MainActor @Observable` stores; all I/O in actors (`IGDBClient`, `CoverStore`, `PSNClient`, `RateLimiter`); parallel work via `TaskGroup` with bounded width.
- **DB:** `DatabasePool` (WAL → reads never block writes). Views subscribe through GRDB `ValueObservation` as `AsyncSequence` → the grid updates itself after any import, no manual refresh. Grid query returns a slim row struct (id, title, cover file, tier, flags), not full records. Indices on platform, tier+rank_key, decade, played; FTS5 for text.
- **Images:** `CoverStore` actor — disk originals + thumbnails pre-downsampled with `CGImageSourceCreateThumbnailAtIndex` at the cell's pixel size (never decode a 1000 px cover for a 160 pt cell), `NSCache` with cost limit, in-flight request de-duplication, ≤ 6 concurrent downloads, cancel on cell disappear, prefetch just beyond the viewport. Fixed-size cells so `LazyVGrid` never measures content.
- **Per-cell invalidation:** each cell observes its own small `@Observable` box (romlord's fix: "a tick re-renders one cell, not the grid"), so a cover arriving or a tier change never re-diffs 1 000 cells.
- **Escape hatch:** romlord ran `LazyVGrid` fine to 5–10 k cells; if it ever stutters, swap in an `NSCollectionView` wrapper behind the same view-model (contained change).
- **Never block on network:** inserts are local and instant; enrichment (metadata, cover, time-to-beat) is a background job queue persisted in the DB, resumes after relaunch, retries with backoff.
- **Safety:** automatic DB snapshot on launch (keep last 10), JSON/CSV export — this library will represent years of curation.
- **Empty / progress / narrow-inspector polish (wave 17):** every "no games / no results" area uses the shared `EmptyStateView` (`VGN/UI/Support/`) with actions wired to existing commands; all four importers share one fixed-width matching-progress modal (`ImportMatchingProgressView`) that never resizes as titles scroll; the inspector reflows its action buttons and playtime table at the minimum column width (300 pt). Play Next cards carry an "Open on IGDB" button (`IGDBWebLink`).

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
| 7 | **PSN import** (§13) | Web login, token store, `LibraryImporter` protocol + shared review sheet, **validated 30-day response cache**, request budget + rate limit, played list (from trophies) / game list / purchased, playtime, re-sync; built in gated live steps with owner approval on any unexpected response | Full PSN history imported; a second sync within 30 days makes **zero** PSN requests and shows only deltas |
| 8 | **GOG import** *(built before 7 — §14)* | First `LibraryImporter` + the shared cache / validator / budget / review sheet: web login, owned list → review sheet | GOG library imported as owned PC/Mac games (§14.6) |
| 9 | **Polish** | Liquid Glass touches under `#available(macOS 26)`, stats view, Top export as image, backups, app icon, empty states | — |
| 10 | **Delicious Library import** (§5.5) | First file importer: read-only `.deliciouslibrary2` reader, platform + title/edition mapping, shared review sheet with the "discard duplicate copies" rule + own-cover fallback, migration v7 (drop the `products.source` CHECK) | An old Delicious catalogue imports as owned physical games with the right platforms; re-import adds nothing |

Order rationale: 0–4 deliver the whole core loop (add → browse → rank) with manual entry only; 5–8 are independent accelerators and can be reordered freely (e.g. PSN before photos).

Milestone 9 **empty states — done** (wave 17): one shared `EmptyStateView` (SF Symbol · title · one sentence · up to two wired actions, static) across the library grid, sidebar smart lists, ranking, Play Next, Stats and the Vault browser; a single fixed-size import-matching progress modal for GOG/PSN/Delicious/Batocera; and the inspector reflows at a narrow column (§8). See `docs/ACCEPTANCE.md` for the owner tour.

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
| Importer order *(2026-09-19)* | **GOG (M8) is built before PSN (M7)**: lower risk, and it builds the shared importer machinery (§14). Same cache-first / stop-and-ask protocol for both. |
| PSN copy format *(2026-09-19)* | Existing library copy wins → purchased = digital → played-without-purchase = played only (offer Physical/Digital in the review sheet) → no signal = digital. Bulk "Change Copy Format" ships with M7. No PSNProfiles scraping: the 800 is a page size of *games*, not a trophy cap. |
| PS Plus copies *(2026-09-19)* | Imported, not excluded: `products.subscription = 'ps_plus'` (migration v8), "+" badge when a game is owned only through PS Plus, Format ▸ PS Plus filter, optional Play Next preference. Build on the owner's test account first (flows, empties), then one tiny probe per data set on the real account. |
| Sample photos | Originals git-ignored; **downsized JPEG fixtures committed**. |
| Persistence | GRDB stays even with Xcode available (see §1). |
| ROMs *(added 2026-09-18)* | Third ownership format next to physical/digital. Manual entry only for now — no romlord/emulator import. |
| 1–10 scores *(decided 2026-09-18)* | Not an input. Tiers + duels stay the way rankings are entered; a 1–10 score is **derived** from tier band + position, and tier **dividers are draggable** to tune bucket sizes (§7). |
| PSN sync posture *(decided 2026-09-19)* | Read-only, on demand, serial, rate-limited and budgeted; **every valid response cached 30 days**, bogus ones never cached; during the build the agent **stops and asks** at any step that does not return the proper content (§13). |
| Recommendations *(added 2026-09-18)* | **Play Next** (§7b): local, explainable, driven by my own rankings + a time bracket; only suggests owned, not-yet-completed games. Built as milestone 5b. **\"Ask Claude\" second opinion: yes** — on-demand re-ranking of the shortlist through the local `claude` CLI, never the default path. |
| Delicious import *(added 2026-09-19)* | Import an old Delicious Library 2 file (§5.5) as owned **physical** copies: read-only/immutable, VideoGame rows only, title cleaned for matching (original kept), **discard duplicate copies** already owned physically on that platform, own box-art as a cover fallback. Migration **v7 drops the `products.source` CHECK** (validated in Swift via `ProductSource`) so future importers need no table rebuild. |

---

## 13. PSN Sync — detailed plan (milestone 7)

**Goal.** Recover play history and digital ownership from my PlayStation account: which games I *played* (trophy lists — the only source for PS3/Vita), how long and when (PS4/PS5 game list), and what I *own digitally* (purchased list). Everything lands in the existing `import_titles` staging table and goes through a review sheet; nothing is added blindly. No trophy data is stored or shown.

**Non-goals.** Anything that writes to PSN (friends, messages, presence, purchases), background or scheduled syncing, other people's profiles, trophy details.

### 13.1 Risk posture — hard rules
PSN has no public API; this uses the endpoints the official mobile app and web store use. Personal, read-only, low-volume use has a long public track record (trophy sites, home-automation integrations), but it is outside Sony's terms and my whole digital library hangs on this account. So the client is built to be *boring*:
1. **Read-only endpoints only** — an allow-list of URL prefixes compiled into the client; any other request is a programming error and traps in DEBUG.
2. **User-initiated only.** A sync runs when I press Sync. No timers, no launch-time refresh, no retries in the background.
3. **Serial, slow, budgeted.** One request at a time, ≥ 1.5 s between requests (jittered), and a **hard budget per sync** (default 40 requests; a full first sync of ~800 titles needs ≈ 15). Exceeding the budget aborts the sync with a message — it never "just continues".
4. **No retry loops.** A failed request is not retried automatically, except a single retry after an explicit `Retry-After` on 429 — and then the sync ends for the day. 401 → one token refresh, once. 403 / captcha / HTML instead of JSON / unknown error envelope → **stop**, surface it, do nothing else.
5. **Credentials.** VGN never sees my password: login happens on Sony's own page inside a `WKWebView`; VGN reads the `npsso` cookie, exchanges it for an access token (~1 h) and refresh token (~2 months), and stores only those in the Keychain. "Sign out" deletes the tokens and (optionally) the cache. A paste-NPSSO field is the fallback.
6. **Cache first** (next section): inside the cache window a sync makes **zero** network requests.

### 13.2 Response cache — 30 days, valid responses only
Every PSN response is validated before anything else happens to it. **Valid ⇒ cached for 30 days. Bogus ⇒ never cached, never overwrites a good entry, and the sync stops.**

- Table: the **shared** `import_cache` / `import_cache_rejects` of §14.2 with `source = 'psn'` (GOG is built first and creates them in migration v5): key, endpoint, canonical params, fetched/expires dates, status, body, item count, schema version; rejects keep the last 50 per source with 4 KB excerpts, tokens and account identifiers redacted.
- **Key** = endpoint + canonicalised parameters (incl. page offset/limit and service name). Paged lists are cached **per page** plus a small manifest (total count, page keys) so a partial fetch can resume without re-requesting good pages.
- **"Not bogus" means all of:** HTTP 200; `Content-Type` JSON; decodes into the expected DTO with every *required* field present; no error envelope (`error`, `errors`, `code` ≠ success); pagination coherent (`totalItemCount` ≥ items seen, offsets contiguous, no duplicate ids across pages); list not *suspiciously empty* (an empty list where the previous valid cache had ≥ 1 item is treated as bogus until I confirm it); ids match their expected patterns (`NPWR…` communication ids, `CUSA/PPSA/…` title ids). Anything else is a **reject**.
- **Reads:** a sync asks the cache first. Fresh entry (< 30 days) ⇒ use it, no request. Stale or missing ⇒ one request (within the budget), validate, store. The sync summary always states "n responses from cache · m from network".
- **Force refresh** exists per data set (trophy titles / game list / purchases), behind a confirmation that says how many requests it will cost and when the data was last fetched. No global "refresh everything" shortcut.
- Tokens are never in this cache (Keychain only). The cache is wiped on Sign out if I tick the box.
- The 30-day TTL, the inter-request delay and the budget are constants in one file; changing them is a code review, not a setting.

### 13.3 Data sets and mapping
| Data set | Endpoint (host `m.np.playstation.com` unless noted) | Gives | Becomes |
|---|---|---|---|
| Profile | `/api/userProfile/v1/internal/users/me/profiles` (1 request) | account id, online id | sanity check that the token is mine; shown in Settings |
| Trophy titles (all) | `/api/trophy/v1/users/me/trophyTitles` (paged, limit 800; **no `npServiceName`** — the filter is ignored, see below) | title, platform (incl. PS3/Vita), earned counts, last update; each title's own `npServiceName` | `import_titles` rows; **every** title is kept, including 0 % ones (a game I merely launched is on this list) — signal **played** when progress > 0 %, **launched** at 0 %; only title, platform, progress % and last-activity kept |
| Game list | `/api/gamelist/v2/users/me/titles` (paged, limit 200) | play duration (ISO-8601), play count, first/last played, concept + title ids, **`service`** (how accessed) + **`category`** (platform / non-game) — PS4/PS5 only | `play_duration`, first/last played; signal **played**; `service`/`category` drive ownership + noise (see "Physical or digital?") |
| Purchases | web GraphQL `getPurchasedGameList` on `web.np.playstation.com` (persisted-query hash — **the fragile one**) | entitlements, product name, platform, PS Plus-claimed vs bought (`membership`) | signal **owned** (digital); Plus claims carry the `ps_plus` subscription flag; a Plus claim played ≤ 10 min goes to the Vault (§16), not the library |

**One trophy list, not two** *(live 2026-09-20)*. The `trophyTitles` endpoint **ignores the `npServiceName` filter**: `trophy` and `trophy2` returned the identical 265-item list. VGN fetches it **once** with no `npServiceName` (matching psn-api's `getUserTitles`); each title carries its own `npServiceName` (`trophy` = PS3/PS4/Vita sets, `trophy2` = PS5 sets), and `trophyTitlePlatform` (incl. combined `"PS4,PS5"`, `"PS3,PSVITA"`) gives the slug. The separate "PS3/Vita" data set / probe / fetch is gone.

**PS Plus copies — "play these before I unsubscribe"** *(owner, 2026-09-19)*. A game claimed through PS Plus is a licence that **expires with the subscription**, so it is worth knowing which ones they are. The purchases list marks each entitlement with its membership (`membership: "PS_PLUS"` vs `"NONE"` in the community clients — to be confirmed on the first real response; unknown values are kept raw and shown, never guessed).
- **Stored**: migration **v8** adds `products.subscription TEXT` (NULL = a copy I really own; `'ps_plus'` today; free text so another service needs no rebuild). A Plus claim becomes a digital Product with `source = psn`, `subscription = ps_plus`. If I later *buy* the same game the bought entitlement becomes a second, unflagged copy; if a later sync no longer lists the claim (subscription lapsed or game withdrawn) the sync proposes removing that copy in the review sheet — never silently.
- **Only claims I actually played become copies** *(owner 2026-09-20, §16 The Vault)*. A `PS_PLUS` entitlement whose joined game-list play time is **≤ 10 min** (`ImportPolicy.vaultPlaytimeGateSeconds = 600`, shared with Batocera) is **not** made a library copy — it is staged *Ignored* ("PS Plus — in the Vault (played under 10 min)") for a later lane to move into the Vault, which stops 581 monthly claims from drowning the library. Only a claim played **> 10 min** becomes the owned-via-subscription copy below. Bought (`membership: NONE`) copies are never vaulted (that is my backlog). **Cross-gen twins** (a PS4 and a PS5 entitlement of one game, seen live 2026-09-20) collapse to one copy (ps5 preferred, note "PS4 & PS5 versions"); a bought twin beats a Plus twin.
- **Counts as owned, but says so**: the game is in Owned/Backlog like any digital copy; the grid cell shows a small **"+" badge — a PlayStation-blue "+" inside a yellow circle** (PS Plus colours: yellow ≈ `#FFC300` fill, blue ≈ `#0070D1` glyph, same size as the owned/played badges, tooltip "PS Plus — expires with the subscription") next to the owned badge, the inspector's copy row reads "PS Plus — expires with the subscription", and export carries the flag. A game I own **only** through PS Plus is what matters: a copy I also own on disc is not at risk and shows no badge.
- **Filter**: Format ▸ **"PS Plus"** (after Multiple Copies): games whose only owned copies are subscription copies. With Status ▸ Not Played it is the "finish before unsubscribing" list; a sidebar smart list is not needed.
- **Play Next**: a reason line "leaves with PS Plus" and an option in the bar's Options menu, *"Prefer expiring PS Plus games"* (off by default; when on, a modest, backtest-neutral boost that only reorders near-ties — it never beats a clearly better fit).
- **What PSN does not tell us**: games merely *played* from the Extra/Premium catalogue without being claimed may not appear as entitlements at all (they then import as *played, not owned*, which is accurate), and PS Plus *tier* (Essential/Extra/Premium) per game is not exposed. No expiry dates exist — the flag is the information.

**Accounts for the build.** The owner created a **test PSN account** (no PS Plus, no play history). It has **a few free games downloaded** (so the purchases list is not empty: it can prove the GraphQL call, the persisted-query hash and the entitlement DTO with `membership: NONE` — the fragile S6 step gets its first probe here, not on the real account), but no PS Plus and little or no play history. It is used for everything that does not need my data: sign-in flow, token exchange/refresh, headers, endpoint reachability, empty-list handling (an empty list from a brand-new account is *valid*, not "suspiciously empty" — the validator only distrusts emptiness when a previous valid cache had items). It cannot prove the DTOs (no titles) or the `membership` values (no Plus), so each data set still gets its **tiny probe on the real account** afterwards (S3a-style, one request, smallest limit) before any full fetch — same stop-and-ask rules, and the dev response cache keeps the two accounts in separate folders.

**About the "800"** — it is the *page size* of the trophy-**titles** list: one entry per **game** I have trophies in (title, platform, earned counts), not per trophy. A library of more than 800 games simply costs a second page (`offset=800`); individual trophies are never fetched, stored or shown — VGN only needs "≥ 1 earned trophy ⇒ played". So there is no coverage gap to fill, and **PSNProfiles scraping is not needed and not planned** *(decided 2026-09-19)*: it would add a Cloudflare-protected third party whose terms forbid scraping, only works for public profiles, and returns the same title list.

**Played but not owned is a first-class result** *(2026-09-19)*. The trophy list is my complete launch history, so it is also the record of games that were **lent to me or that I no longer have**: they import as *played, not owned* (the data model has always allowed that) and never need a copy. In the review sheet:
- progress > 0 % → **Played**, pre-ticked;
- progress = 0 % → **Launched, 0 %** — its own group, *not* ticked by default (I decide per game: played, or ignore); on PS4/PS5 a game-list play time of ≥ 30 min promotes a 0 % title to *Played*;
- progress = 100 % → status pre-filled **100 %**; nothing else is inferred about finishing (trophies cannot tell "finished" from "abandoned") — that is what Mark Played As / `⇧M` is for afterwards.

**Physical or digital?** *(decided 2026-09-19)* Division of labour: **trophies / game list = what I launched (played)** — a mix of discs and downloads, with no format in it; **the shelf = the photo scan** (physical copies); **purchases = digital copies**. PSN therefore never creates a physical copy on its own. The two imports meet on the same game in either order: a PSN sync after a photo scan adds *played* to the disc already there; a photo scan after a PSN sync adds the physical copy to the played-only game (the scan's "already in library" match — covered by a test in M7). The copy format is derived in this order:
1. **Already in my library** (e.g. a disc added by photo scan) → no new copy at all: the import only adds *played*, playtime and last-played to the existing game. This covers most discs.
2. **Purchased entitlement** → owned, **digital**. A **PS Plus claim** is imported the same way but flagged (next paragraph).
3. **Played, no entitlement** → the only signal available for a disc (it may also be a game I borrowed, sold, or played on someone else's licence), so it is imported as **played, not owned** by default, listed in the review sheet under "*Played — no purchase found*" with a one-click "own these as ▸ Physical / Digital" for the ticked rows (**default Physical**). The explicit disc/digital marker foreseen here turned out to be the game list's **`service`** field *(live 2026-09-20)*: `none(purchased)` = a digital purchase (owned digital even if the purchases list misses it); `ps_plus` = played through PS Plus (owned-via-subscription if a `PS_PLUS` entitlement exists, else played-not-owned, note "played via PS Plus"); `other` = neither — in my data the DISC games (Elden Ring, FF VII Rebirth, Kingdom Come II…) — imported played-not-owned with the note "probably a disc — not a digital licence", the "own as" default then being Physical. Ownership is **never asserted from `other`**; unknown `service` values are kept raw. The game list's **`category`** gives the platform (`ps5_…`/`ps4_…`) and flags non-games: a category not ending in `_game` (`ps5_native_media_app` etc. — Netflix, Plex) is *Ignored* as a media app.
4. **No usable signal at all** (the purchases step S6 failed or was skipped) → anything I choose to own from the import defaults to **digital**, and I re-sort later.
- To make that re-sorting practical the milestone also adds a bulk **Change Copy Format ▸ Physical · Digital · ROM** action for a multi-selection (grid context menu + Game menu; one transaction, one undo step) — with the *Format* filter it turns "fix fifty discs" into three clicks. GOG needs none of this: every GOG copy is digital (§14.3).

Normalisation: one `import_titles` row per (source `psn`, stable external id); the three lists are joined on concept/title id where present, else on normalised name + platform (`TitleNormalizer`). Noise filtered by default and remembered: media apps, demos, betas, themes/avatars, PS Plus claims never launched.

Matching to the library reuses the photo-scan ladder (platform-constrained IGDB autocomplete → `FuzzyMatch` buckets → alternatives); confident matches are pre-ticked, the rest wait in the review sheet (*New / Already matched / Ignored*), decisions persist in `import_titles.matched_game_id / ignored`, so a later sync surfaces only new titles and refreshed playtimes. Commit is one transaction: played flags (+ `game_platforms`), digital Products for purchases, `psn_playtime_s` (manual playtime still wins), last played; then `notifyLibraryChanged()`.

### 13.4 Architecture
`VGN/Services/Importers/` — `LibraryImporter` protocol (authenticate → fetch → emit staging rows → shared review sheet; GOG will be the second implementation), `PSN/PSNAuth` (WebView bridge, token actor with single-flight refresh, Keychain), `PSN/PSNClient` (actor: allow-list, serial queue, delay, budget, validation, cache-first reads through `PSNResponseCache`), `PSN/PSNMapping` (pure: DTO → staging rows, noise rules), `PSNSyncCoordinator` (orchestrates a sync, progress + summary). UI: Settings ▸ Accounts ▸ PlayStation (sign in, status, token expiry, last sync, cache age per data set, Force refresh, Sign out & wipe), the import review sheet (shared component with photo scan where it fits). Everything behind protocols with fakes; **unit tests never touch the network** — they run on recorded, scrubbed fixtures and an injected clock (TTL, delay, budget, reject paths, resume after a partial paged fetch).

### 13.5 Build protocol — gated live steps, stop and ask
The build talks to the real service as little as possible, in a fixed order, and **halts on anything unexpected**. For the agent doing the work this is binding:

> **At every live step:** make exactly the listed request(s); validate the response with the §13.2 rules. If it is valid → record a scrubbed fixture, cache it, report, move on. If it is **not** the proper content — wrong status, HTML/captcha, error envelope, schema mismatch, suspicious emptiness, rate-limit or auth challenge, anything not foreseen here — then **stop all PSN traffic immediately**, do not retry, do not try a variant, another parameter, another endpoint or another host; write down exactly what was sent and received (tokens and account ids redacted), explain the likely cause and the options, and **wait for the owner's explicit approval** before any further request. Approval covers one next action, not the rest of the build.

| Step | Live requests (budget) | Proper content = | Checkpoint |
|---|---|---|---|
| S0 Scaffolding | 0 | — | protocol, DTOs **ported from maintained open-source clients, pinned to a commit** (`achievements-app/psn-api` — TypeScript, MIT: auth exchange, `trophyTitles`, `getUserPlayedGames`, `getPurchasedGames` incl. the current GraphQL persisted-query hash; cross-checked against `isFakeAccount/psnawp` and the `andshrew/PlayStation-Trophies` endpoint notes; their recorded sample responses become the first fixtures; any disagreement between sources is listed for the owner before S1), cache + validator + budget limiter + allow-list, all tested on synthetic fixtures |
| S1 Sign-in (**test account**) | the web login (owner does it) + 2 token calls | access + refresh tokens with expiry | **ask before S2**; owner confirms which account was used |
| S2 Profile | 1 | my online id / account id | report, continue if valid |
| S3a Trophy titles **probe** (`trophy2`, `limit=10`) | 1 | 10 titles + `totalItemCount` | the first data request is deliberately tiny: prove auth, headers, DTO and validator on 10 rows; **stop and report before anything bigger** |
| S3b Trophy titles page 1 (`limit=800`) | 1 | a full page, coherent with S3a's `totalItemCount` | report counts; **ask before paging** if more pages are needed |
| S4 Remaining trophy pages + `trophy` (PS3/Vita) | ≤ 4 | coherent pages, no duplicates | report |
| S5 Game list | ≤ 3 | titles with ISO-8601 durations | report |
| S5b **Switch to the real account** | sign-in + 1 profile call | my real online id | every data set below/above is re-probed on the real account with ONE tiny request each (trophy titles `limit=10`, game list `limit=10`) before its full fetch; **ask before each full fetch** |
| S6 Purchases (GraphQL) — real account, first a probe with the smallest page size | ≤ 4 | entitlement list incl. the `membership` marker (first sight of PS Plus values); **most likely to fail** (persisted-query hash changes) | on failure: stop and ask — owned-digital can ship later without blocking the milestone |
| S7 Full sync from cache | 0 | — | staging rows, matching, review sheet, commit — all offline |
| S8 Second sync | 0 (inside the cache window) | — | proves "zero requests, only deltas" |

The purchases list is the same GraphQL operation that `library.playstation.com/recently-purchased` runs in my browser: if the persisted-query hash has moved on by S6, I can read the current one from that page's network tab instead of anyone guessing (a stop-and-ask, not a retry). **Credentials never leave the owner's hands** *(2026-09-19)*. Nobody — not the orchestrator, not an agent, not this chat — is ever given a PSN password, an NPSSO or a token. The owner signs in on Sony's own page inside the app (Settings ▸ PlayStation ▸ Sign In; a paste-NPSSO field *in the app* is the fallback); the app keeps the tokens in the Keychain. The live build steps are driven from a **DEBUG-only "PSN build steps" panel** in that Settings tab: one button per step (*Probe profile · Probe trophy titles (10) · Probe game list (10) · Probe purchases (smallest page) · Full fetch …*), each performing exactly the requests of its §13.5 row, showing the redacted outcome, and writing the body to the development response cache. The orchestrator then reads those cached bodies from disk (no headers, no tokens in them) to check the DTOs against reality and to cut scrubbed fixtures. The panel shows which account is signed in (`test` / `real`, by online id) so a step can never run against the wrong one. **Small first, cached always** *(owner, 2026-09-19)*. Every data set starts with ONE small request (smallest `limit` the endpoint accepts, first page only); the full run for that data set happens only after that probe parsed and validated cleanly and I have seen the report. Nothing is ever fetched twice: during the build every valid live response is written, before anything else is done with it, to a **development response cache** on disk — `~/Library/Application Support/VGN/dev-import-cache/psn/<endpoint>-<params-hash>.json` plus an `index.json` (URL without tokens, status, date, item count) — which the build scripts and the client read first, so re-running a step, a test recording or a crashed session costs zero requests. It is outside the repo, never committed, holds no tokens (headers are not stored; account ids are kept only there, scrubbed from fixtures), and is deleted at the end of the milestone or on request. At run time the app uses its own cache (§13.2): the `import_cache` table inside `vgn.sqlite` (`source = 'psn'`, 30 days, valid responses only; rejects in `import_cache_rejects`), tokens in the Keychain. Total live budget for the whole build ≈ 15–20 requests. Recommended: run S1–S6 with a **secondary PSN account** first (mistakes like a request loop happen while building, not while using), then one real sync with my main account once S8 passes. Fixtures are scrubbed of online id, account id, entitlement ids and avatars before they are committed; the NPSSO/token values never appear in logs, fixtures, prompts or commits.

### 13.6 Done when
A first sync imports my PSN history through the review sheet with ≤ 20 requests; an immediate second sync makes **0** requests and proposes nothing new; after adding a game on the console and forcing a refresh of one data set, only that data set is re-fetched and only the new title appears; every reject path shows a clear message and leaves the last good cache intact; signing out removes the tokens.

---

## 14. GOG Sync — detailed plan (milestone 8, built before PSN)

**Goal.** Import what I own on GOG as *owned (digital)* PC/Mac games, through the same staging table and review sheet as every importer. Decided 2026-09-19: GOG is built **before** PSN — it is the simpler service, so it is where the shared importer machinery (protocol, response cache, validator, budget limiter, review sheet) gets built and proven; PSN (§13) then plugs into it.

**Non-goals.** Play time, achievements, friends, wishlist (GOG only exposes play time to Galaxy; I do not use Galaxy — not installed on this Mac, so its local database is not an option). Downloading installers. Anything that writes to the account. Background or scheduled syncing.

### 14.1 Risk posture
GOG has no documented public API either, but its account endpoints have been stable for a decade and are what open-source launchers and library managers use daily; GOG is DRM-free and tolerant of them. The exposure is far lower than PSN — and the rules are **the same anyway**, because they cost nothing and the machinery is shared:
1. **Read-only allow-list**: `auth.gog.com/token` (code exchange + refresh only), `embed.gog.com/userData.json`, `embed.gog.com/user/data/games`, `embed.gog.com/account/getFilteredProducts`. Anything else traps in DEBUG. (`account/gameDetails/<id>.json` is *not* on the list in v1 — it is one request per game and adds nothing the import needs.)
2. **User-initiated only**; serial; ≥ 1 s (jittered) between requests; **budget 15 requests per sync** (a 300-game library needs 1 + 1 + 3 pages = 5).
3. **No retry loops**: 401 → one token refresh, once; 429 → honour `Retry-After` once, then the sync ends; 403 / HTML / captcha / unknown envelope → stop and surface.
4. **Credentials**: I log in on GOG's own page in a `WKWebView` (non-persistent data store). VGN never sees the password; it keeps only the refresh/access tokens in the Keychain (service = bundle id, account `gog`). Sign out deletes them (and optionally the cache).
5. **Cache first** (§14.2).

**Sign-in mechanism — decided 2026-09-19: OAuth.** The *authorization-code* flow used by community launchers: GOG's login page in a non-persistent `WKWebView` → redirect to `embed.gog.com/on_login_success` carrying `code` → `auth.gog.com/token` → access token (~1 h) + refresh token, both in the Keychain; refresh is single-flight and silent. It relies on the Galaxy client's publicly documented client id/secret — they are GOG's, not mine, and not confidential (every open-source GOG client ships them); they live in ONE file (`GOGAuthConfiguration+Galaxy.swift`) behind the injected `GOGAuthConfiguration`, so they can be swapped or moved out of the repo without touching the flow. The session-cookie route is not built. The web view is restricted to GOG's login hosts (`auth.gog.com`, `login.gog.com`, `www.gog.com`, plus the captcha host GOG's page itself loads); the redirect is intercepted before it renders, and the `code` is never logged.

### 14.2 Shared response cache — 30 days, valid responses only
Same contract as §13.2, and **one implementation for every importer**: migration **v5** creates `import_cache(source TEXT, key TEXT, endpoint TEXT, params_json TEXT, fetched_at DATETIME, expires_at DATETIME, status INTEGER, body BLOB, item_count INTEGER, schema_version INTEGER, PRIMARY KEY (source, key))` and `import_cache_rejects(id, source, endpoint, params_json, received_at, status, reason, body_excerpt)` (last 50 per source, 4 KB excerpts, tokens / user ids / e-mail redacted). These replace the `psn_cache*` names of §13.2 — PSN will use `source = 'psn'`.
- **Valid ⇒ cached 30 days. Bogus ⇒ never cached, never overwrites a good entry, the sync stops.** Inside the window a sync makes **zero** requests. Paged lists are cached per page + a manifest.
- **"Not bogus" for GOG**: HTTP 200; JSON content type; decodes into the expected DTO with its required fields (`products[]`, `page`, `totalPages`, `totalProducts`; per product `id`, `title`, `worksOn`); pages coherent (`page` echoes the request, `totalPages`/`totalProducts` identical across pages, no duplicate ids, Σ products = `totalProducts`); the owned-id list and the product pages agree (every product id ∈ owned ids; a gap is reported, not fatal); not *suspiciously empty* (empty where the last valid cache had ≥ 1 item ⇒ bogus until I confirm); a login page or `isLoggedIn: false` in `userData.json` ⇒ auth failure, never cached.
- Force refresh per data set behind a confirmation stating the request cost and the age of the cached data. TTL, delay and budget are constants in one file.

### 14.3 Data sets and mapping
| Data set | Endpoint | Gives | Becomes |
|---|---|---|---|
| Account | `embed.gog.com/userData.json` (1) | username, `isLoggedIn` | sanity check that the token is mine; shown in Settings (username only) |
| Owned ids | `embed.gog.com/user/data/games` (1) | `owned: [product id]` | cross-check for the pages below |
| Library pages | `embed.gog.com/account/getFilteredProducts?mediaType=1&page=n` (100 per page) | id, title, `worksOn` {Windows, Mac, Linux}, `isGame`, category, release date, image, `isHidden`, tags | one `import_titles` row per product: `source = gog`, `external_id` = product id, signal **owned** |

- **Platform**: the owned copy is one digital Product. Default platform = `mac` when `worksOn.Mac`, else `pc` (I play on a Mac) — switchable for the whole import ("Mac when available" / "Always PC") and per row in the review sheet. Linux-only titles map to `pc` with a note.
- **Noise, filtered by default and remembered** (shown under *Ignored*, one click to restore): `isGame = false`, movies (`mediaType = 2` is never requested), DLC / expansions that GOG lists as separate products, soundtracks / artbooks / "goodies" packs, demos and prologues, hidden products.
- **Packs / collections**: a product that IGDB knows as a bundle becomes a compilation Product with its member games (reusing the §5.1 bundle expansion — reverse lookup, nested bundles, add-ons dropped); otherwise it is an ordinary game.
- **Matching** reuses the photo-scan ladder (IGDB autocomplete constrained to PC/Mac → `FuzzyMatch` buckets → alternatives), GOG's release year as the tie-breaker (the same `release_dates.y` filter Quick Add uses). Confident matches are pre-ticked; the rest wait under *New*. Decisions persist in `import_titles.matched_game_id / ignored`, so a later sync proposes only new purchases. Already-owned-on-GOG games are recognised by an existing Product with `source = gog` + the same external id, never by title alone.
- **Commit** = one transaction: digital Products (`source = gog`, external id kept for idempotency), `game_platforms`, games created *owned, not played* (they land in Backlog); nothing is marked played, no tier is touched; then `notifyLibraryChanged()` and the usual enrichment/cover jobs.

### 14.4 Architecture
`VGN/Services/Importers/` — shared: `LibraryImporter` protocol (`authenticate` → `fetch(progress:)` → staging rows), `ImportResponseCache` (the §14.2 table, injected clock), `ImportResponseValidator` protocol + `ImportRequestBudget` + `ImportRequestPacer` (delay/jitter, injected clock), `ImportAllowList`; `GOG/GOGAuth` (web-view bridge + token actor with single-flight refresh, Keychain), `GOG/GOGClient` (actor: allow-list, serial queue, pacer, budget, validation, cache-first reads), `GOG/GOGMapping` (pure: DTO → staging rows, platform rule, noise rules), `ImportSyncCoordinator` (orchestrates one sync for any importer: progress, summary "n from cache · m from network", reject handling). Database (lane A): migration v5, `ImportStagingStore` (upsert rows, decisions, idempotent commit). UI: Settings ▸ Accounts ▸ GOG (sign in, username, last sync, cache age per data set, Force refresh, Sign out & wipe) and the **shared import review sheet** (*New / Already matched / Ignored*, platform switch, per-row alternatives — built from the photo-scan review components where they fit). Everything behind protocols with fakes; **unit tests never touch the network** (synthetic then recorded-and-scrubbed fixtures, injected clock: TTL, delay, budget, every reject path, resume after a partial paged fetch).

### 14.5 Build protocol — gated live steps, stop and ask
The §13.5 rule applies verbatim, with "GOG" for "PSN": **at every live step make exactly the listed requests; if the response is not the proper content — wrong status, HTML/login page/captcha, error envelope, schema mismatch, suspicious emptiness, rate limit, auth challenge, anything unforeseen — stop all GOG traffic, do not retry or try a variant, report what was sent and received (tokens, user id, e-mail redacted), and wait for my explicit approval. Approval covers one next action.**

| Step | Live requests (budget) | Proper content = | Checkpoint |
|---|---|---|---|
| G0 Scaffolding | 0 | — | shared importer machinery, migration v5, GOG DTOs from community documentation, mapping, review sheet, Settings pane — all on synthetic fixtures |
| G1 Sign-in (OAuth, §14.1) | the web login (I do it, in the app) + 1 token call | access + refresh tokens with expiry | **ask before G2**; a refused client id/secret or an unexpected redirect = stop and ask |
| G2 Account | 1 | `isLoggedIn: true` + my username | report, continue if valid |
| G3 Owned ids | 1 | a non-empty id list | report the count |
| G4 Library page 1 | 1 | products + `totalPages` | report counts; **ask before paging** if `totalPages` > 5 |
| G5 Remaining pages | ≤ 5 | coherent pages, Σ = `totalProducts` | report |
| G6 Full sync from cache | 0 | — | staging, matching (IGDB calls only), review sheet, commit — offline as far as GOG is concerned |
| G7 Second sync | 0 (inside the cache window) | — | proves "zero requests, nothing new proposed" |

Total live budget for the whole build ≈ 10 requests. Fixtures are scrubbed of username, user id, e-mail, avatar and order data before they are committed; tokens and cookies never appear in logs, fixtures, prompts or commits. My real GOG account is acceptable for the build (read-only, single-digit request count), unless G1 turns up something unexpected.

### 14.6 Done when
A first sync imports my GOG library through the review sheet in ≤ 10 requests; an immediate second sync makes **0** requests and proposes nothing new; after a new purchase and a forced refresh only the library pages are re-fetched and only the new title appears; DLC / goodies are ignored by default and restorable; every reject path shows a clear message and leaves the last good cache intact; signing out removes the tokens.

---

## 15. Batocera / ROM collection *(owner, 2026-09-19 — phase 1 started the same day)*

> Correction (same day): the owner runs **Batocera**, not Recalbox. This section was rewritten for Batocera; the design (two tiers, taste-tailored Discover, automatic sync) is unchanged, the file format facts are different — and simpler.

**The idea.** I have a Batocera box with thousands of ROMs on my NAS. Batocera keeps per-game play data; fusing that collection in could make VGN suggest retro games I own but have never tried — without drowning the library.

**What Batocera has (from its EmulationStation fork's documentation; to be confirmed on my files before any design is final).** I run **Batocera 43.1** (the current stable, released 2026-05-30). Its EmulationStation keeps ONE `gamelist.xml` per system in `share/roms/<system>/` (the `share` = `/userdata` partition, exported over SMB as `\\BATOCERA\share` (`smb://batocera/share` from the Mac), holding both the scraped metadata and the play data in the same `<game>` element: `path`, `name`, `desc`, `image` / `thumbnail` / `video`, `rating` (0–1), `releasedate`, `developer`, `publisher`, `genre`, `players`, `region` / `lang`, and the three counters **`playcount`**, **`gametime`** (total seconds played, sessions longer than 5 s) and **`lastplayed`** (`YYYYMMDDTHHMMSS`), plus `favorite` / `hidden` flags. No separate user-data file (that was a Recalbox 10 detail). Note: EmulationStation rewrites `gamelist.xml` when it exits or a game ends, so a file read while the box is running may lag by one session — harmless for a sync. File-based and read-only like the Delicious importer: no account, no network service, nothing to get banned from.

**The flooding problem — two tiers, not one.** A ROM set is not a collection I *chose*; 3 000 entries would bury ~450 curated games in the grid, the counts, the stats and the ranking queue. So:
- **Library games** (what the grid, Backlog, stats and ranking are about): only ROMs I have **really played — more than 10 minutes in total** (`gametime > 600 s`, raised from 5 minutes on 2026-09-20 and shared with PS Plus, §16; a shorter total is a test launch or a mistake and stays in the catalogue, whatever its `playcount`), marked **favourite**, or **promoted by hand**. The threshold is one constant; a game that later crosses it is promoted by the next sync. They become ordinary games with a ROM copy (`source = batocera`), played flag, playtime and last-played date taken from Batocera — which also feeds the filed "Play it again" and "almost there" ideas with machine-known dates.
- **The shelf in the cellar — a ROM catalogue** kept in its own table (`rom_catalog`: system, file, cleaned title, region/revision, hash, optional IGDB id, play data), **never counted** in All / Owned / Backlog / stats / ranking. It shows up in exactly two places: a sidebar entry **"Batocera"** (its own browsable, searchable list per system, with "Add to Library" on any row), and **Play Next ▸ "Discover"** (below).
- Duplicates collapse before anything is shown: regions, revisions, hacks, translations and multi-disc files fold into one title with the existing `LibretroFilenameParser` / libretro key (the same machinery the cover matcher uses); BIOS files, homebrew test ROMs and `hidden` entries are dropped. My ~130 hand-entered ROM copies are matched to catalogue entries so nothing doubles.

**"Suggest me something I don't know about" — cheaply.** Enriching thousands of ROMs through IGDB one by one is slow and pointless. Invert it: for each system present, ask IGDB once for that platform's best-regarded games (a few hundred rows per platform, rating + rating count + genres/themes/keywords — a handful of requests in total, cached for months), and **intersect** that list with the catalogue by normalised title. The intersection — typically a few hundred games — is the Discover pool; only those get traits. Play Next then gains a **"Discover on your Batocera"** row: never-played catalogue games scored by the usual taste model (traits vs my tiers) plus the crowd prior, fitted to the chosen time bracket, with reasons like "SNES · top-rated action RPG · like *Secret of Mana* (your A tier)". "Not interested" retires a title for good; "Add to Library" / "Start playing" promotes it. Rotation matters more than precision here: the row should surface different games each week.

**Decisions** *(owner, 2026-09-19)*:
- **My set is built with 1G1R** (one game, one ROM, preferred regions), so most region/revision duplicates are already gone; the libretro-key folding stays as a safety net (multi-disc, the odd leftover) rather than the main mechanism.
- **Access**: read-only over the **SMB mount** of the Batocera share (`/Volumes/share/roms/<system>/gamelist.xml`, or wherever I mount it — a folder I pick once, remembered as a security-scoped bookmark is not needed since the app is not sandboxed). Never write to the share.
- **Arcade romsets are ignored** (MAME, FBNeo, Neo-Geo sets, Naomi/Atomiswave…): a fixed skip list of systems, editable.
- **Suggestions must be tailored to my taste**, not just "top-rated on the platform": the Discover pool (platform best-ofs ∩ my catalogue) is only the *candidate* set; ranking inside it uses the same taste model as the rest of Play Next — traits (genres, themes, keywords, franchises, developers) weighted by my tiers and derived scores, direct links ("from the makers of…", "same series as your S-tier…"), my play style and time bracket, plus Batocera's own signals (systems I actually play a lot get a nudge; things I launched once and dropped after five minutes are a mild negative). The crowd rating is a prior, never the driver. Backtestable like §7b, with "Ask Claude" available on the shortlist.
- **Favourites are my explicit picks** *(owner, 2026-09-19)* — a ★ on the Batocera box is curation, not noise, so it gets special treatment at three levels: (1) **auto-added to the library** after a sync when the IGDB match is *confident* (platform-constrained, year-checked, top bucket; setting "Add my Batocera favourites automatically", on by default) — a quiet banner "12 favourites added from Batocera · Undo", never for ambiguous or unmatched ones, which stay in the review sheet; everything else (played > 5 min, hand-picked) still goes through the review; (2) in **Play Next's regular picks**, a library game that is a Batocera favourite I have not played gets a modest boost and the reason "★ a favourite on your Batocera" — it is in my backlog because I flagged it; (3) in **Discover**, a favourite that is not in the library yet (no confident match, or auto-add switched off) is pinned at the head of the row with the same reason and is exempt from the weekly rotation. Un-favouriting on the box removes the boost at the next sync and never removes a game from the library. **Built (wave 13)** — all three levels, as designed: (1) after every sync the un-decided favourites are matched to IGDB in a cancellable background pass (each staged in `import_titles` first, so none is queried twice), and those with a top-bucket, platform- and year-consistent match (a year gap > 1 downgrades to "needs review") are promoted through `BatoceraPromoter`; a quiet "N favourites added from Batocera · Undo" banner (one undo step removing exactly what the batch created + clearing `promoted_game_id`), "· K still to match" when a first run hits the 60-per-run cap, else "· M to review"; setting "Add my favourites automatically" (default on). (2) `Candidate.isBatoceraFavourite` (one additive join) + a small backtest-neutral bonus for unplayed favourites. (3) `DiscoverScorer` pins favourites (≤ half the visible cards), jitter-exempt, "★ your favourite" first. See `docs/batocera-import.md`.
- **Regular sync**: unlike PSN/GOG this is a local file read with nobody to annoy, so it may be automatic: when the share is mounted, VGN compares the modification date of each system's `gamelist.xml` with what it last read (a few `stat` calls), and re-reads only the systems that changed — at launch and on a "Sync Now" button; nothing happens (and nothing complains) when the NAS is not mounted. Each sync updates **both tiers**: new ROMs enter the catalogue (and the Discover pool), newly *played* or *favourited* ones are promoted into the curated library automatically — with a quiet "3 games added from Batocera" banner and an Undo — and play time / last played are refreshed on games already there. ROMs deleted from the share leave the catalogue; a library game is never deleted by a sync (it just loses its "on Batocera" marker).

**Still open.** Whether the tag names above match my files exactly (favourites especially); whether play data for never-scraped ROMs exists; how good title intersection is for Japanese-only and translated ROMs; whether the scraped metadata already in `gamelist.xml` (rating, genre, description, image) is enough for the browse view (likely — IGDB only for the Discover pool).

**What is really on my box** *(read-only survey over the SMB mount `/Volumes/share/roms`, 2026-09-19)*: **42 systems with a gamelist, 14 633 entries** — biggest: mame 3 157 · snes 1 931 · nes 1 707 · gba 1 578 · gbc 1 116 · gb 1 082 · megadrive 948 · msx1 561 · n64 398 · mastersystem 382 · gamegear 339. Without the arcade sets (mame, fbneo, daphne…) about **11 300**. Play data is real: **168 entries launched, 150 with a `gametime`, 80 played more than 5 minutes** (snes 23, megadrive 12, nes 11, scummvm 7, psx 4…), **247 favourites** (nes 91, snes 61, megadrive 37, n64 22, gba 16), 107 hidden. The files are ScreenScraper-scraped and richer than expected — per game: `<game id="…">` (the ScreenScraper id), `path` (No-Intro name with region), `name` (clean title), `desc`, `rating` (0–1), `releasedate`, `developer`, `publisher`, **`genre`**, **`family`** (the series — present on ~30 %), `players`, `region`, `lang`, `md5`, plus `playcount`, `gametime`, `lastplayed`, `favorite`, `hidden`, and local `image` / `thumbnail` / `boxback` / `video` paths. Consequences: (1) the catalogue needs **no IGDB call at all** to be browsable, searchable and scorable — genre, family, developer, year and the crowd rating are already there; IGDB is only needed when a ROM is *promoted* into the library (to get its id for dedupe against my ~134 hand-entered ROM copies and the normal enrichment); (2) the taste model can score catalogue games from gamelist metadata directly (genre / family / developer matched against the traits of my ranked games), so "Discover" works offline; (3) stable identity = system + path, with `md5` and the ScreenScraper id as secondary keys; (4) box art is already on the share — thumbnails can be read from it, never copied wholesale.

**Build order when scheduled:** phase 1 — reader, system→platform table + skip list, catalogue store (`rom_catalog`, migration), promotion rules (> 5 min or favourite or by hand → review sheet, deduped against existing copies), change-detecting sync; phase 2 — the "Batocera" sidebar browser, the promotion review, Settings ▸ Batocera (share path, skip list, Sync Now), Play Next ▸ Discover with the taste-tailored scoring.

**Built — phase 1 (services/DB, prior wave) and phase 2 (UI, wave 13).** ✅ Phase 2 as built (`docs/batocera-import.md` has the full write-up + owner walkthrough): **Settings ▸ Batocera** (share folder picker, status, Sync Now + cancel, auto-sync-at-launch toggle default on, editable skip list, read-only threshold); **live-only auto-sync at launch** after the UI is up (inert everywhere else — never touches `/Volumes` in sample/test); a quiet **"N Batocera games ready to review"** banner with a *Review…* action (never an auto-commit); the **promotion review** through the shared `ImportReviewSheet` (IGDB match with progress+cancel, play-time line, the "adds play time only" duplicate state, commit via `BatoceraPromoter`); the **Sidebar ▸ Batocera ▸ ROM Catalogue** browser (per-system, FTS search, sort, filter chips, paged, share thumbnails, In-Library marker, Add to Library… / Not Interested / Show in Finder) with the catalogue kept **invisible** to the library counts/stats/ranking/export (a separate observation; a 10 000-row test proves the library counts are unchanged); and **Play Next ▸ "Discover on your Batocera"** — never-played catalogue games scored by a **new** pure `DiscoverScorer` (trait affinity + direct links + capped crowd prior + system affinity, neutral time, weekly rotation + Shuffle) reusing the engine's `TraitProfile`/`DirectLinks` without changing its weights or backtest. **No schema change** (v10 sufficed). Follow-up: "Ask Claude" for Discover (not wired this lane).

---

## 16. The Vault — games within reach that are not my backlog *(owner, 2026-09-20)*

**What it is.** One place for everything I *can* play but never chose to put on my list: the Batocera ROM set (§15) and the **PS Plus games I have barely touched** (§13). Same problem, same answer: thousands of entries must not drown a curated library, but they must not be forgotten either — so they live in **The Vault**, are browsable there, and surface only through a dedicated Play Next row. The name replaces "ROM Catalogue" everywhere (sidebar section **THE VAULT** with one row per source — *Batocera ROMs*, *PS Plus* — each with its count; Play Next row **"From the vault"**, which replaces "Discover on your Batocera").

**One gate for both sources: 10 minutes of play.** A Vault entry becomes a library game (through the usual review sheet, or automatically for confident Batocera favourites) only when it was **played more than 10 minutes** (`600 s`, one named constant shared by both importers — this *raises* Batocera's earlier 5-minute rule), is a favourite (Batocera), or is promoted by hand. Below that it was a test launch.
- **Batocera**: unchanged otherwise (§15).
- **PS Plus**: a `PS_PLUS` entitlement whose joined play time (game list) is ≤ 10 min — including never launched — goes to the Vault instead of the library or the *Ignored* bucket; one played > 10 min is imported as the owned-via-subscription copy with the "+" badge (§13.3). Real purchases (`membership: NONE`) are never vaulted: bought-and-unplayed games are my backlog. Cross-gen twins are one Vault entry. A claim that disappears from the purchases list leaves the Vault silently (nothing of mine is lost).
- A Vault entry knows its source, platform, title, and whatever metadata the source has (Batocera: genre / series / developer / year / rating from the gamelist; PSN: almost nothing — name, platform, cover URL). PS Plus entries therefore get their traits from **IGDB**, matched by name + platform in capped background batches (like the Batocera favourites: ≤ 60 per run, results persisted, never re-queried), so they can be scored by taste; until matched they are browsable but not suggested.

**Three fates for a review row** *(owner question, 2026-09-20)*. In every import review sheet: **ticked** = imported into the library now; **unticked** = "not this time" — nothing is stored, the row stays under *New* and comes back at the next sync (pre-ticked again when the match is confident); **Ignore** = never propose it again (restorable from *Ignored*). None of these sends a game to the Vault — only the automatic 10-minute rule does. So there is a fourth, explicit action for games I own or can play but do not consider backlog (bundle filler, free claims, things I bought and will probably never start): **"Send to the Vault"** — per row and for the ticked/unticked selection of a group ("Send the unticked rows to the Vault"). A purchased game sent there is remembered as *owned* (it is not a subscription claim and never gets the PS Plus boost or deadline), is not proposed again by later syncs, can be promoted to the library from the Vault at any time, and joins "From the vault" once matched. Works for every importer (GOG and Delicious rows too).

**Play Next ▸ "From the vault".** One row, both sources, never mixed into the backlog picks; scored by my taste (traits vs my tiers, direct links, crowd rating as a prior, time fit when a length is known — IGDB-matched PS Plus games usually have one, ROMs usually do not), with the weekly rotation and *Not Interested*. Pinned Batocera favourites keep their place. Hidden while Play Next has "not enough data".

**PS Plus deadline — "play them before I unsubscribe".** Settings ▸ PlayStation: *"I plan to leave PS Plus around [month year]"* (optional; clearing it removes every effect below). With a date set:
- every PS Plus game — library copies with the "+" badge *and* Vault entries — gets a **boost that ramps up** as the date approaches: modest beyond a year, clearly visible inside six months, strongest in the last three (a smooth function of months left, constants in one place, excluded from the taste backtest like the other situational terms);
- **finishability matters more than urgency**: the boost is multiplied by how comfortably the game still fits — personal length (§8, play style) vs the hours I have until the date at my weekly pace (§15 pace). A 22-hour game with nine months left gets the full boost; a 120-hour one fades out once it no longer fits, rather than nagging;
- reason line: "+ leaves with PS Plus · ~9 months left · about 22 h for you"; in the regular picks the boost can lift a PS Plus game above near-equals but never above a clearly better fit; in "From the vault" PS Plus entries are interleaved with ROMs by score, so with a date set they naturally lead;
- this replaces the earlier on/off option "Prefer expiring PS Plus games" (kept only as the fallback when no date is set: a small constant boost, **on** by default).

**Build order.** (1) Rename + generalise: `rom_catalog` becomes the Vault's table (`source` already distinguishes entries; add what PS Plus entries need — external id, cover URL, membership, matched IGDB id — in migration v11), the 10-minute gate in both importers, the sidebar section with two rows, the browser filtered by source. (2) PS Plus ingestion from the PSN staging rows + background IGDB trait matching. (3) "From the vault" scorer over both sources + the PS Plus deadline setting and ramp.

**Built — wave 14 (data / logic / ingestion; UI partly wired).** ✅ **(1) Rename + generalise.** Migration **v11** (additive `ADD COLUMN`, FTS untouched, no rebuild) gives `rom_catalog` the PS Plus columns (`external_id`, `cover_url`, `membership`, `cross_gen_note`, `igdb_id`, `length_main_s` / `length_complete_s`, `traits_json`, `igdb_rating`, `match_state`, `matched_at`); a PS Plus claim is a row with `source='psn'`, `system=<slug>`, `relative_path=<external id>`, keeping `UNIQUE(source, system, relative_path)`. The sidebar is now **THE VAULT** with one row per source (*Batocera ROMs* / *PS Plus*), each shown only when non-empty, driven by **one** per-source observation (`VaultSourceCounts`) kept off the library counts; `SidebarSelection.vault(VaultSource)` (ids `vault:batocera` / `vault:psn`, old sort-key migrated); the browser (`RomCatalogueView`/`Model`) is scoped by source. The 10-minute gate is already the shared `ImportPolicy.vaultPlaytimeGateSeconds` (§16, prior wave). ✅ **(2) PS Plus ingestion.** Pure `PSNMapping.vaultEntries` (same merge as staging; cross-gen twins → one entry; cover URL captured; gate edges 599/600/601 share the constant) flows through the existing coordinator (`ImportFetchResult`/`ImportSyncResult` gained additive `vaultEntries`/`vaultPresentIDs`); the PSN presenter upserts them via `RomCatalogStore.syncPSNVault` after each sync (claims that vanish or cross the gate get `removed_at`). ✅ **(3) scorer + deadline.** `DiscoverScorer` scores matched PS Plus entries beside ROMs with a time-fit term when a length is known (ROMs neutral), a source-aware crowd prior, and the deadline term; the pure `PSPlusDeadlineBoost` (Hill urgency `1/(1+(m/6)²)` × finishability, one `maxBoost`) is wired into `RecommendationEngine` for library `ownedOnlyViaSubscription` copies (gated, backtest-neutral) and into the vault scorer; the constant "Prioritise PS Plus games" fallback is the no-date case. **Still to wire (see `docs/LIMITATIONS.md`):** the background IGDB **trait-matching pass** for PS Plus entries (store side ready: `unmatchedPSN` / `setVaultMatch` / `setVaultNoMatch` / `psnMatchProgress`); the browser's **PS-Plus-specific row** (remote cover, "PS Plus"/"+" marker, *Add to Library…* through the review, *Open in PlayStation Store*); the Play Next **"From the vault"** row wired to `vaultPool` over both sources (currently the Batocera-only Discover row remains, scorer aside); the Settings **deadline month/year picker** (engine + scorer already accept `psPlusMonthsLeft`); the review-sheet collapsed **"In the Vault (N)"** group; promotion-on-play **linking** (`setPromotedByExternalID` ready).

**Built — wave 15 (UI wired).** ✅ **IGDB trait-matching pass.** `VaultTraitMatcher` (a service like `BatoceraFavouriteAutoAdd`) matches up to 60 unmatched PS Plus entries per run through the existing `ImportMatcher` + IGDB rate limiter (™-stripped title via the PSN cleaner, platform-constrained, top-bucket-only); a confident match does **one** batch `games(ids:)` + `timeToBeat` call and persists IGDB id, traits (genres/themes/keywords/franchise/developer + synthesised genre/decade), rating and main/complete time-to-beat via `setVaultMatch`, everything else `setVaultNoMatch` (never re-queried). `VaultTraitMatchModel` runs it after each PSN sync and once at launch (live + IGDB configured only), one at a time, cancellable; Settings ▸ PlayStation shows "Vault: N of M matched · next batch at the next sync" + **Match more now**. IGDB cost ≈ one autocomplete per entry + two batch calls per run (≈ 62 requests/60-batch; ~180–310 entries ⇒ 3–6 runs). ✅ **PS Plus browser row** — remote cover (in-memory `VaultCoverLoader`, never the cover folder), title, platform pill, the "+" marker (#0070D1 on #FFC300), cross-gen note, IGDB year/genre/rating once matched, match state, and **Add to Library…** (owned-via-subscription copy through the shared staging commit, links the row via `setPromotedByExternalID`), **Not Interested**, **Find match…** (reuses the reconcile link sheet). *Open in PlayStation Store is omitted — no correct product URL is derivable (the entitlement id is not a store/concept id).* ✅ **"From the vault" deadline wiring** — the Settings **month/year picker** (`PSPlusDeadlinePreferences`, past-date hint, Clear) threads `psPlusMonthsLeft` + `PlayPace` into both scorers (regular picks + vault), recompute-on-change; the option is renamed **"Prioritise PS Plus games"**, on by default in the UI (engine default off). ✅ **Review sheet** — auto-vaulted claims show in a collapsed, read-only **"In the Vault (N)"** group with **Show in the Vault**; promotion-on-play linking runs after a PSN commit; the pc/mac platform switch shows only for GOG/Delicious; PSN group headers show "ticked / total". ✅ **Matching progress** — the sync sheet shows a determinate bar + "Matching N of M · Title" + ETA. **Foundations only (see `docs/LIMITATIONS.md §5b`):** the explicit **"Send to the Vault"** review action (migration **v12** `rom_catalog.owned`, `RomCatalogStore.sendToVault`/`deleteEntries`, the `owned` scorer/browser handling are in; the per-row/group action + `ImportDecision.vault` + undo + GOG/Delicious sources are not wired); resume-after-cancel without re-querying (matches are not yet persisted per item).

**Built — wave 16 ("Send to the Vault" + resume after cancel).** ✅ **The fourth fate is wired.** Migration **v13** adds `import_titles.vaulted` (`ImportDecision.vault` / `.unvault`), so the decision **persists** — a later sync never re-proposes or re-lists a vaulted row. The import review sheet has a per-row **Send to the Vault** (row menu), a group action ("Send N to the Vault" in the bucket header + per PSN group), a collapsed read-only **In the Vault (N)** group with **Show in the Vault** and a per-row **Bring back**, and a per-model **Undo** (`undoLastVaultSend`). Vault rows are written through `RomCatalogStore.sendToVault` with `owned = 1` for GOG / Delicious / a purchased PSN copy and `owned = 0` + `membership` for a hand-vaulted PS Plus claim (which keeps the deadline boost). `VaultSource` gained **`.gog`** and **`.delicious`** (stable ids `vault:gog` / `vault:delicious`), so those rows browse in their own sidebar rows (shown only when count > 0) and are suggested by "From the vault" (`DiscoverScorer.vaultPool` over all sources; an `owned` entry gets no PS Plus term). ✅ **Resume matching after cancel (§5.1).** The coordinator persists each *New* row's outcome (`match_attempted_at` + a `match_json` blob = the `ScanMatchOutcome` + any bundle expansion), so a cancelled-then-restarted or a second sync **skips already-attempted titles** (never re-querying IGDB), restores their alternatives and bundle members, and re-queries only never-attempted titles and no-match ones older than 30 days (or on `ImportStagingStore.clearMatchAttempt` — the "Re-match" seam); the progress shows "… · N already matched". ✅ **Committed compilations stop re-listing as New** — the compilation commit marks the staging row matched (first member); re-import stays idempotent. ✅ **Bundles-to-Expand** — `bundleExpansionCandidates()` excludes games dismissed as "not a bundle" (persisted in `app_state`, `dismissBundleCandidate`), the reconcile presenter auto-dismisses a non-bundle on the IGDB check, and a `BundlesToExpandModel` + `BundlesToExpandView` render the list (mounting it beside the Unlinked list is a follow-up — see `docs/LIMITATIONS.md §5b`).

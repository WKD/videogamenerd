# HowLongToBeat fallback (PLAN §5.3)

IGDB is the default source of completion-time estimates. On the owner's library it
covers ~231 of 376 games; the ~145 without a time are invisible to Play Next's time
fit. This feature fills **only the gaps**, on demand, from HowLongToBeat — a public
site with a **private, frail search endpoint** whose path/key rotates and breaks.

If HLTB breaks for good, the feature degrades to the "Open on HowLongToBeat" link and
nothing else is affected.

## How it works

1. **Trigger** (never automatic, never at launch):
   - Inspector ▸ **Refresh from HowLongToBeat** — one game, the single per-game HLTB
     action *(wave 19)*: always in the Playtime section's action row (a real bordered
     button next to the "Open on HowLongToBeat" link), shown for every game — including one
     whose times already come from HLTB (then a re-check). Always the **`.replace`** mode
     (`HLTBFetchPresenter.refreshOne`): a confident match overwrites the three times with an
     Undo-able banner (⌘Z), an ambiguous one opens a picker, a game HLTB doesn't know is left
     unchanged and stays flagged. It fills gaps as a special case, and never touches the
     owner's own playtime. (The old gap-only "Fetch from HowLongToBeat" is gone; the ⚠︎
     suspicious-estimate row now just points at this button.)
   - Game ▸ **Fetch Missing Time Estimates…** — the current selection, or every game
     with no estimate at all. Progress + Cancel, then a summary
     "n filled · m not found · k ambiguous"; ambiguous games are resolved one-by-one
     with the same picker.
   - Game ▸ **Refresh Time Estimates from HowLongToBeat…** — the bulk `.replace` for the
     selection (or every flagged game), confirming the count first; one Undo restores the batch.
2. **Search** (`HLTBClient`, an actor): endpoint discovery → per-session `/init` auth token
   (both once per run) → one POST search per title.
3. **Match** (`HLTBMatcher`, pure): `TitleNormalizer` + `FuzzyMatch` over the
   candidate's name + aliases, release year ± 1 as the tie-breaker → confident /
   ambiguous / not-found.
4. **Fill** (`LibraryStore.applyHLTBTimes`, one transaction) with the wave-21 mapping
   (`HLTBCandidate.mappedTimes`, see "Mapping" below): main ← Main+Extra, else Main Story;
   rushed ← Main Story; completionist ← Completionist. **Only empty
   fields are filled** (an IGDB or hand-typed value is never overwritten). `ttb_source`
   becomes `'hltb'` only when a value was written and the game had no prior source; a
   game that already carried IGDB times keeps its `igdb` label and just gains the
   filled field. The HLTB game id is stored in `games.hltb_id` so "Open on
   HowLongToBeat" opens the exact page.

Play Next reads `ttb_normally_s` / `ttb_completely_s` straight from `games`, regardless
of source, so an HLTB-only game gets a time fit exactly like an IGDB one.

## The pinned reference (where the request shape comes from)

Everything HLTB-specific lives in **one file**: `VGN/Services/TimeToBeat/HLTB/HLTBEndpoint.swift`.
Ported from the maintained open-source client and **verified against the live site**:

- **ScrappyCocco/HowLongToBeat-PythonAPI** — branch `master`, read verbatim **2026-09-19**
  (`howlongtobeatpy/howlongtobeatpy/HTMLRequests.py` for discovery + the `/init` auth token +
  headers + the POST body; `JSONResultParser.py` for the response field names + seconds→hours).
- Cross-checked against **ckatzorke/howlongtobeat** (JS wrapper).
- **Decisively: read `howlongtobeat.com`'s own turbopack app chunk live on 2026-09-19** — the
  mechanics below are what the site actually does, not just what a wrapper claims.

Today's mechanics (**verified live 2026-09-19**):

- Base site `https://howlongtobeat.com/`. The CDN **403s bare clients**, so every GET carries a
  desktop `User-Agent`, `Accept: text/html,…`, `Accept-Language`.
- **Endpoint discovery.** GET the homepage → its `/_next/static/chunks/*.js` chunks are turbopack
  builds with **opaque hashed names** (no `_app`/`main` any more), so we try them in document
  order and take the one chunk that contains a `fetch("/api/<path>", { … method:"POST" … })`;
  `<path>` is a plain slashed literal — **currently `api/search/site`** — with `api/s/` as the
  historical fallback. (No token is concatenated into the URL — that was the first port's mistake.)
- **Per-session auth (new vs. the first port).** GET `<searchPath>/init?t=<ms>` →
  `{ token, hpKey, hpVal }`. The search then sends headers `x-auth-token: token`,
  `x-hp-key: hpKey`, `x-hp-val: hpVal`, **and** injects `body[hpKey] = hpVal` into the POST
  payload. Field names are read defensively (any init field whose name contains `key`/`val`), so a
  rename survives. The token embeds the caller IP + UA and **expires** — the client fetches it once
  per run and does not refresh mid-run (a lapse surfaces as a 403 stop; the owner re-runs).
- Search headers also: `Content-Type: application/json`, `Accept: */*`, `Referer` + `Origin`.
- POST body: `{ searchType:"games", searchTerms:[…], searchPage, size,
  searchOptions:{ games:{…}, … }, useCache:true, <hpKey>:<hpVal> }`.
- Response: `{ data: [ { game_id, game_name, game_alias, release_world, comp_main,
  comp_plus, comp_100, profile_platform, … } ], count, … }`. `comp_*` are **seconds** (verified:
  Bloodborne `comp_main == 115887` ≈ 32 h); `release_world` is the world release year.

### Live request log (verification, 2026-09-19)

15 requests total, all to `howlongtobeat.com`, serial, ≥ 2 s apart, none blocked:

| # | method · path | status | note |
|---|---|---|---|
| 1 | GET `/` | 200 | 12 turbopack chunks listed |
| 2 | GET `/_next/static/chunks/1ygls5xciw8_y.js` | 200 | no `/api/` |
| 3 | GET `/_next/static/chunks/0vrbb9n4se1y6.js` | 200 | contains `fetch("/api/search/site",{method:"POST"…})` |
| 4 | GET `/api/search/site/init?t=…` | 200 | `{token, hpKey, hpVal}` |
| 5 | POST `/api/search/site` "Bloodborne" | 200 | 6 results, `data[]`, seconds confirmed |
| 6–14 | homepage+chunks+init + 5 searches (recorder run) | 200 | recorded the fixtures (9 req) |
| 15 | GET `/` (interpreted-mode sync-IO proof) | 200 | recorder runs to completion under `swift file.swift` |

## Politeness / frailty rules (the same importer machinery)

- **URL allow-list**: `howlongtobeat.com` only (`HLTBClient.allowList`).
- **Serial + paced**: ≥ 1.5 s (jittered) between requests (`ImportPolicy.hltb`).
- **Budget**: 250 requests per run (`ImportPolicy.hltb.budget`).
- **Cache** through the shared `import_cache` with `source = "hltb"`: a hit is cached
  **180 days** (`ImportPolicy.hltbHitTTL`), a "no result" **30 days**
  (`ImportPolicy.hltbMissTTL`). A cached answer, hit or miss, costs **zero** requests;
  a re-run only queries what is still missing and not negatively cached.
- **Stop on the first unexpected response** — HTML/captcha, 403, 429, not-JSON, schema
  mismatch, discovery failure. **No retries, no variants.** The run stops with a clear
  message and "VGN stopped and made no further requests."; a redacted excerpt is logged
  to `import_cache_rejects` (no credentials exist for HLTB).

## What breaks first, and where to fix it

The three things that rotate, in rough order of likelihood: the **endpoint path**
(`api/search/site` today), the **`/init` token scheme** (the `hpKey`/`hpVal` field names, the
`x-hp-*` header names, or the requirement itself), and the **DTO** field names. Any of them shows
as a clean stop on the first fetch — `schemaMismatch` / discovery-failure / `authChallenge` (403) —
nothing corrupted; the feature falls back to the "Open on HowLongToBeat" link.

**The only file to fix is `HLTBEndpoint.swift`.** Re-read the live app chunk (or the current
`HTMLRequests.py` of the reference repo) and update, as needed: `resolveDiscovery` (the POST-fetch
regex / path), `parseAuth` (`/init` shape), `headers` / `searchPayload` (the header + body-field
injection), `authInitRequest` (the init URL), and the `SearchResponse` DTO. Then re-record fixtures
and bump the "verified <date>" notes here and in the file header. If the token step itself changes
(e.g. moves back to no-auth, or gains a challenge), the client's `ensureSession` in
`HLTBClient.swift` is the only other place that touches the flow.

## Fill vs. replace (PLAN §5.3)

The same client, pacing, per-run cap, matcher and stop-on-first-unexpected-response serve two
writes, selected by a `mode`:
- **`.fillGaps`** — "Fetch Missing Time Estimates…": fills only empty `ttb_*` columns
  (`LibraryStore.applyHLTBTimes`), never overwriting an IGDB / hand-typed value.
- **`.replace`** — "Refresh Time Estimates from HowLongToBeat…" (the suspicious-estimate repair):
  overwrites all three times with HLTB's and stamps `ttb_source = 'hltb'`
  (`LibraryStore.replaceHLTBTimes`), so the game becomes the reference and leaves the
  Suspicious-Estimate filter. A game HLTB doesn't know is left untouched (stays flagged). The
  owner's own playtime columns are never touched. One `HLTBTimeSnapshot` per game is collected so
  the whole batch is a single Undo. The replace bulk sheet confirms the count first.

## Caching, platforms, the query ladder & linking (wave 20)

Owner asks (2026-09-20): cache the reply on refresh; use my library platforms to disambiguate;
a manual lookup/link UI for long / edition-heavy titles; and store an HLTB id with matched games
so later refreshes are exact.

- **Cache the reply (D1).** A search already reads cache-first (`search:<canonical title>`, found
  180 d / no-result 30 d; a valid reply — including an *ambiguous* multi-candidate one — is stored;
  an error/reject is never cached). Wave 20 adds a **second entry keyed by the HLTB id**
  (`id:<hltbID>` → the chosen candidate's JSON incl. its canonical HLTB name, same 180 d TTL),
  written whenever a candidate is applied / linked / picked. It powers exact refresh-by-id.
  - ~~**The Refresh rule I settled on.** … a Refresh older than 24 h (`ImportPolicy.hltbRefreshFloor`)
    goes to the network …~~ **Superseded in wave 21** — there is no refresh floor any more; see
    "Wave 21" below.
- **Platforms disambiguate (D2).** `timeToBeatFacts` now returns each game's **effective platforms**
  (`LibraryQuery.effectivePlatformsSQL`) and its stored `hltb_id`. `HLTBPlatformMap` (pure, in
  `VGN/Matching`) maps VGN slugs ↔ HLTB platform names (spelling lint against the fixtures).
  `HLTBMatcher` takes `librarySlugs` and uses platform overlap as a **tie-breaker only**: among
  equally-good titles it prefers the one on one of my platforms (and closest year); it never promotes
  a worse title, and two candidates still tied after platform + year stay ambiguous. The picker shows
  "In your library: …" and emphasises the overlapping candidate platforms.
- **Query ladder for long titles (D3).** `HLTBQueryLadder` (pure) expands a title into ≤ 3 ordered
  queries — as-is; edition/packaging noise stripped (trademark symbols, `PlatformTail`, trailing
  "Complete/GOTY/Definitive/Deluxe/Ultimate/Special/Collector's/Limited/Anniversary/Enhanced/
  Legendary/Royal Edition", "Director's Cut", a conservative "Remastered"/"HD", "Game of the …
  Edition") with the subtitle kept; then also drop the subtitle. Never strips a numeral or a bare
  qualifier ("Doom 3", "Resident Evil 2", "Persona 5 Royal" survive). The fill service stops at the
  first confident match.
- **Exact refresh by id (D4).** A game with `hltb_id` refreshes via
  `HLTBFillService.resolveLinked`: it searches by the remembered canonical name (ladder fallback) and
  picks the candidate whose id equals the stored id — never ambiguous, never re-asks. If the id is
  gone from the reply it falls back to normal matching and says "not found any more — pick again".
  Bulk sorts id-linked games first and the summary adds "linked by id" / "links lost".
- **Manual "Find on HowLongToBeat…" (D5).** `HLTBFindModel` + `HLTBFindSheet`: a Quick-Add-style
  search prefilled with the D3-cleaned title, **polite** — search on Return or an 800 ms pause, ≥ 3
  chars, identical queries served from an in-session cache, a visible per-session request counter with
  the per-run cap, a clean stop on the first reject. Actions: **Link & Use These Times**
  (`replaceHLTBTimes`), **Link Only** (`setHLTBLink`, times untouched), **Unlink** — each one undo
  step. Inert (no network) in sample/seeded/test modes. Reachable from the inspector, the grid context
  menu and the Game menu; the bulk sheet's unresolved rows get a per-row **Find…**.

## Wave 21 — Main-Story-only games, order-free matching, Refresh = cache

Three owner reports (checked read-only against the real library + HLTB cache): *Akira* (NES) linked
to HLTB but shown with **no estimate** (HLTB lists only a Main Story; our mapping put it in the rushed
slot, and "rushed-only ⇒ unmeasured" hid it); *The Beast Within: A Gabriel Knight Mystery* **not
found** although the search returned *Gabriel Knight II: The Beast Within* (1995); and **Refresh went
to the network** for anything older than a day.

### Mapping (the write rule)

`HLTBCandidate.mappedTimes` — the one place HLTB columns become VGN times; used by the fill
(`applyHLTBTimes`, empty fields only), the replace (`replaceHLTBTimes`: Refresh, bulk Refresh, the
picker, **Link & Use**):

| VGN column | value |
|---|---|
| `ttb_normally_s` (Main) | `comp_plus` if > 0, else `comp_main` if > 0, else `comp_all` if > 0 (only when both main and plus are 0) |
| `ttb_hastily_s` (Rushed) | `comp_main` if > 0, else nil |
| `ttb_completely_s` (Completionist) | `comp_100` if > 0, else nil — never fabricated |

`comp_all` (All Styles) is a real average of real runs but mixes play styles, so it is the last
resort and only ever fills the main slot. `comp_all` and `comp_{main,plus,100}_count` are parsed
additively (optional `Codable` fields — pre-wave-21 `id:` cache entries still decode). Surfaces: the
single-game banner and the bulk summary say "Main+Extra not on HowLongToBeat — main story used"; the
picker / Find rows say "Main Story only (2 reports) — used as main".

### The read rule (rows written before wave 21 — no data change)

PLAN §4 inv. 5 forbids a repair pass, so rows already written as rushed-only are read differently: the
**effective main** is `ttb_normally_s`, or — only when `ttb_source = 'hltb'` and the main is empty —
`ttb_hastily_s` (`LibraryQuery.effectiveMainSQL` ≡ `EstimateSanity.effectiveMain`). It replaces the
raw main everywhere in the ONE length expression (`lengthEstimateExpr` → BY LENGTH shelves, Unmeasured,
the Playtime filter's No Estimate, the Length sort, Stats backlog) and its Swift mirror
(`EstimateSanity.lengthInputs` → Play Next). IGDB-sourced rushed-only rows keep "rushed-only ⇒
unmeasured". The Suspicious-Estimate predicate is unchanged (hltb rows are never flagged). The
inspector's Main row shows the effective main with the tooltip "HowLongToBeat lists only Main Story
for this game." and a caption; Rushed shows the same value. A Refresh then rewrites the row with the
new mapping (from cache, zero requests). The inspector does not show the report count (the counts
live in the cached reply, not in `games`) — the picker / Find rows do.

### Matching: order-free token set

`TitleTokenSet` (pure, `VGN/Matching`). Significant tokens = `TitleNormalizer` at `.articleless`
(fold, lowercase, roman → arabic, `&` → and, punctuation, leading article, edition tags) minus
`a/an/the/of/and`; a **series-tag subtitle** ("A Gabriel Knight Mystery": `a|an` + 1–4 words +
mystery/adventure/story/tale/saga/novel/thriller/game) contributes only its series name. Score:
equal sets → 0.95; one set ⊂ the other → `0.90 + 0.05 · |small|/|large|` **only when** `|small| ≥ 3`,
coverage ≥ 0.75, no extra token is a numeral (unless the smaller title had a series tag — the "A
<Series> Mystery" form drops the number) and no extra token is a separate-game word (remake,
remastered, hd, origins, …); otherwise Dice `2|A∩B|/(|A|+|B|)`. `HLTBMatcher` base =
`max(FuzzyMatch, TitleTokenSet)` against the **library title and the ladder query** (the old matcher
scored rung 3's candidates against the rung-3 query only — the actual cause of the owner's "not
found"). Thresholds (0.90 / 0.74, margin 0.05, year ± 0.06) unchanged.

| pair | token set | verdict |
|---|---|---|
| The Beast Within: A Gabriel Knight Mystery ↔ Gabriel Knight II: The Beast Within | 0.94 | confident (+0.06 year 1995) |
| … ↔ Slain 2: The Beast Within (2027) | 0.5 | not plausible |
| Resident Evil 2 ↔ Resident Evil · Doom 3 ↔ Doom | Dice (0.8 / 0.67) | never confident |
| Gabriel Knight: Sins of the Fathers ↔ Gabriel Knight II: The Beast Within | 0.44 | not plausible |
| Tomb Raider ↔ Rise of the Tomb Raider · FF VII ↔ FF VII Remake | Dice | never confident |

### Ladder

Still ≤ 3 queries, full title first. When the subtitle is a series tag, rung 2 is the
**subtitle-swapped** query ("The Beast Within: A Gabriel Knight Mystery" → "Gabriel Knight Beast
Within"), otherwise the noise-stripped form; rung 3 drops the subtitle. Candidates from every rung are
**pooled**: `notFound` only when nothing plausible came back from any rung; otherwise at least
`ambiguous` (the picker, with my platforms + years). The bulk summary reads "n filled · k need your
pick · m no HLTB entry" (+ "unchanged", "linked by id", "links lost", "x from cache · y from network").

### Cache rule

The 24 h refresh floor is gone (`ImportPolicy.hltbRefreshFloor` and `HLTBFreshnessPolicy.refresh`
removed). Refresh — single and bulk — serves any valid cached reply inside its TTL (found 180 d /
no-result 30 d) exactly like Fetch Missing: a Refresh re-applies *our* mapping + matching, and HLTB's
numbers move slowly. The fill service first runs a **cache pass** over every rung
(`HLTBSearching.cachedCandidates`, zero requests) and only asks the network for rungs the cache did not
answer when nothing cached was confident. **"Ask HowLongToBeat Again"** (Game menu, one selected game;
`.bypassOne`) is the one explicit bypass — it asks every rung of that one game again and stores the new
replies; a bulk run never bypasses. The single-game banner says "(from cache, N days old)" or
"(asked HowLongToBeat)".

Not built: **Source: HowLongToBeat filter** (Playtime ▸ Estimate Source) — it would add a facet to
`LibraryFilter` / `FilterChip` / the filter menu in the same wave another lane adds the *Holds Up*
facet there; filed for a later wave.

## Fixtures / recording

`scripts/record-hltb-fixtures.swift` — bounded (≤ 25 requests, ≥ 2 s apart, serial, stop on the
first unexpected response), unbuffered, 15 s per-request timeout, synchronous I/O so it **runs to
completion both interpreted (`swift scripts/record-hltb-fixtures.swift`) and compiled**
(`swiftc -O -o /tmp/hltb-rec scripts/record-hltb-fixtures.swift && /tmp/hltb-rec`); it prints a
request count. Run it **from the repo root** so `VGNTests/Fixtures/` resolves.

Committed fixtures:
- `hltb-search-{bloodborne,celeste,final-fantasy-vii,the-legend-of-zelda-the-wind-waker,empty}.json`
  — **recorded from real searches** (2026-09-19), trimmed to the first ~5 results. Public game data,
  no PII (`userData` comes back `[]` for an anonymous client).
- `hltb-discovery-home.html`, `hltb-discovery-app.js` — **hand-authored minimal excerpts** mirroring
  the real turbopack homepage + the one app chunk's two `/api/` fetches (the init GET and the POST
  search). The recorder never commits whole minified bundles.
- `hltb-link-{akira,beast-within}.json` — **synthetic** (wave 21), built from the shapes of the
  owner's cached replies (game ids / names / years / times / counts only, no URLs, no user data).
- `hltb-init.json` — a **sanitised** `{token, hpKey, hpVal}` (the live token embeds the caller IP +
  UA, so it is never recorded verbatim). The parser reads it defensively, so a placeholder is fine.

Unit tests never touch the network.

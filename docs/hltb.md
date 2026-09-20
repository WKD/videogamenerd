# HowLongToBeat fallback (PLAN §5.3)

IGDB is the default source of completion-time estimates. On the owner's library it
covers ~231 of 376 games; the ~145 without a time are invisible to Play Next's time
fit. This feature fills **only the gaps**, on demand, from HowLongToBeat — a public
site with a **private, frail search endpoint** whose path/key rotates and breaks.

If HLTB breaks for good, the feature degrades to the "Open on HowLongToBeat" link and
nothing else is affected.

## How it works

1. **Trigger** (never automatic, never at launch):
   - Inspector ▸ **Fetch from HowLongToBeat** — one game. A confident match fills
     directly with an Undo-able banner (⌘Z); an ambiguous one opens a picker sheet.
   - Game ▸ **Fetch Missing Time Estimates…** — the current selection, or every game
     with no estimate at all. Progress + Cancel, then a summary
     "n filled · m not found · k ambiguous"; ambiguous games are resolved one-by-one
     with the same picker.
2. **Search** (`HLTBClient`, an actor): endpoint discovery → per-session `/init` auth token
   (both once per run) → one POST search per title.
3. **Match** (`HLTBMatcher`, pure): `TitleNormalizer` + `FuzzyMatch` over the
   candidate's name + aliases, release year ± 1 as the tie-breaker → confident /
   ambiguous / not-found.
4. **Fill** (`LibraryStore.applyHLTBTimes`, one transaction): Main → `ttb_hastily_s`,
   Main+Extra → `ttb_normally_s`, Completionist → `ttb_completely_s`. **Only empty
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
- `hltb-init.json` — a **sanitised** `{token, hpKey, hpVal}` (the live token embeds the caller IP +
  UA, so it is never recorded verbatim). The parser reads it defensively, so a placeholder is fine.

Unit tests never touch the network.

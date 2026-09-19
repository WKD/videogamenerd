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
2. **Search** (`HLTBClient`, an actor): endpoint discovery → one POST search per title.
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
Ported from the maintained open-source client:

- **ScrappyCocco/HowLongToBeat-PythonAPI** — branch `master`, read **2026-09-19**
  (`howlongtobeatpy/HTMLRequests.py` for endpoint discovery + headers + the POST body,
  `howlongtobeatpy/JSONResultParser.py` for the response field names).
- Cross-checked against **ckatzorke/howlongtobeat** (JS wrapper), read 2026-09-19.

Today's mechanics (2026-09-19):

- Base site `https://howlongtobeat.com/`.
- The search endpoint path is **not constant**. The Next.js app bundles a
  `fetch("/api/<word>/<token>…", { method: "POST" })` whose `<token>` is assembled
  from string literals in the JS. We discover it: GET the homepage → find a
  `/_next/static/chunks/*.js` app chunk → extract the quoted `/api/…` base path plus
  the concatenated token (with `api/s/` as a historical fallback).
- Headers: `Content-Type: application/json`, `Accept: */*`, a desktop `User-Agent`
  (the site 403s without one), `Referer` + `Origin` the site itself.
- POST body: `{ searchType:"games", searchTerms:[…], searchPage, size,
  searchOptions:{ games:{…}, … }, useCache:true }`.
- Response: `{ data: [ { game_id, game_name, game_alias, release_world, comp_main,
  comp_plus, comp_100, profile_platform, … } ] }`. `comp_*` are **seconds**;
  `release_world` is the world release year.

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

When HLTB changes its search endpoint again (it will), the symptom is a **schema
mismatch** or **discovery failure** on the first fetch — a clear stop, nothing
corrupted. **The only file to fix is `HLTBEndpoint.swift`**: re-check the current
`HTMLRequests.py` of the reference repo for the new path/token/payload shape and update
`resolveDiscovery` / `searchPayload` / the DTO. Re-record fixtures with
`scripts/record-hltb-fixtures.swift` and update the "read <date>" note here and in the
file header.

## Fixtures / recording

`scripts/record-hltb-fixtures.swift` (bounded: ≤ 12 requests, ≥ 2 s apart, stop on the
first unexpected response) records `VGNTests/Fixtures/hltb-*.json`. The committed
synthetic fixtures are built from the reference client's documented shapes so the whole
feature is testable offline; unit tests never touch the network.

# PSN import — S0 scaffolding notes and the `ASSUMPTION(S0)` checklist

State after **step S0** (PLAN §13.5): the PSN vertical (auth, client, DTOs, validator,
mapping, importer, commit) + the development response cache + schema v8, all built and
tested on **synthetic fixtures only**. **Not one request has been made to any
`playstation.com` / `playstation.net` / `sony.com` host.** Every guess about a real PSN
response is marked in code with `// ASSUMPTION(S0):` and listed here for the gated live
steps S1–S8 (run by the orchestrator *with the owner*, one tiny probe at a time) to
confirm or correct. The owner's whole digital library hangs on this account, so the client
is built to be boring: read-only allow-list, user-initiated, serial, paced ≥ 1.5 s,
budget 40/sync, no retry loops, cache-first, stop-and-ask on anything unexpected.

## Sources read (ported from, pinned to a commit)

- **`achievements-app/psn-api`** (TypeScript, MIT) — commit
  `1e9d9a806fcd884a4ddee8086bfe92594611da9f` (2026-08-15). The authority for: the OAuth
  flow (`exchangeNpssoForAccessCode` → `exchangeAccessCodeForAuthTokens` →
  `exchangeRefreshTokenForAuthTokens`), `getUserTitles` (trophy titles), `getUserPlayedGames`
  (game list), and `getPurchasedGames` (GraphQL `getPurchasedGameList`). Files read:
  `src/authenticate/AUTH_BASE_URL.ts`, `exchangeNpssoForAccessCode.ts`,
  `exchangeAccessCodeForAuthTokens.ts`, `exchangeRefreshTokenForAuthTokens.ts`,
  `src/trophy/TROPHY_BASE_URL.ts`, `src/trophy/user/getUserTitles.ts`,
  `src/user/USER_BASE_URL.ts`, `src/user/getUserPlayedGames.ts`,
  `src/graphql/GRAPHQL_BASE_URL.ts`, `src/graphql/operationHashes.ts`,
  `src/graphql/getPurchasedGames.ts`, `src/models/purchased-games-response.model.ts`.
- **`isFakeAccount/psnawp`** (Python) — cross-check on the endpoints, the profile envelope
  (`profile` wrapper), and the trophy/game-list field names.
- **`andshrew/PlayStation-Trophies`** — endpoint notes cross-check (host, npServiceName).

### Ported request shapes (all in code, all `ASSUMPTION(S0)`)

| What | Value | File |
|---|---|---|
| Auth base | `https://ca.account.sony.com/api/authz/v3/oauth` | `PSNAuthConfiguration+MobileApp.swift` |
| client_id | `09515159-7237-4370-9b40-3806e67c0891` | same |
| token Basic auth | base64 of `09515159-…:ucPjka5tntB2KqsP` | same |
| redirect_uri | `com.scee.psxandroid.scecompcall://redirect` | same |
| scope | `psn:mobile.v2.core psn:clientapp` | same |
| Profile | `https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles` | `PSNClient.swift` |
| Trophy titles | `https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles?npServiceName={trophy2\|trophy}&limit=&offset=` | `PSNClient.swift` |
| Game list | `https://m.np.playstation.com/api/gamelist/v2/users/me/titles?limit=&offset=` | `PSNClient.swift` |
| Purchases | `https://web.np.playstation.com/api/graphql/v1/op?operationName=getPurchasedGameList&variables=…&extensions=…` | `PSNClient.swift` |
| Persisted-query hash | `827a423f6a8ddca4107ac01395af2ec0eafd8396fc7fa204aaf9b7ed2eefa168` | `PSNClient.purchasedGamesHash` |

### Disagreements between sources (for the owner, before S1)

1. **Profile envelope** — §13.3 says `…/me/profiles`; psnawp shows the payload nested under
   a `profile` key, while some clients read a bare object. `PSNProfile` decodes **both**
   (nested `profile` first, then bare). Verify the real shape at **S2**.
2. **NPSSO acquisition** — psn-api's documented flow logs into `playstation.com` then reads
   `https://ca.account.sony.com/api/v1/ssocookie` (JSON `{"npsso":…}`); the WKWebView route
   in PLAN §13.1 reads the `npsso` **cookie** directly. Both are modelled (`loginURL`,
   `npssoCookieName`/`Domain`, `ssoCookieEndpoint`). The exact sign-in URL + cookie domain
   are an **ASSUMPTION(S0)** — verify at **S1**.
3. **Trophy account path** — psn-api uses `/v1/users/{accountId}/trophyTitles`; PLAN §13.3
   uses `/v1/users/me/trophyTitles`. We use `me` (works per psn-api docs). Verify at **S3a**.
4. **Game-list base** — the code lives in `getUserPlayedGames.ts` under a `USER_GAMES_BASE_URL`
   the repo did not surface directly; PLAN §13.3 gives `/api/gamelist/v2/users/me/titles`,
   which we use. Verify at **S5**.
5. **Membership values** — clients show `PS_PLUS` vs `NONE`; unknown values are kept **raw
   and shown**, never guessed (`ProductSubscription`). First sight of real values at **S6**.

## The `ASSUMPTION(S0)` checklist, keyed by the step that verifies it

| # | Assumption | Verified at |
|---|---|---|
| A1 | Mobile-app client id / Basic auth / redirect / scope still accepted by `…/oauth/token` | **S1** |
| A2 | Sign-in URL + `npsso` cookie name/domain (WKWebView route) | **S1** |
| A3 | NPSSO length/charset (`isPlausibleNPSSO`, currently 32–128 URL-safe chars) | **S1** |
| A4 | Token response fields (`access_token`, `refresh_token`, `expires_in`, `refresh_token_expires_in`) | **S1** |
| A5 | Profile envelope + `onlineId`/`accountId` keys | **S2** |
| A6 | Trophy DTO (`npCommunicationId`, `trophyTitleName`, `trophyTitlePlatform`, `progress`, `totalItemCount`, `nextOffset`) and the `NPWR…` id pattern | **S3a** |
| A7 | Trophy paging coherence at `limit=800` | **S3b/S4** |
| A8 | `npServiceName=trophy` really returns PS3/Vita titles | **S4** |
| A9 | Game-list DTO, ISO-8601 `playDuration`, `CUSA/PPSA` id pattern, `concept.id` | **S5** |
| A10 | Disc-vs-digital marker candidates (`category`/`service`, entitlement package) | **S5/S6** |
| A11 | GraphQL persisted-query hash still valid (**most likely to fail**) | **S6** |
| A12 | Purchases DTO + `membership` real values (first sight of `PS_PLUS`) | **S6** |

## The S1–S8 runbook (test account first, then the real account)

The owner made a **test PSN account** (a few free games downloaded, **no PS Plus**, little
or no play history). Run everything that does not need real data on it first; each data set
still gets a **tiny probe on the real account** afterwards. The dev cache keeps the two
accounts in **separate folders** (`test/`, `real/`), so nothing is fetched twice.

> **At every live step:** make exactly the listed request(s); validate with the §13.2
> rules. Valid → record the scrubbed fixture, it is cached, report, move on. **Not** the
> proper content (wrong status, HTML/captcha, error envelope, schema mismatch, suspicious
> emptiness, rate-limit, auth challenge, anything unforeseen) → **stop all PSN traffic
> immediately**, do not retry or try a variant/parameter/endpoint/host, write down exactly
> what was sent and received (tokens + account ids redacted), and **wait for the owner's
> explicit approval**. Approval covers one next action.

| Step | Account | Exact request (probe = smallest page) | Proper content |
|---|---|---|---|
| **S1** sign-in | test | owner logs in; `GET …/oauth/authorize` (`Cookie: npsso=…`) → code; `POST …/oauth/token` ×1 | access + refresh tokens with expiry |
| **S2** profile | test | `GET …/userProfile/v1/internal/users/me/profiles` | the test online id |
| **S3a** trophy probe | test | `GET …/trophy/v1/users/me/trophyTitles?npServiceName=trophy2&limit=10&offset=0` | ≤10 titles (may be **empty** — valid for a new account) + `totalItemCount` |
| **S3b** trophy full | test | `…&npServiceName=trophy2&limit=800&offset=0` | a full page coherent with S3a |
| **S4** trophy PS3/Vita + paging | test | `…&npServiceName=trophy&limit=10&offset=0`, then `limit=800` | coherent pages, no dupes |
| **S5** game list | test | `GET …/gamelist/v2/users/me/titles?limit=10&offset=0`, then `limit=200` | titles with ISO-8601 durations |
| **S6** purchases (fragile) | **test** | `GET …/graphql/v1/op?operationName=getPurchasedGameList&variables={…"size":10,"start":0…}&extensions={persistedQuery hash}` | entitlement list incl. `membership` (test has free games → **NONE** expected, not empty) |
| **S5b** re-probe | **real** | sign-in + profile, then ONE tiny probe per data set (`trophyTitles limit=10`, `gameList limit=10`, `purchases size=10`) **before** its full fetch | real online id, first sight of `PS_PLUS` |
| **S7** full sync | real | 0 — staging, matching, review sheet, commit, all offline from cache | — |
| **S8** second sync | real | 0 (inside the cache window) | proves "zero requests, only deltas" |

The purchases op is the same one `library.playstation.com/recently-purchased` runs in the
browser; if the persisted-query hash has moved by S6, read the current one from that page's
network tab (a stop-and-ask, not a retry). Owned-digital can ship later without blocking the
milestone: build the importer with `includePurchases: false` until S6 passes.

**Free-to-play** entitlements are normal owned digital copies (price is irrelevant); demos,
betas, add-ons, themes/avatars, media apps, pre-orders and inactive entitlements go to
noise (each with a reason, restorable).

## What a reject looks like

A bogus response is **never cached** and never overwrites a good entry. The client records
a redacted 4 KB excerpt in `import_cache_rejects` (`source='psn'`, last 50) and throws
`ImportError.rejected` with a one-line `ImportRejectReason.message` (e.g. "A login page was
returned — the session looks signed out.", "The response carried an error envelope."). The
sync stops; the owner is asked. `reachedRateLimitEnd` is set after the single 429 wait, and
`PSNClient.ClientError.probeRequired` is thrown if a full fetch is attempted before its probe.

## Wiping both caches

- **Runtime cache** (`import_cache`/`import_cache_rejects`, `source='psn'`, in `vgn.sqlite`):
  `ImportResponseCacheStore.wipe(source: "psn")` — also the Sign-out & wipe path.
- **Dev cache** (`~/Library/Application Support/VGN/dev-import-cache/`, DEBUG only, holds no
  tokens, headers never stored, account ids kept only here): `DevImportResponseCache.wipe()`.
  Delete it at the end of the milestone or on request. Injected in tests to a temp dir —
  never the real Application Support directory.
- **Tokens** (Keychain, account `psn.tokens`): `PSNAuth.signOut()`.

## The panel runbook — S1–S8, one click at a time (wave 12)

The import UI landed in wave 11 (lane C); the **DEBUG "PSN build steps" panel** (§13.5) landed in
wave 12 (lane A). Run the gated live steps **through the panel** — one request per click, each
button disabled until its prerequisite has passed, and a hard stop-and-lock on anything
unexpected. Only the orchestrator + owner run these steps, together, in a DEBUG build launched
from Xcode (never `-VGNSampleData`, never against the owner's real library first).

### 0. Arm the latch (all builds)
`psn.liveEnabled` defaults **off** — the live PSN objects are not even built, so no click can
reach Sony. In **Settings ▸ PlayStation** the pane reads "PlayStation sync is off"; click
**Enable PlayStation sync (unofficial API)…**, confirm, and it says **"Relaunch VGN to apply"**
(the sign-in/importer/panel are composed once at launch — nothing hot-swaps). Relaunch.

### 1. Sign in on the TEST account (S1)
Leave the panel's account picker on **test** (persisted, key `psn.buildSteps.accountLabel`,
default `test`; it also scopes the dev cache folder and the probe markers). Click **Sign In to
PlayStation…**, log in on Sony's own page (host-only address bar; off-Sony pages blocked). VGN
reads the `npsso` cookie → tokens; if the cookie can't be read, expand **Paste NPSSO instead**.
The pane shows the online id; open **PSN build steps…** — the panel shows `test` and
`requests this session: 0 / 40`.

### 2–6. Probe on the test account, reading each cached body before the next click
In §13.5 order, each button runs **exactly** its requests and writes the body to the dev cache
(`~/Library/Application Support/VGN/dev-import-cache/psn/test/…`). After each, read the result
row (HTTP status, item count / `totalItemCount`, from cache vs network, bytes, the dev-cache
path — click it to reveal in Finder — elapsed) and the running total, then let the orchestrator
open the cached body from disk to check the DTO before the next click:

- **S2 · Probe profile** — the test online id.
- **S3a · Probe trophy titles — limit 10** and **S3a′ · Probe trophy titles PS3/Vita — limit 10**
  (both require S2). A brand-new account's list may be **empty** — that is valid.
- **S5 · Probe game list — limit 10** (requires S2).
- **S6 · Probe purchases — size 10** (requires S2) — the test account's free games prove the
  GraphQL call, the persisted-query hash and the `membership: NONE` DTO. **Most likely to fail.**

The full-fetch buttons (S3b/S4, S5, S6) stay disabled until their probe passes for `test`. On the
test account you can run them too (they ask "up to N requests — continue?"), but the point of the
test account is the probes.

### 7. Switch to the REAL account (S5b)
**Sign Out** (optionally tick "also delete cached PlayStation responses"), sign in with the real
account, then set the panel picker to **real** — a red **REAL ACCOUNT** marker appears and the
panel resets to what is recorded for `real` (nothing yet; the dev cache and markers are per
account). Run **one probe per data set** (S2 → S3a → S3a′ → S5 → S6), stopping after each for the
orchestrator to check the dev cache. The first real `membership: PS_PLUS` shows here.

### 8. Full fetches on the real account, one at a time
Only after a data set's probe has passed for `real`, its **Fetch** button enables. Each asks
"up to N requests — continue?" and, on the real account, a **second confirmation**. Run them one
at a time, reading the cached bodies between. When every probe and full fetch has passed for a
label, the panel has satisfied the **DEBUG normal-Sync gate**: **Sync Now** / File ▸ Import from
PlayStation… now run the ordinary cache-first sync (0 requests inside the cache window — S8) and
open the review sheet with the PSN groups (Played · Launched 0 % · Played — no purchase found ·
Purchased · PS Plus · Already in your library · Ignored · Proposed removals).

### If a step stops (the reject lock)
Any reject / budget-exceeded / auth failure / unexpected error **disables every button** and shows
**"VGN stopped and made no further requests."** with the redacted excerpt. Nothing else happens
until **Acknowledge**; acknowledging re-enables only steps whose prerequisites still hold, and the
failed step needs an explicit **Try this step again** (one retry = one new decision). **Copy
report** puts a redacted plain-text summary of all rows on the pasteboard (no token / NPSSO /
account id). **Wipe dev cache (this account)** clears this label's recorded bodies.

`getPurchasedGameList` hash moved (S6)? That is a **stop-and-ask**, not a retry: read the current
hash from `library.playstation.com/recently-purchased`'s network tab and update
`PSNClient.purchasedGamesHash`. Owned-digital can ship later without blocking by building the
importer with `includePurchases: false` until S6 passes.

## Live log

- **2026-09-19 — S1, test account, profile `psn-test` — first attempt FAILED client-side ("unsupported URL"), fixed.** The owner signed in on Sony's page (the web view opened `my.playstation.com`, which showed the PlayStation **homepage** — he had to click through to the sign-in form; the start URL is a known wart, not yet changed because a better one cannot be verified without loading Sony pages). The NPSSO cookie was captured and the `authorize` request was sent once; Sony answered with the expected `302 Location: com.scee.psxandroid.scecompcall://redirect/?code=…`, but the wiring had given `PSNAuth` a redirect-FOLLOWING session, so `URLSession` tried to follow the custom-scheme URL and failed with `NSURLErrorUnsupportedURL` before the code could be read. No token call was made, nothing was retried. Fix: `URLSessionTransport.ephemeral(followRedirects: false)` (a session whose delegate refuses redirects) is now used for the `authorize` step only, and all PSN traffic uses ephemeral sessions (no shared cookie jar / URL cache). Covered by `NoRedirectTransportTests`. Requests to Sony so far: the interactive login + 1 `authorize`.
- **2026-09-19 — S1 retry OK** (authorize 302 read, token exchange accepted ⇒ the mobile-app client values, the `npsso` cookie name/domain and the token endpoint are verified).
- **2026-09-19 — S2 REJECTED, 1 request, stopped.** `GET m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles` → **HTTP 400** `{"error":{…"Bad Request (path: accountId)"}}`: the modern profile endpoint does not accept `me` as the account id (psn-api only documents it with a real `accountId`; §13.3's URL was wrong). Recorded in `import_cache_rejects`, nothing cached, panel locked. Proposed next action (needs the owner's go, one request): the legacy endpoint psn-api uses to resolve the signed-in user — `GET us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=onlineId,accountId,plus` → `{ "profile": { onlineId, accountId, plus } }`. Code, allow-list (exact `…/users/me/profile2` prefix only — nobody else's profile) and tests updated offline. Also settled from the psn-api source: the game-list base URL is `m.np.playstation.com/api/gamelist/v2/users` (matches what we built).
- **2026-09-19 — S2 OK (test account), 1 request.** Legacy `profile2` → HTTP 200, 86 B, shape `{ "profile": { onlineId: string, accountId: 19-digit string, plus: 0 } }` (nested `profile`, `plus` is an Int) — matches the DTO; cached in the dev cache (`psn/test/profile-….json`, no headers). Disagreement (1) settled: nested. Next: S3a.
- **2026-09-19 — S3a, S3a′, S5 OK (test account), 1 request each.** Trophy titles `trophy2` and `trophy`: `{"trophyTitles":[],"totalItemCount":0}`; game list: `{"titles":[],"nextOffset":null,"previousOffset":0,"totalItemCount":0}` — valid empty envelopes (the account has no play history): endpoints, the `me` path and bearer auth verified; per-title shapes still to be seen on the real account's limit-10 probes.
- **2026-09-19 — S6 probe REJECTED, 1 request, stopped.** HTTP 400 from the GraphQL gateway: *"This operation has been blocked as a potential Cross-Site Request Forgery (CSRF). Please either specify a 'content-type' header … or provide … x-apollo-operation-name, apollo-require-preflight"*. Not the persisted-query hash: our GET simply lacked the `Content-Type: application/json` header that psn-api's `call()` sends on every request (the REST endpoints never cared). Fixed offline: the client now sends it on all PSN requests (test asserts it). Hash and variables re-checked against psn-api `main` — identical. Next action (needs the owner's go, one request): press the S6 probe again.
- **2026-09-20 — S6 probe OK (test account), 1 request.** With the `Content-Type` header the GraphQL gateway answered HTTP 200, 1.6 KB: `data.purchasedTitlesRetrieve.{ games[], pageInfo }`; each game `{ __typename: GameLibraryTitle, name, platform ("PS4" / "PS5"), membership ("NONE"), isActive, isDownloadable, isPreOrder, entitlementId, productId, titleId, conceptId (null on all three), image.url }`; `pageInfo { isLast, offset, size, totalCount }`. ⇒ **the persisted-query hash is still valid**, the DTO matches, free games arrive as ordinary entitlements with `membership: NONE`. Two follow-ups done offline: `pageInfo` is now decoded and ends the paging (`isLast` / `totalCount`); note `conceptId` can be null, so the external id falls back to `titleId` (already the rule). Still unseen: a `PS_PLUS` membership value (real account only) and a page size of 100 (the full fetch on the TEST account will prove it harmlessly).
- **2026-09-20 — S3b/S4, S5, S6 full fetches OK (test account), 4 requests.** Trophy titles (`trophy2` + `trophy`) and game list: empty, coherent envelopes; purchases with **page size 100 accepted**: 3 games, `pageInfo { isLast: true, offset: 0, size: 3, totalCount: 3 }` — paging ended on `isLast` in one request. App cache holds every response (`import_cache`, source `psn`); rejects table holds exactly the two known rejects (S2 `me`, S6 CSRF). Test-account total: 10 API requests (8 valid, 2 rejected-and-fixed), zero retries. Next: S7 normal sync from cache (expect 0 requests) + review + commit, S8 second sync (0 requests, nothing new), then the REAL account: sign out → sign in → label `real` → one tiny probe per data set.
- **2026-09-20 — S7 OK (test account):** normal Sync Now = "9 from cache · 0 from network", 3 games reviewed and imported as owned digital `source = psn` copies (King's Quest PS4, Life is Strange 2 PS4, Fortnite PS5), all matched to IGDB.
- **2026-09-20 — REAL account, S2/S3a served FROM THE TEST ACCOUNT'S CACHE — our bug, zero requests, stopped.** After Sign Out (cache kept) → Sign In as the real account → label `real`, the panel showed S2 and S3a "ok · from cache · 0 B · 0 requests": the 30-day `import_cache` key was endpoint+params only, so the real session was handed the test account's profile and empty trophy list. Nothing reached Sony and nothing was imported, but a sync would have shown the wrong account's data. Fix: every PSN login session gets a random **cache scope** (`PSNStoredToken.cacheScope`, minted at interactive sign-in, kept across token refreshes, persisted with the tokens in the Keychain); every cache key, dev-cache hash and probe marker is prefixed with it. A new sign-in ⇒ a cold cache and fresh probes, never another account's data. Regression test `PSNCacheScopeTests`. The old unscoped rows are unreachable (they expire in 30 days or go with "delete cached responses"). Owner action before continuing: relaunch the rebuilt app; the `real` label's two "passed" flags from the bogus run must be ignored — press S2 again (it will now go to the network).
- **2026-09-20 — REAL account, S2 + S3a OK, 2 requests (from network, after the cache-scope fix).** Profile: nested, `plus: 1` (the subscription is visible). Trophy titles `trophy2`, limit 10: `totalItemCount: 265`, `nextOffset: 10`, 10 coherent titles; per-title keys `npCommunicationId` (NPWR…), `npServiceName`, `trophyTitleName`, `trophyTitlePlatform` ("PS5" / "PS4"), `progress` (0–100), `earnedTrophies{}`, `definedTrophies{}`, `lastUpdatedDateTime` (ISO), `hiddenFlag`, `hasTrophyGroups`, `trophyGroupCount`, `trophySetVersion`, `trophyTitleIconUrl` — the DTO matches. Two 0 % titles in the first ten (the "Launched, 0 %" group is real), names carry ™/® (must be stripped for IGDB matching — check the import matcher's cleaning before the first real review). A full fetch is ONE request (265 < 800).
- **2026-09-20 — REAL account, S3a′ + S5 + S6 probes OK, 3 requests (5 / 40 for the session).** (1) `npServiceName=trophy` returned the SAME list as `trophy2` (265 titles, same first ten): the endpoint lists everything and each title carries its own `npServiceName` — the separate PS3/Vita data set is wrong and is being removed (lane w14/a). (2) Game list: `totalItemCount 231`; per title `name`, `titleId` (PPSA…/CUSA…), `category` (`ps5_native_game`, `ps4_game`, **`ps5_native_media_app`, `ps5_web_based_media_app`** = Netflix, Plex → noise), **`service`** = `none(purchased)` | `ps_plus` | `other` (the owner's disc games are `other`), `playDuration` (`PT221H51M37S`, `PT5M22S`), `playCount`, `firstPlayedDateTime`, `lastPlayedDateTime`, `concept { id (Int), name, genres, … }`. (3) Purchases: `pageInfo.totalCount 581`, `isLast false`; **`membership: "PS_PLUS"` confirmed** (7 of the first 10) next to `"NONE"`; `conceptId` null everywhere; PS4 and PS5 versions of one game are separate entitlements. No full fetch yet — waiting for lane w14/a (single trophy list, `service`/`category` mapping, cross-gen twins, never-played PS Plus claims → Ignored).

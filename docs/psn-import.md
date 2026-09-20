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

## Mapping — what the real fields mean (verified live 2026-09-20)

The three lists are joined into **one staging row per game** on **concept id → title id →
normalised name** (name only, so a cross-gen twin with different title ids and a null concept
id still merges). Trophy titles carry no ids, so they join by name. ™/®/© are stripped for
the join **and** for the IGDB match title (`matchTitle`); the shown `name` keeps them.

**Trophy titles — one list.** The endpoint (`…/trophy/v1/users/me/trophyTitles`) ignores the
`npServiceName` filter and returns every title of the account; each title carries its own
`npServiceName` (`trophy` = PS3/PS4/Vita sets, `trophy2` = PS5 sets). VGN fetches it once (no
`npServiceName`, as psn-api's `getUserTitles` does). `trophyTitlePlatform` values, including
combined ones, map to slugs: `PS5`→ps5, `PS4`→ps4, `PS3`→ps3, `PSVITA`→vita. The pick for a
combined string is the **newest generation** and is **order-independent** — the real strings
arrive oldest-first, `"PSVITA,PS4"` (10 titles) and `"PS3,PSVITA,PS4"` (4 titles, live
2026-09-20), yet both resolve to **ps4**; `"PS4,PS5"`→ps5, `"PS3,PSVITA"`→vita. The row keeps
the newest slug and gets a review note **"also on …"** listing the other platforms of the
string. The same `npCommunicationId` never double-counts. (`generationRank` orders strictly by
release, PS5 > PS4 > Vita > PS3 > PSP > PS2 > PS1, so any real combined string resolves cleanly.)

**Game list — `service`** tells how a game was accessed:

| `service` | Meaning | Becomes |
|---|---|---|
| `none(purchased)` (100) · `none_purchased` (67) | a digital purchase — **two spellings of the same value** | **owned digital**, even if the purchases list misses it |
| `ps_plus` (27) | played through PS Plus | if a `PS_PLUS` entitlement exists → owned-via-subscription; else **played, not owned**, note "played via PS Plus" |
| `other` (37) | neither (the owner's disc games) | **played, not owned**, note "probably a disc — not a digital licence" → *Played — no purchase found* group; "Own the ticked rows as ▸" **defaults to Physical** |
| any other string | kept raw and shown | played (per play time), not owned |

Parsing is **tolerant**: `service` is normalised by dropping case, spaces, underscores, hyphens
and parentheses before matching (`classifyService`), so `none(purchased)`, `none_purchased`,
`None (Purchased)`, `none-purchased` all fold to *purchased*, and `ps_plus` / `PS Plus` to *PS
Plus*. The two purchase spellings mean the same thing (`none_purchased` is only ever seen on
`CUSA…` = PS4-generation records — never on a `ps5_native_game` / `PPSA…` title; `none(purchased)`
covers both generations); a genuinely unknown value stays raw, shown, and **never asserts
ownership**.

**Game list — `category`** gives the platform (the list has no platform field) and flags
non-games. Real values (231-title fetch): `ps4_game` 158, `ps5_native_game` 47,
`ps5_native_media_app` 6, `unknown` 6, `ps4_videoservice_web_app` 5, `ps4_nongame_mini_app` 4,
`ps5_web_based_media_app` 3, `not_found` 2.

- **Apps → Ignored** ("media app"): any category containing `media_app`, `videoservice`,
  `web_app`, `nongame` or `mini_app` (Netflix, Plex, YouTube, Media Player, Headset Companion…).
- **Games**: a category ending in `_game`; platform from the `ps5_…`/`ps4_…` prefix.
- **`unknown` / `not_found` are NOT apps** — they are delisted/old **games** (Resident Evil
  Director's Cut, Return of the Obra Dinn, Undertale, Back to the Future: The Game, Game of
  Thrones…; all `CUSA…` = PS4 in the owner's data, all with real play time). Kept as games with
  a **"category unknown"** review note; platform from the **title-id prefix** (`slug(fromTitleId:)`:
  `PPSA…`→ps5, `CUSA…`→ps4, `PCSA…`→vita best-effort) since the category can't give it. When the
  prefix is unrecognised the platform is left **nil for the owner to pick** in the review row.
- **Any future unseen value** follows the same ladder: `…_game` → game, an app-keyword → app,
  otherwise kept as a game with the "category unknown" note — **never silently dropped**.

**Purchases — `membership`.** `NONE` = a bought copy I really own (never vaulted). `PS_PLUS`
= a subscription claim, gated by play time (below). Unknown values are kept raw and shown.
**Cross-gen twins** (the same game as a PS4 *and* a PS5 entitlement, null concept id) become
**one** staged game with one copy: platform ps5 when a PS5 entitlement exists (else ps4),
note "PS4 & PS5 versions", external id on the PS5 entitlement (stable across syncs). A PS Plus
twin + a bought twin ⇒ the **bought** one wins as the owned copy (no subscription flag).

**The Vault's 10-minute gate (§16 / `ImportPolicy.vaultPlaytimeGateSeconds = 600`).** A
`PS_PLUS` entitlement whose joined game-list play time is **≤ 600 s** (including no game-list
entry at all, regardless of a 0 % trophy) is **not** imported into the library: it is staged
*Ignored* with reason "PS Plus — in the Vault (played under 10 min)" (`.vaultedSubscription`,
restorable), for a later lane to move into the Vault. One played **> 600 s** is imported as the
owned-via-subscription copy (the "+" badge). Batocera's promotion uses the same constant
(raised from its old 5-minute rule). The review header shows "PS Plus: N played · M in the
Vault".

**Play data.** ISO-8601 `playDuration` (e.g. `PT33H34M17S`, `PT5M22S`, `PT221H51M37S`) →
seconds; `firstPlayedDateTime`/`lastPlayedDateTime` → `games.first_played_at`/`last_played_at`.
A 0 % trophy title whose game-list play time is < 30 min stays **Launched** (e.g. Myst,
5 m 22 s).

**Bundles expand too (W18-A, PLAN §13.3).** A PSN title whose IGDB match is a bundle/pack is expanded
during matching (the shared `IGDBImportBundleExpander`) and committed as ONE `compilation` Product
keyed by the PSN external id: digital for a purchase, the PS Plus subscription copy for a claim,
physical/digital per the review's *own-as* control for a played-no-purchase disc, or **no product**
for played-not-owned (only the members ticked as played are then created, as played-not-owned games).
"Which did you play?" is asked once, in the row (a per-member played tick + All/None, default none),
only when PSN reports the collection played; the collection's play time / dates / 100 % status go to a
member **only when exactly one** is ticked, otherwise they stay on the `import_titles` record.
`cleanMatchTitle` also drops the platform tail Sony appends ("… PS4 & PS5", "… (PS4)", "… PS5",
"for PS4") for MATCHING only — the shown title is unchanged.

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
- **S3a · Probe trophy titles — limit 10** (requires S2). **One list, not two:** the endpoint
  ignores the `npServiceName` filter (live, 2026-09-20 — `trophy` and `trophy2` returned the
  identical 265-item list), so there is no separate PS3/Vita probe/fetch; each title carries
  its own `npServiceName`. A brand-new account's list may be **empty** — that is valid.
- **S5 · Probe game list — limit 10** (requires S2).
- **S6 · Probe purchases — size 10** (requires S2) — the test account's free games prove the
  GraphQL call, the persisted-query hash and the `membership: NONE` DTO. **Most likely to fail.**

The full-fetch buttons (S3b/S4, S5, S6) stay disabled until their probe passes for `test`. On the
test account you can run them too (an inline confirm row appears in the step, "up to N requests —
[Fetch] [Cancel]"), but the point of the test account is the probes.

### 7. Switch to the REAL account (S5b)
**Sign Out** (optionally tick "also delete cached PlayStation responses"), sign in with the real
account, then set the panel picker to **real** — a red **REAL ACCOUNT** marker appears and the
panel resets to what is recorded for `real` (nothing yet; the dev cache and markers are per
account). Run **one probe per data set** (S2 → S3a → S5 → S6), stopping after each for the
orchestrator to check the dev cache. The first real `membership: PS_PLUS` shows here.

### 8. Full fetches on the real account, one at a time
Only after a data set's probe has passed for `real`, its **Fetch** button enables. Pressing it
reveals an **inline confirm row inside the step** — there is exactly **one** confirmation per full
fetch (never a chained second dialog). On the real account it is a single, stronger confirm:
titled **"… — REAL ACCOUNT"**, message "up to N request(s) … with your real account (k / 40 used
this session)", buttons **Fetch (N request(s))** / Cancel. If a step can't start when you press
Fetch (a prerequisite was undone, another step is running, the panel is locked) the row says why
instead of doing nothing. Run them one at a time, reading the cached bodies between. When every probe and full fetch has passed for a
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
- **2026-09-20 — `npServiceName` is ignored by the trophyTitles endpoint (real account).** A probe with `npServiceName=trophy` returned EXACTLY the same list as `npServiceName=trophy2` (same 265 `totalItemCount`, same first ten titles). The endpoint lists every title of the account; each carries its own `npServiceName` (`trophy` = PS3/PS4/Vita, `trophy2` = PS5). Fixed (w14/a): fetch the list **once** with no `npServiceName` (matches psn-api's `getUserTitles`); removed the separate PS3/Vita data set / probe / full fetch (client `DataSet`, importer loop, panel S3a′, runner, estimates, docs, tests). `npServiceName` is still kept per-title on the DTO. Combined `trophyTitlePlatform` values ("PS4,PS5", "PS3,PSVITA") map to the newest slug. The same `npCommunicationId` never double-counts.
- **2026-09-20 — game list `service` = how the game was accessed (real account).** Per title `service` ∈ `none(purchased)` (a digital purchase), `ps_plus` (played through PS Plus), `other` (neither — the owner's DISC games: Elden Ring, FF VII Rebirth, Kingdom Come II…). Mapping (w14/a): `none(purchased)` → owned digital even if the purchases list misses it; `ps_plus` → owned-via-subscription if a `PS_PLUS` entitlement exists, else played-not-owned ("played via PS Plus"); `other` → played-not-owned ("probably a disc — not a digital licence"), whose *Own the ticked rows as ▸* defaults to Physical. Unknown values kept raw. **Never asserts ownership from `other`.**
- **2026-09-20 — game list has non-games (real account).** `category` ∈ `ps5_native_game`, `ps4_game`, `ps5_native_media_app`, `ps5_web_based_media_app`. A category not ending in `_game` → *Ignored* ("media app"); `category` also gives the platform (the list has no platform field). Types: `concept.id` is an **Int** in the game list, `conceptId` a nullable **String** in purchases (null on every real row) — both decoded through `PSNFlexibleID`, normalised to String; the join falls back to name when the concept id is absent.
- **2026-09-20 — purchases probe, real account, size 10.** `pageInfo.totalCount = 581`, `isLast = false`; `membership` values `PS_PLUS` (7 of the first 10) and `NONE` — the PS Plus flag works as assumed; `conceptId` null on every row. **Cross-gen twins**: the same game appears as two entitlements (PS4 + PS5) — merged into one game/one copy (ps5 preferred), note "PS4 & PS5 versions", stable external id on the PS5 entitlement; a bought twin beats a PS Plus twin (no flag). **Volume**: 581 entitlements, mostly PS Plus monthly claims never launched. Per **owner 2026-09-20 (PLAN §16 The Vault)**: a `PS_PLUS` entitlement with joined play time **≤ 10 min** (600 s, `ImportPolicy.vaultPlaytimeGateSeconds`, shared with Batocera) is staged *Ignored* "PS Plus — in the Vault (played under 10 min)" for a later lane to move to the Vault; > 10 min → owned-via-subscription. Bought (`NONE`) never vaulted. Full purchases fetch estimate ceil(581/100) = 6. Review header: "PS Plus: N played · M in the Vault".
- **2026-09-20 — w14/a landed all of the above offline** (no new Sony traffic; all on synthetic fixtures with the same shapes). Panel steps are now S2 · S3a · S5 · S6 · three full fetches; estimates 1 / 2 / 6. Whole suite green (1494 tests). Not yet exercised against the real account beyond the probes above: the **full** real fetches (trophy 265, game list, purchases 581) and the first real review sheet — first run should watch the cross-gen merge and the Vault counts on real names.
- **2026-09-20 — real-account full-fetch confirm did nothing — fixed (w14/c), no Sony traffic.** On the `real` label, pressing a **Fetch all …** button showed "up to N — continue?", but after the owner confirmed, nothing happened (no request, no dialog, no row change). Root cause: `confirmPending()` set `pendingConfirm = nil` (dismissing the one shared `confirmationDialog`) and, on the real account, *synchronously reassigned* it to `.realFullFetch` to request a **second** dialog — macOS silently drops a presentation requested while another is dismissing, so the second confirm never appeared and `perform` was never reached. On `test` the first confirm called `perform` directly, so it worked. Fix: dropped the chained second dialog and the `confirmationDialog` entirely; the confirmation is now an **inline confirm row inside the panel** (click-testable, no double-presentation trap) — exactly **one** confirm per full fetch, a single stronger one on `real` (title "… — REAL ACCOUNT", "with your real account (k / 40 used this session)", button "Fetch (N request(s))"). The confirm button starts the step through the same `perform` path as the probe buttons; a start that can't proceed now leaves a visible `lastActionNote` in the row instead of failing silently. Same pattern removed from Wipe / Try again / Acknowledge. All `#if DEBUG`; Release still has no `PSNBuildSteps` symbols. New tests: single-confirm on both labels for all three full fetches, cancel-runs-nothing, blocked-confirm-leaves-a-note, and a `ClickProbeWindow` test that clicks Fetch → inline confirm → confirm → exactly one runner call.
- **2026-09-20 — REAL account, full trophy-titles fetch OK, 1 request** (after the inline-confirm fix). 265 / 265 items, `nextOffset` null, 0 duplicate ids. Platforms: PS4 146 · PS3 59 · PS5 46 · `PSVITA,PS4` 10 · `PS3,PSVITA,PS4` 4 (combined values come in this order — check the platform pick rule on them at the first review). `npServiceName`: trophy 219, trophy2 46. Progress: 31 at 0 % (the "Launched" group), 187 in between, 47 at 100 % (status pre-fill). 5 hidden titles. Activity from 2009-12 to 2026-09. 51 names carry ™/®.
- **2026-09-20 — REAL account, full game-list (231) + purchases (581) fetches, values the mapping did not know — landed offline (w14/d), no new Sony traffic.** **Game list, 231 titles.** `service` has **four** values, not three: `none(purchased)` 100 · `none_purchased` 67 · `other` 37 · `ps_plus` 27. `none_purchased` is a **second spelling of the same digital-purchase value** — it appears **only** on `CUSA…` (PS4-generation) records (all 67), never on a `PPSA…`/`ps5_native_game` title, while `none(purchased)` covers both generations; both fold to *purchased*. Parsing is now tolerant (case/space/underscore/hyphen/paren-insensitive, `classifyService`); unknown strings stay raw and never assert ownership. `category` has more values than assumed: `ps4_game` 158 · `ps5_native_game` 47 · `ps5_native_media_app` 6 · **`unknown` 6** · **`ps4_videoservice_web_app` 5** · **`ps4_nongame_mini_app` 4** · `ps5_web_based_media_app` 3 · **`not_found` 2**. Rule: any category with `media_app`/`videoservice`/`web_app`/`nongame`/`mini_app` → *Ignored* ("media app") — the four app categories are Netflix, Plex, YouTube, Disney+, Prime Video, Apple TV, Twitch, SONY PICTURES CORE, Dailymotion, OCS, Media Player, Headset Companion, Spider-Man: Homecoming VR…; `…_game` → a game (platform from the prefix). **`unknown` (6) and `not_found` (2) are NOT apps — they are delisted/old games** (unknown: Resident Evil Director's Cut, Return of the Obra Dinn, DRAGON BALL FighterZ, Undertale, Resident Evil, Endless Fables: Dark Moor; not_found: Back to the Future: The Game, Game of Thrones) — all `CUSA…` (PS4), all with real play time; kept as **games** with a "category unknown" note, platform from the title-id prefix (`CUSA…`→ps4, `PPSA…`→ps5; nil ⇒ owner picks). Only two prefixes appear in the real data: CUSA 175, PPSA 56. Play: **27 titles ≤ 10 min**; ≈ 4 200 h across the 213 game titles (≈ 4 900 h counting the media apps). **Purchases, 581 entitlements** (page size 100, 6 requests, `pageInfo` ended paging): `membership` NONE 352 · PS_PLUS 229; platform PS4 462 · PS5 119; **all `isActive: true`, no pre-orders, `conceptId` null on every row**; ~70 names present on both PS4 and PS5 (68 by exact name / 75 by folded name). Combined trophy platform strings `"PSVITA,PS4"` (10) and `"PS3,PSVITA,PS4"` (4) confirmed; the platform pick is now order-independent (newest generation wins → **ps4** for both) and the row carries an "also on …" note. The Vault ingestion (`vaultEntries`) shares the same platform pick, "also on …" note, `category unknown` handling and `none_purchased` semantics as the staging rows (w14/d merge). Whole unit suite green (1547 tests). Not yet exercised: the first real review sheet on these values (watch the `unknown`/`not_found` games land as PS4 with the "category unknown" note, and the Vault counts).
- **2026-09-20 — REAL account, first real import + re-sync + force refresh + sign-out, all OK (owner, profile `psn-test`).** The first real review sheet was committed into the `psn-test` profile's library; a second *Sync Now* worked (served from the cache); *Force Refresh* of a data set worked; *Sign Out* worked. No reject, no stop. Owner feedback from that session (fixed in wave 17): the matching sheet resized with every title; the *Own the ticked rows as* control looked like it had a stuck default; a barely-launched disc game (*Prey*, game-list `service = other`, 8 min, trophies 0 %) left unticked in *Launched* did not go to the Vault. **Still to do: the same run against the real library** (its profile has its own cache and build-step flags, ≈ 14 requests) — `m7` is tagged after that.

## The Vault — PS Plus (wave 14, PLAN §16)
The barely-touched PS Plus games live in **The Vault**, not the library or the review sheet's *Ignored* bucket. A `PS_PLUS` entitlement with joined play time **≤ 10 min** (`ImportPolicy.vaultPlaytimeGateSeconds = 600`, shared with Batocera), including never launched, is a Vault entry; a bought copy (`membership: NONE`) never is; > 10 min is imported as the owned-via-subscription "+" copy.
- **Storage.** A PS Plus claim is a `rom_catalog` row with `source='psn'`, `system=<platform slug>`, `relative_path=<PSN external id>` — the same table as the Batocera ROM catalogue (migration **v11** adds the nullable PS Plus columns: `external_id`, `cover_url`, `membership`, `cross_gen_note`, `igdb_id`, `length_main_s`/`length_complete_s`, `traits_json`, `igdb_rating`, `match_state`, `matched_at`). `UNIQUE(source, system, relative_path)` and the FTS triggers are unchanged.
- **Ingestion.** Pure `PSNMapping.vaultEntries(trophyTitles:gameList:purchases:)` builds the entries with the same merge as `stagingRows` (cross-gen twins → one entry, PS4 & PS5 note; cover URL from the purchase image). It flows through the coordinator (`ImportFetchResult`/`ImportSyncResult` carry `vaultEntries` / `vaultPresentIDs`, empty for GOG/Delicious) and the PSN presenter calls `RomCatalogStore.syncPSNVault` after each sync — new claims inserted, present ones refreshed **without touching an IGDB match**, vanished ones (or ones that crossed the gate) get `removed_at`. The importer only builds vault entries when purchases were actually fetched, so a skipped/rate-limited purchases page never empties the Vault.
- **Scoring.** Matched PS Plus entries are scored by `DiscoverScorer` beside Batocera ROMs (time-fit from IGDB length, source-aware crowd prior); library "+" copies get the `PSPlusDeadlineBoost` ramp in `RecommendationEngine`.
- **Trait matching (wave 15).** `VaultTraitMatcher` (a service like `BatoceraFavouriteAutoAdd`) matches up to 60 unmatched PS Plus entries per run through the existing `ImportMatcher` + IGDB rate limiter — the ™-stripped title (`PSNMapping.cleanMatchTitle`), platform-constrained, **top-bucket only**; confident matches share **one** batch `games(ids:)` + `timeToBeat` call and persist id / traits (genres, themes, keywords, franchise, developer + genre/decade) / rating / main-complete length via `setVaultMatch`; everything else `setVaultNoMatch`, so nothing is ever re-queried. `VaultTraitMatchModel` runs it after each sync and once at launch (live + IGDB configured only); Settings ▸ PlayStation shows "Vault: N of M matched" + **Match more now**.
- **Browser + actions (wave 15).** The PS Plus browser row shows the remote cover (in-memory `VaultCoverLoader`, never `covers/`), platform pill, the "+" marker, cross-gen note, IGDB facts once matched, and **Add to Library…** (owned-via-subscription copy via the shared staging commit + `setPromotedByExternalID`), **Not Interested**, **Find match…** (the reconcile link sheet). No PS Store link — the entitlement id is not a store/concept id.
- **Deadline + review (wave 15).** The Settings month/year picker (`PSPlusDeadlinePreferences`) threads `psPlusMonthsLeft` + `PlayPace` into both scorers; the review sheet groups auto-vaulted claims in a collapsed "In the Vault (N)" section with **Show in the Vault**; after a PSN commit `linkPromotedFromProducts` links a claim that crossed the gate to its new game.
- **Still foundations-only (see `docs/LIMITATIONS.md §5b`).** The explicit "Send to the Vault" review action (migration v12 `owned` + `sendToVault` are in; the action / `ImportDecision.vault` / undo / GOG-Delicious sources are not), and resume-after-cancel without re-querying.

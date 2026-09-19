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

## Wave 11 — the import UI, and how to run the live steps through it

The PSN import UI landed in wave 11 (lane C): a **Settings ▸ PlayStation** tab, a WebKit login
sheet, the live `ImportBackend`, the File ▸ **Import from PlayStation…** command, and the
review/commit flow. The DEBUG **one-button-per-step build-steps panel** described in §13.5 is
**not built yet** (see `docs/LIMITATIONS.md` §5c); until it is, run S1–S8 through the ordinary
Settings flow below. The per-fetch probe guard still holds — the importer calls
`client.probe(...)` before every full fetch, so a full page is never fetched un-probed — but
this flow is *not* literally one request per click, so run it **deliberately**, watching the
reject surface, and stop the moment anything looks off.

**Click-by-click (orchestrator + owner, DEBUG build, real Xcode-run app):**
1. Launch the app normally (no `-VGNSampleData`; live mode builds the real PSN objects). Open **Settings ▸ PlayStation**.
2. **Account = test.** The owner's throwaway test account (a few free games, **no PS Plus**) goes first. (The persisted `test`/`real` label — key `psn.buildSteps.accountLabel`, default `test` — already scopes the dev cache and probe markers; the picker UI ships with the build-steps panel.)
3. **Sign in (S1).** Click **Sign In to PlayStation…**, log in on Sony's page (host-only address line; off-Sony pages blocked). VGN reads the `npsso` cookie → exchanges it for tokens. If the cookie can't be read, expand **Paste NPSSO instead** and paste the `npsso` value from a signed-in browser. The pane now shows the online id, expiry, and cache ages.
4. **Sync (S2–S6).** Click **Sync Now**. The progress sheet runs profile → trophy titles (probe 10 → full 800, PS4/PS5 then PS3/Vita) → game list (probe 10 → full 200) → purchases (probe 10 → full). Watch for a **stop**: any reject shows "VGN stopped and made no further requests." with the reason + redacted excerpt, and nothing commits. For the test account, expect free games as owned digital and **no** PS Plus.
5. **Review & commit.** The review sheet opens (generic *New / Already matched / Ignored* buckets for now; PSN-specific groups are deferred — see LIMITATIONS §5c). The commit is already correct per row: purchases → owned digital, trophy titles → played with last-played date + 100 % status where earned. Commit; a banner reports the counts; re-syncing + re-committing adds nothing.
6. **Switch to the real account.** Sign out (optionally "also delete cached PlayStation responses"), then sign in with the real account. Because the dev cache and probe markers are per account (`test`/`real`), the real account re-probes each data set before its full fetch (S5b). The first real PS Plus title shows the yellow **+** badge and the inspector's "PS Plus — expires with the subscription" row.
7. **Second sync (S8).** Click **Sync Now** again inside the cache window — it makes **zero** requests (all from cache), proving idempotency.
8. **Force Refresh** on one data set states the request cost + cached age before spending anything (use it to re-fetch a single set without wiping the rest). **Sign Out** returns to the signed-out pane.

`getPurchasedGameList` hash moved (S6)? That is a **stop-and-ask**, not a retry: read the current
hash from `library.playstation.com/recently-purchased`'s network tab and update
`PSNClient.purchasedGamesHash`. Owned-digital can ship later without blocking by building the
importer with `includePurchases: false` until S6 passes.

When the build-steps panel is built, it replaces steps 3–8 with a labelled button per §13.5 row
(S2 probe, S3a/S5/S6 probes, then the full fetches, each disabled until its probe succeeds for the
current account), a running request total vs the 40 budget, a reject → **Acknowledge** lock, and a
**Wipe dev cache (this account)** button — the same requests, made one click at a time.

# GOG import — G0 scaffolding notes and the `ASSUMPTION(G0)` checklist

This is the state after **step G0** (PLAN §14.5): the shared importer machinery + the
GOG client, all built and tested on **synthetic fixtures only**. Not one request has
been made to any `gog.com` host. Every guess about a real GOG response is marked in
code with `// ASSUMPTION(G0):` and listed here for the live steps G1–G5 (run by the
orchestrator *with the owner*) to confirm or correct.

## Sign-in (decided at G1: OAuth authorization-code, route a)

- Galaxy client credentials live in `VGN/Services/Importers/GOG/GOGAuthConfiguration+Galaxy.swift`
  (`GOGAuthConfiguration.galaxy`). These are GOG's **public** Galaxy client id/secret,
  shipped by every open-source GOG client — not the owner's secrets. The owner approved
  the OAuth route knowing it uses them.
  - client_id `46899977096215655`
  - client_secret `9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9`
  - **ASSUMPTION(G0): verified at G1** — that these are still the current values and that
    `auth.gog.com/token` accepts them.
- Authorization URL: `https://auth.gog.com/auth?client_id=…&redirect_uri=https://embed.gog.com/on_login_success?origin=client&response_type=code&layout=client2`.
- Success redirect prefix: `https://embed.gog.com/on_login_success` — `GOGAuthRedirectParser`
  extracts `code` (and recognises `error=access_denied`/`cancel` and other failures).
- Token DTO fields assumed: `access_token`, `refresh_token`, `expires_in`, `user_id`,
  `session_id` (lenient on extras). **ASSUMPTION(G0): confirm at G1.**

## Response shapes (each strict on required fields, lenient on the rest)

- `userData.json` — required `isLoggedIn`; `username` shown in Settings; `userId` assumed a
  string. `isLoggedIn:false` ⇒ auth failure, never cached. **ASSUMPTION(G0): confirm at G2.**
- `user/data/games` — assumed `{ "owned": [<int id>…] }`. **ASSUMPTION(G0): confirm at G3.**
- `account/getFilteredProducts?mediaType=1&page=n` — required `products[]`, `page`,
  `totalPages`, `totalProducts`; per product required `id`, `title`, `worksOn`.
  **ASSUMPTION(G0): confirm at G4/G5.**
  - `releaseDate` shape is inconsistent (Unix ts / `{ "date": "YYYY-MM-DD …" }` / string /
    null); `GOGReleaseDate` decodes any of these to just a `year`. **ASSUMPTION(G0).**
  - **Noise detection** keys off `isGame`, `isMovie`, `isHidden`, `category` and title
    keywords (soundtrack/artbook/goodies, DLC/expansion/season pass/-pack, demo/prologue).
    These are the only signals `getFilteredProducts` gives without a per-game
    `gameDetails` call (off the allow-list in v1). The keyword lists are conservative —
    a wrong guess only moves a title to the restorable *Ignored* bucket, never drops it.
    **ASSUMPTION(G0): tune against real titles at G4/G5.**

## Behaviour to confirm live (G4–G7)

- Page echo, constant `totalPages`/`totalProducts` across pages, no duplicate ids,
  Σ products = `totalProducts`, owned-ids ↔ pages cross-check (reported, not fatal).
- `totalPages > 5` ⇒ ask before paging (PLAN §14.5 G4). The client's budget (15) and
  ≥ 1 s pacing are enforced regardless.
- Second sync inside the 30-day window makes **zero** requests (proved offline in tests).

## Platform note

- Default platform: `mac` when `worksOn.Mac`, else `pc` (switchable "Always PC"). A
  **Linux-only** title maps to `pc`; the review sheet shows a "Linux-only → PC" chip.
  Resolved (wave 8, lane B): `GOGMapping` sets transient `macAvailable`/`linuxOnly` flags on
  the staging row (no schema change), and the review sheet re-maps platforms on the policy
  switch from `macAvailable` and shows the note from `linuxOnly`.

## Live result — 2026-09-19 (owner ran G1–G6 in the app)

Sign-in (OAuth with the Galaxy client id/secret) and the first sync **worked on the first try**: token exchange accepted, `userData.json` valid, `user/data/games` = 66 owned ids, `getFilteredProducts` = 1 page / 43 products (the 23-id gap is DLC/extras GOG counts as owned but does not list as products — reported, not fatal), **3 data requests, 0 rejects**; 39 games imported as digital `source = gog` copies with their external ids, 4 left unmatched/undecided in staging. Migration v5 ran on the real library behind a `premigration-v5-…` backup. The G0 assumptions about the token DTO, `userData`, owned ids and the product page shape therefore hold as of this date. Not yet exercised live: multi-page libraries (> 100 products), token refresh after expiry, G7 (second sync = 0 requests) — confirm on the next sync.

## Live-step runbook (G1–G7) — orchestrator + owner, PLAN §14.5

Every live step is **stop-and-ask**: make exactly the listed requests; if the response is
not the proper content (wrong status, HTML/login page/captcha, error envelope, schema
mismatch, suspicious emptiness, rate limit, auth challenge, anything unforeseen) **stop all
GOG traffic, do not retry or vary, report what was sent/received with tokens + user id +
e-mail redacted, and wait for explicit owner approval** (one action per approval). Run the
**live build (no `-VGNSampleData`)** so the real GOG objects exist; the owner is present.

- **G1 — Sign in (the web login + 1 token call).** Settings ▸ Accounts ▸ **GOG** ▸
  *Sign In to GOG…*. A private window opens on GOG's own login page (address line shows the
  host — it should stay `auth.gog.com` / `login.gog.com` / `www.gog.com`). The owner signs in.
  *Proper content:* the window closes itself and the pane flips to signed-in with the owner's
  **username**. Sub-frames (GOG's captcha iframe) are allowed; only the *window's own* page is
  held to the host list. *If it shows "Blocked a page from `<host>`"* the login tried to take
  the whole window to an unlisted host — **stop** and report the host; do not add it blindly.
  A refused client id/secret or
  an unexpected redirect ⇒ stop and ask. **Ask before G2.**
- **G2–G5 run as ONE *Sync Now*** (the UI has no step mode): ≤ 15 requests, serial, ≥ 1 s apart, and the code stops at the first response that is not proper content — that is the stop-and-ask point; the pane then shows the reject. The owner approved this shape or asks for a step mode before the first sync.
- **G2 — Account (1 request).** *Sync Now* begins; the first request is `userData.json`.
  *Proper content:* `isLoggedIn: true` + the owner's username shown. Report, continue if valid.
- **G3 — Owned ids (1 request).** `user/data/games`. *Proper content:* a non-empty id list;
  report the count.
- **G4 — Library page 1 (1 request).** `account/getFilteredProducts…page=1`. *Proper content:*
  a products array + `totalPages`/`totalProducts`; report the counts. **If `totalPages > 5`,
  stop and ask before paging.**
- **G5 — Remaining pages (≤ 5 requests).** Only after G4 approval. *Proper content:* each page
  echoes its number, totals stay constant, no duplicate ids, Σ products = `totalProducts`.
- **G6 — Full sync from cache (0 GOG requests).** The review sheet opens: *New / Already
  matched / Ignored* buckets, the platform switch, per-row alternatives. IGDB calls happen here
  (matching only). Tick, adjust platforms, ignore/restore, then **Import N Games**. The commit
  is one transaction; a banner reads "N games imported from GOG · M already in your library".
- **G7 — Second sync (0 requests, inside the 30-day window).** *Sync Now* again: it makes no
  GOG requests and proposes nothing new (all committed titles are now *Already matched*).

**Where rejects show:** any bogus response stops the sync and the **error surface** appears in
the Settings ▸ GOG pane — the reason, the sentence *"VGN stopped and made no further
requests."*, and a **Response excerpt** disclosure (already redacted). The last good cache is
untouched.

**Force refresh / wipe:** each data set has a *Force Refresh…* button; it confirms the request
cost and the cached age before spending anything (only that set is re-fetched on the next sync).
*Sign Out…* removes the tokens, and its **"Also delete cached GOG responses"** tick wipes the
`import_cache` rows for `source = 'gog'`.

**Fixtures:** before committing any fixture recorded during G1–G7, scrub username, user id,
e-mail, avatar and order data; tokens and cookies never appear in logs, fixtures, prompts or
commits.

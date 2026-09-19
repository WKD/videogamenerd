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
  **Linux-only** title maps to `pc`; PLAN §14.3 asks for a UI note on those — there is no
  note column in `import_titles`, so the review-sheet lane should surface it from the
  mapping (`GOGMapping` knows the product ran only on Linux). **[review-sheet lane]**

# VGN — Human acceptance checklist & known issues

Things machines can't judge (or that need the owner's data/eyes). Updated by the orchestrator as features merge. Machine gates (build, tests, launch smoke) are not repeated here.

## To verify by hand

### Wave 0 / M0
- [ ] `docs/shelf-truth-draft.json` — correct the draft list of games per sample photo. It becomes the answer key for the M6 accuracy run. Two music DVDs at the right of IMG_3685 were excluded on purpose.
  - Owner feedback 2026-09-18: the second "ELDEN RING" spine was an empty sleeve (box now back inside) → one Elden Ring; the white Konami MGS V box is a special vendor SteelBook collector's edition (which MGS V game — Phantom Pain or Ground Zeroes — still to confirm).
  - **Sample set changed 2026-09-18** (done): `IMG_3681`/`IMG_3682` retired, `IMG_3687` added; fixtures, tiles 1–3 and the truth file were refreshed. Items per photo: 3683: 30 · 3684: 19 · 3685: 26 · 3686: 1 · 3687: 93.
  - Doubts to check first in `IMG_3687`: (1) which MGS V game is the white SteelBook (spine unreadable); (2) a slim all-black spine between *Death Stranding* and *Terminator 2D*, and a plain dark-grey spine between the MGS box and *Detroit* — games or empty slipcases? (not listed); (3) *Deponia* (PS4), low confidence; (4) *Death Stranding* PS5 = Director's Cut? *FF VII Remake* PS5 = Intergrade?
- [ ] `VGN/Resources/platforms.json` — skim the 61 platforms: slugs are forever (DB primary keys), sidebar `group` assignments, anything you own that is missing.

## Known issues / watch list
- **Title normaliser over-strips budget labels**: the `.articleless` level strips trailing "Platinum / Essentials / Greatest Hits / Player's Choice", so *Pokémon Platinum* collapses to "pokemon". Exact `.canonical` matching protects precision; only bites if two real titles collapse to the same form. Fix if seen: gate budget-label stripping behind a flag in `TitleNormalizer`.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

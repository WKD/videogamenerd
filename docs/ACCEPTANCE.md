# VGN — Human acceptance checklist & known issues

Things machines can't judge (or that need the owner's data/eyes). Updated by the orchestrator as features merge. Machine gates (build, tests, launch smoke) are not repeated here.

## To verify by hand

### Wave 0 / M0
- [ ] `docs/shelf-truth-draft.json` — correct the draft list of games per sample photo (177 entries). It becomes the answer key for the M6 accuracy run. Known doubts: two adjacent "ELDEN RING" spines (duplicate vs Shadow of the Erdtree?), the white Konami MGS V box edition, exact editions generally. Two music DVDs at the right of IMG_3685 were excluded on purpose.
- [ ] `VGN/Resources/platforms.json` — skim the 61 platforms: slugs are forever (DB primary keys), sidebar `group` assignments, anything you own that is missing.

## Known issues / watch list
- **Title normaliser over-strips budget labels**: the `.articleless` level strips trailing "Platinum / Essentials / Greatest Hits / Player's Choice", so *Pokémon Platinum* collapses to "pokemon". Exact `.canonical` matching protects precision; only bites if two real titles collapse to the same form. Fix if seen: gate budget-label stripping behind a flag in `TitleNormalizer`.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

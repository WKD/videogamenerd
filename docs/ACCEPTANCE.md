# VGN — Human acceptance checklist & known issues

Things machines can't judge (or that need the owner's data/eyes). Updated by the orchestrator as features merge. Machine gates (build, tests, launch smoke) are not repeated here.

## To verify by hand

### Wave 0 / M0
- [x] `docs/shelf-truth-draft.json` — **owner-reviewed 2026-09-18.** Items per photo: 3683: 59 · 3684: 20 · 3685: 27 · 3686: 1 · 3687: 93. It is now the answer key for the M6 accuracy run.
  - Owner corrections applied: MGS V = *The Phantom Pain* (special vendor SteelBook); one Elden Ring (the second spine was an empty sleeve); PS5 *Death Stranding* is *Death Stranding 2*; *Deponia* is *Goodbye Deponia*; *Catherine* (PS3) added after *Darksiders* in 3684/3685; *Alice: Madness Returns* is Xbox 360; the *L.A. Noire* in 3684 is the Xbox 360 copy; IMG_3683 rebuilt (the draft had 30 of ~59 spines and two games that are not in that photo).
  - Closed 2026-09-18: PS5 *FF VII Remake* is not Intergrade; the two unlabelled spines in IMG_3687 are skipped (`skip` in the JSON) — unreadable spines are never guessed, neither by the answer key nor by the recogniser.
  - **Lesson for the M6 recogniser/harness** (from the draft's IMG_3683 failure): a vision model reading several overlapping shelf photos in one context (a) silently skips most of a dense row when working from a downsized image and (b) pattern-completes from neighbouring photos (it listed *Darksiders* / *Alice* in a frame where they don't appear). The app's design already isolates each tile in its own `claude -p` call with full-resolution crops; the accuracy harness must measure **recall per row** and **false positives per photo** separately, not just overall precision.
- [ ] `VGN/Resources/platforms.json` — skim the 61 platforms: slugs are forever (DB primary keys), sidebar `group` assignments, anything you own that is missing.

## Known issues / watch list
- **Title normaliser over-strips budget labels**: the `.articleless` level strips trailing "Platinum / Essentials / Greatest Hits / Player's Choice", so *Pokémon Platinum* collapses to "pokemon". Exact `.canonical` matching protects precision; only bites if two real titles collapse to the same form. Fix if seen: gate budget-label stripping behind a flag in `TitleNormalizer`.
- **Fuzzy thresholds** (`FuzzyMatch.confidentThreshold = 0.90`, `plausibleThreshold = 0.74`) were tuned on a hand-made table; re-check against real IGDB / libretro names once covers and photo scan run on the real library.
- **LibretroIndex** debug-build timing: 10 k names index ≈ 620 ms, 1 k lookups ≈ 950 ms. Fine off the main thread; revisit if cover matching feels slow.
- App icon and accent colour are placeholders (milestone 9).

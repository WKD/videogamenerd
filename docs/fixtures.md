# Shelf image fixtures

Test fixtures derived from the 6 original shelf photos. The **originals are never
committed** — they live in `../samples/IMG_3681.png … IMG_3686.png` (git-ignored via
`samples/` in `.gitignore`) and are read-only input.

All committed fixtures live under `VGNTests/Fixtures/shelf/`. Total committed weight
≈ 5.1 MB (6 downsized photos ≈ 2.9 MB + 6 tiles ≈ 2.2 MB), under the ~6 MB budget.

## Originals (not committed)

| File | Dimensions | Size | Content |
|---|---|---|---|
| `IMG_3681.png` | 5712 × 4284 | ~25 MB | Top two shelves, left: PS5 row over PS4 row |
| `IMG_3682.png` | 5712 × 4284 | ~26 MB | Same shelves, panned right (PS5→PS4→PS3) |
| `IMG_3683.png` | 5712 × 4284 | ~26 MB | Same shelves, panned further right |
| `IMG_3684.png` | 5712 × 4284 | ~26 MB | Lower shelf close-up: PS3 spines + start of Xbox 360 |
| `IMG_3685.png` | 5712 × 4284 | ~26 MB | Lower shelf: PS3 → Xbox 360 → Nintendo Switch (red) |
| `IMG_3686.png` | 4032 × 3024 | ~10 MB | Single front-cover shot, held in hand: *Clair Obscur: Expedition 33* (PS5) |

The 5 shelf photos (3681–3685) pan left-to-right across the same wall unit, so games
overlap between consecutive frames. 3686 is a separate front-cover close-up.

## Downsized photos — `IMG_368x.jpg`

Each original downsized to 2000 px on the long edge, JPEG quality 70. These are the
"whole photo" fixtures (fast to load, spine text still broadly readable).

Produced with `sips` (repeatable for all six):

```sh
for n in 3681 3682 3683 3684 3685 3686; do
  sips -s format jpeg -s formatOptions 70 -Z 2000 \
    ../samples/IMG_${n}.png --out VGNTests/Fixtures/shelf/IMG_${n}.jpg
done
```

Result: 2000 × 1500 (3681–3685) / 2000 × 1500-ish (3686 is 4:3 → 2000 × 1500), each
≈ 370–570 KB.

## Tiles — `tiles/*.jpg`

Full-resolution crops cut straight from the **originals** (no upscaling), ~1500 px,
JPEG quality 80. These keep spine text crisp and are the primary input the Wave 4
`ShelfRecognizer` will be tested against. Each is chosen for a distinct challenge.

Produced with `scripts/crop-tiles.swift` (ImageIO crop; args are the top-left offset
and size in the **original** pixel space):

```sh
# swift scripts/crop-tiles.swift <in.png> <out.jpg> <x> <y> <w> <h> [quality=0.8]
swift scripts/crop-tiles.swift ../samples/IMG_3681.png tiles/tile1_ps5_row.jpg        520  180  1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3681.png tiles/tile2_ps4_row.jpg        520  2450 1600 1560
swift scripts/crop-tiles.swift ../samples/IMG_3682.png tiles/tile3_french_titles.jpg  1820 240  1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3684.png tiles/tile4_ps3_collector.jpg  1700 1350 1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3685.png tiles/tile5_switch_xbox360.jpg 2750 1500 1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3686.png tiles/tile6_front_cover.jpg    740  180  1560 2000
```

| Tile | Source | Region (x,y,w,h in original px) | Why it's here |
|---|---|---|---|
| `tile1_ps5_row.jpg` | IMG_3681 | 520,180,1560,1560 | PS4/PS5 spine banners + clean English titles (Until Dawn, The Quarry, House of Ashes, Silent Hill 2, Bramble, LEGO Star Wars, The Medium, Demon's Souls) — the easy baseline |
| `tile2_ps4_row.jpg` | IMG_3681 | 520,2450,1600,1560 | Dense PS4 row (Resident Evil, Prey, Uncharted 4, The Evil Within, Dark Souls III, FFXII, Astro Bot, Ni no Kuni II) |
| `tile3_french_titles.jpg` | IMG_3682 | 1820,240,1560,1560 | French edition + special editions: *Les Chevaliers de Baphomet – L'ombre des Templiers: Reforged*, *Final Fantasy XVI Édition Deluxe*, Alan Wake Remastered, Syberia Remastered |
| `tile4_ps3_collector.jpg` | IMG_3684 | 1700,1350,1560,1560 | Collector/compilation spines: *Metal Gear Solid: The Legacy Collection*, LEGO *Harry Potter Années 5 à 7* (French), Batman Arkham Asylum, God of War III, Guitar Hero Metallica |
| `tile5_switch_xbox360.jpg` | IMG_3685 | 2750,1500,1560,1560 | Mixed-platform boundary: Xbox 360 spines (Dark Souls, FFXIII, Alone in the Dark, Walking Dead GOTY, FF Pixel Remaster) meeting Nintendo Switch reds (Mandragora, Mario Wonder, 3D All-Stars, Odyssey, Mario + Rabbids) |
| `tile6_front_cover.jpg` | IMG_3686 | 740,180,1560,2000 | Front-cover shot (portrait): *Clair Obscur: Expedition 33* (PS5) — the non-spine case |

To regenerate everything: `sips` loop above, then the `crop-tiles.swift` calls.
Requires the originals present in `../samples/`.

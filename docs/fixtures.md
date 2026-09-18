# Shelf image fixtures

Test fixtures derived from the 5 original shelf photos. The **originals are never
committed** — they live in `../samples/` (git-ignored via `samples/` in `.gitignore`)
and are read-only input.

All committed fixtures live under `VGNTests/Fixtures/shelf/`. Total committed weight
≈ 4.4 MB (5 downsized photos ≈ 2.3 MB + 6 tiles ≈ 2.2 MB), under the ~6 MB budget.

## Sample set change (2026-09-18)

**`IMG_3681.png` and `IMG_3682.png` were retired** and **`IMG_3687.png` added**. In the
old 3681/3682 an empty *Elden Ring* sleeve stood next to the boxed game, so it looked
like two copies; the box is now back inside the sleeve → exactly **one** Elden Ring.
`IMG_3687` is a single, wider frame that covers the same two shelves the retired pair
covered, so nothing is lost. The committed downsized JPEGs `IMG_3681.jpg`/`IMG_3682.jpg`
and the three tiles cut from them (`tile1_ps5_row`, `tile2_ps4_row`, `tile3_french_titles`)
were removed and re-cut from `IMG_3687`.

## Originals (not committed)

| File | Dimensions | Size | Content |
|---|---|---|---|
| `IMG_3683.png` | 5712 × 4284 | ~26 MB | Upper + lower shelves, panned right (PS5→PS4→PS3) |
| `IMG_3684.png` | 5712 × 4284 | ~26 MB | Lower shelf close-up: PS3 spines + start of Xbox 360 |
| `IMG_3685.png` | 5712 × 4284 | ~26 MB | Lower shelf: PS3 → Xbox 360 → Nintendo Switch (red) |
| `IMG_3686.png` | 4032 × 3024 | ~10 MB | Single front-cover shot, held in hand: *Clair Obscur: Expedition 33* (PS5) |
| `IMG_3687.png` | 5699 × 3452 | ~21 MB | Single wide frame: upper shelf PS5→PS4 row, lower shelf PS4→PS3 row (replaces retired 3681/3682) |

`IMG_3683`–`3685` pan left-to-right across the same wall unit, so games overlap between
consecutive frames. `IMG_3687` is a single wide 2-shelf frame of the left half of that
unit (wider/shorter aspect than the 4:3 frames). `IMG_3686` is a separate front-cover
close-up.

## Downsized photos — `IMG_368x.jpg`

Each original downsized to 2000 px on the long edge, JPEG quality 70. These are the
"whole photo" fixtures (fast to load, spine text still broadly readable).

Produced with `sips` (repeatable for all five):

```sh
for n in 3683 3684 3685 3686 3687; do
  sips -s format jpeg -s formatOptions 70 -Z 2000 \
    ../samples/IMG_${n}.png --out VGNTests/Fixtures/shelf/IMG_${n}.jpg
done
```

Result: 2000 × 1500 (3683–3685), 2000 × 1500 (3686 is 4:3), 2000 × 1211 (3687 is the
wide frame), each ≈ 376–567 KB.

## Tiles — `tiles/*.jpg`

Full-resolution crops cut straight from the **originals** (no upscaling), ~1500 px,
JPEG quality 80. These keep spine text crisp and are the primary input the Wave 4
`ShelfRecognizer` will be tested against. Each is chosen for a distinct challenge.

Produced with `scripts/crop-tiles.swift` (ImageIO crop; args are the top-left offset
and size in the **original** pixel space):

Tiles 1–3 are cut from the new `IMG_3687` (the wide frame is only 3452 px tall, so
these are 1560 × 1250, sized to fit the spine band without spilling into the shelf);
tiles 4–6 are unchanged.

```sh
# swift scripts/crop-tiles.swift <in.png> <out.jpg> <x> <y> <w> <h> [quality=0.8]
swift scripts/crop-tiles.swift ../samples/IMG_3687.png tiles/tile1_ps5_row.jpg        300  400  1560 1250
swift scripts/crop-tiles.swift ../samples/IMG_3687.png tiles/tile2_ps4_row.jpg        280  1980 1560 1250
swift scripts/crop-tiles.swift ../samples/IMG_3687.png tiles/tile3_french_titles.jpg  2050 400  1560 1250
swift scripts/crop-tiles.swift ../samples/IMG_3684.png tiles/tile4_ps3_collector.jpg  1700 1350 1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3685.png tiles/tile5_switch_xbox360.jpg 2750 1500 1560 1560
swift scripts/crop-tiles.swift ../samples/IMG_3686.png tiles/tile6_front_cover.jpg    740  180  1560 2000
```

| Tile | Source | Region (x,y,w,h in original px) | Why it's here |
|---|---|---|---|
| `tile1_ps5_row.jpg` | IMG_3687 | 300,400,1560,1250 | Upper-shelf clean PS5/PS4 baseline: Until Dawn (PS4), House of Ashes, Silent Hill 2, Bramble, LEGO Star Wars, The Medium, Demon's Souls, Lies of P, Wukong, Expedition 33, Elden Ring (single), RE Village, Returnal, Dead Space, Callisto — the easy baseline |
| `tile2_ps4_row.jpg` | IMG_3687 | 280,1980,1560,1250 | Lower-shelf dense PS4 row: Resident Evil 7, Batman Arkham Knight, Prey, Uncharted 4, The Evil Within, Dark Souls III, FFXII Zodiac Age, Ni no Kuni II, Astro Bot, Persona 5, Star Ocean, Kingdom Come, The Last Guardian, Sekiro, Shadow of the Colossus |
| `tile3_french_titles.jpg` | IMG_3687 | 2050,400,1560,1250 | French edition + special editions: *Les Chevaliers de Baphomet – L'ombre des Templiers: Reforged*, *Final Fantasy XVI Édition Deluxe*, Alan Wake Remastered, Syberia Remastered, Death Stranding, Terminator 2D: No Fate (SteelBook) |
| `tile4_ps3_collector.jpg` | IMG_3684 | 1700,1350,1560,1560 | Collector/compilation spines: *Metal Gear Solid: The Legacy Collection*, LEGO *Harry Potter Années 5 à 7* (French), Batman Arkham Asylum, God of War III, Guitar Hero Metallica |
| `tile5_switch_xbox360.jpg` | IMG_3685 | 2750,1500,1560,1560 | Mixed-platform boundary: Xbox 360 spines (Dark Souls, FFXIII, Alone in the Dark, Walking Dead GOTY, FF Pixel Remaster) meeting Nintendo Switch reds (Mandragora, Mario Wonder, 3D All-Stars, Odyssey, Mario + Rabbids) |
| `tile6_front_cover.jpg` | IMG_3686 | 740,180,1560,2000 | Front-cover shot (portrait): *Clair Obscur: Expedition 33* (PS5) — the non-spine case |

To regenerate everything: `sips` loop above, then the `crop-tiles.swift` calls.
Requires the originals present in `../samples/`.

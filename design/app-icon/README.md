# VGN app icon — "Console Grey"

Chosen 2026-09-19 from the prototype rounds in `../../prototypes/app-icon/` (outside the repo): a charcoal rubber D-pad in a console-grey well, a flat red enamel star at the pivot.

- Grid: 1024 canvas, 824 continuous-corner body, soft drop shadow (macOS 11–15 icon grid); front-facing, few bold layers.
- `vgn-icon-default.svg` is the master; `-small` drops the arrow glyphs and enlarges the star and is used for the 16 and 32 px renditions (HIG: simplify small sizes).
- `vgn-icon-dark*.svg` and `vgn-icon-mono*.svg` are the Dark and Tinted appearances explored in the prototype. The asset catalog's macOS `AppIcon` set has a single appearance, so they are **not shipped yet**: on macOS 26 they belong in an Icon Composer `.icon` file (layers: shell · well · pad · arrows · star) — milestone 9.
- PNGs in `VGN/Assets.xcassets/AppIcon.appiconset/` were rasterised from these SVGs at 1024 px with a transparent background (headless Chrome) and downscaled with `sips`.

# VGN — Video Game Nerd

A native macOS app to catalogue every game you've owned or played, and rank them —
tiers (S A B C D F) plus one ultimate ordered Top. Built with SwiftUI + GRDB (SQLite),
Swift 6, for macOS 15+.

The idea in one line: **separate the *work* you rank (a Game) from the *thing* you own
(a Product — a disc, a licence, or a ROM; a compilation is one product with many
games).** Ranking is incremental — a new game costs one keystroke (its tier) and
~5–7 quick "this or that?" duels, forever — and every recommendation explains itself.

Full design: [`PLAN.md`](PLAN.md). Architecture, build/test details and conventions:
[`CLAUDE.md`](CLAUDE.md).

## Screenshots

_(placeholder — add window captures of the grid, Tier Board, The Top, Play Next and the
photo-scan review sheet here.)_

## Build & run

Requires Xcode 26.x (Swift 6) on macOS 15+. GRDB 7 is the only dependency (SwiftPM,
resolved by Xcode). From a clone:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd build
open .build/dd/Build/Products/Debug/Video\ Game\ Nerd.app
```

Test: the same command with `test`. Try it without touching your real data by launching
with sample data:

```sh
open .build/dd/Build/Products/Debug/Video\ Game\ Nerd.app --args -VGNSampleData YES
```

## First-run setup

Everything works offline and by keyboard; the two optional integrations below unlock
metadata and photo scanning.

1. **IGDB credentials (metadata, covers, autocomplete, time-to-beat).** Create a Twitch
   application to get a client id + secret, then enter them in **Settings ▸ Accounts** and
   hit **Test connection**. They're stored in the macOS Keychain. Without them the app
   still runs — you just add and rank games by hand, with no automatic covers/metadata.
2. **Claude CLI (photo scan + "Ask Claude" second opinion).** Photo scan reads your shelf
   photos through your local, logged-in `claude` CLI (subscription-billed, no API key).
   Install Claude Code and log in, then point **Settings ▸ Photo Scan** at the `claude`
   binary (it auto-detects). Optional — Quick Add and manual entry don't need it.

## Where your data lives

`~/Library/Application Support/VGN/`:

- `vgn.sqlite` — the library (SQLite, WAL).
- `covers/`, `thumbs/` — box art originals and pre-downsampled grid thumbnails (library
  assets, not a cache).
- `backups/` — automatic snapshots.

## Backups & export

- **Automatic snapshots:** a consistent copy of the database is written to `backups/` on
  launch (last 10 kept). A snapshot can be restored via `AppDatabase.restoreLive(from:)`
  at the next launch.
- **Export:** the whole library exports to a complete, re-importable **JSON** document
  (games, products, memberships, tiers/ranks, playtime, statuses, traits, and the full
  duel log) or a flat **CSV** (one row per game, with the derived 1–10 score and overall
  rank) via `LibraryExporter`.

Your library is meant to hold years of curation — snapshots, exports and the
played-or-owned / consistent-rank invariants all exist to keep it safe.

## Status

Milestones 0–6 (catalogue → browse → rank → playtime → Play Next → photo scan) are built.
Not yet built: PSN/GOG import, the full stats view, and macOS 26 "Liquid Glass" polish.
See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) for the honest list of what's imperfect,
deferred, or needs a human's eyes.

Personal, non-commercial app; not affiliated with IGDB, Twitch, Sony, or Anthropic.

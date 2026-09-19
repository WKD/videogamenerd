# Delicious Library 2 import (PLAN §5.5)

The first **file** importer: read an old **Delicious Library 2** catalogue
(`.deliciouslibrary2`) and import the owner's video games as *owned, physical* copies.
It reuses the whole shared importer machinery (§14): `LibraryImporter` →
`ImportSyncCoordinator` → staging → matching → the shared review sheet → one-transaction
commit. There is no network, cache, budget or pacer — a file needs none.

## The file format

A `.deliciouslibrary2` is a **Core Data SQLite** store. It holds *all* of the owner's
media, not just games: ~1 300 movies, ~330 books, music, and loan records. It is
**private** and lives outside the repo; it is never copied or committed.

- **Items table:** `ZABSTRACTAMAZONATTRIBUTESHOLDER`. The owner's catalogued items are
  rows of the **`Medium`** entity; other `Z_ENT` values are Amazon recommendation/cache
  rows and are ignored.
- **Entity ids are resolved by NAME**, never hard-coded: `SELECT Z_ENT FROM Z_PRIMARYKEY
  WHERE Z_NAME = 'Medium'` (it happens to be 6 in the owner's file, but the reader never
  assumes that).
- **Games** are Medium rows with `ZTYPE = 'VideoGame'` (103 in the owner's file). Rows of
  any other `ZTYPE` (Movie/Book/…) are never read — the reader's `SELECT` is scoped to
  `Z_ENT = <Medium> AND ZTYPE = 'VideoGame'`, so no non-game content is ever loaded.
- **Columns used** (all on the items table):
  | column | meaning |
  |---|---|
  | `ZUUIDSTRING` | stable id → import `external_id` |
  | `ZTITLE` | Amazon FR/UK title (noisy), kept & shown as-is |
  | `ZPLATFORMSCOMPOSITESTRING` | newline-separated platform labels |
  | `ZEAN` / `ZASIN` | barcode / Amazon id |
  | `ZPUBLISHDATE` | release date → year (tie-breaker) |
  | `ZCREATIONDATE` | when catalogued ≈ acquired date (`ZPURCHASEDATE` is identical) |
  | `ZEDITIONSCOMPOSITESTRING` | e.g. "Standard Edition" |
  | `ZFORMATSINGULARSTRING` | physical media label ("Blu-ray", "Cartouche de jeu"…) |
  | `ZCOUNTRYCODE` | fr / gb |
  | `ZLOAN` | non-null ⇒ was lent out (shown as a note only) |
  | `ZCOVERIMAGE` | FK → `ZCOVERIMAGE.Z_PK` for the box-art blob |
- **Dates** are Core Data timestamps: seconds since **2001-01-01**, exactly Foundation's
  `timeIntervalSinceReferenceDate`.
- **Covers**: `Medium.ZCOVERIMAGE → CoverImage → LazyCoverImageData.ZCOMPRESSEDIMAGEDATA`,
  which is plain **JPEG** (magic `FF D8 FF`), decoded straight through ImageIO.

## Read-only & immutable

`DeliciousLibraryReader` opens the store with GRDB `Configuration.readonly` — it can only
issue `SQLITE_OPEN_READONLY`, so **no bytes are ever written**, and because a DL2 store is
in rollback-journal mode no `-wal`/`-journal` sidecar is created either. A test asserts the
file's size and mtime are unchanged after a read and that no sidecar appears. It works on a
file in a read-only folder.

Validation is a typed ladder: `notDeliciousFile` (Core Data tables absent),
`unsupportedVersion` (tables present but the DL2 shape/`Medium` entity missing),
`noVideoGames` (valid store, zero games).

## Mapping (`DeliciousMapping`, pure)

- **Platform**: labels → VGN slugs (ps3/wii/gamecube/n64/ds/dreamcast/ps1/gba…). Windows
  anything → `pc`; Macintosh/Mac OS X → `mac`; a **PC/Mac hybrid disc** follows the same
  *Mac when available* / *Always PC* policy switch GOG uses; a console label keeps its slug
  and is never re-mapped by that switch. An unrecognised label leaves the row needing a
  platform pick (the review popup offers **every** VGN platform for Delicious).
- **Title cleaning is for matching only** — the original is always kept and shown. It
  strips trailing/embedded platform tokens (PS3, Wii, DS…), media tokens (DVD Rom, CD-Rom…),
  FR/EN edition phrases (édition spéciale/collector, Standard Edition, Platinum, Essentials…),
  and a bundle tail after " + "; it **extracts the edition** onto the copy. French titles
  keep their form so the matcher's alt-name path can find them (e.g. *Cérébrale Académie* →
  *Big Brain Academy*). `matchTitle` carries the cleaned form to the matcher; `name` keeps
  the original.

## Duplicates — "discard duplicate copies"

The owner catalogued his shelf by photo scan, so a Delicious row is a duplicate when its
matched game already has an **owned copy of the same format (physical) on the same
platform** → it lands under *Already matched* ("Already on your shelf"), unticked, and is
never committed as a second copy. A digital-only existing copy, or the same game on another
platform, stays importable (with a note). Two Delicious rows resolving to the same
game+platform → one imports, the other is listed as a duplicate. Re-import is idempotent on
`(source='delicious', external_id=ZUUIDSTRING)`.

## Covers, edition, acquired date

`products.edition` / `products.acquired_at` already exist, so the extracted edition and
`ZCREATIONDATE` land on the committed copy. After commit, for a game left **without** a
cover, the review sheet's "Use my Delicious Library covers…" toggle (default ON) applies
the store's own box-art through the same path a dropped image takes, but **without** the
user-chosen marker (`LibraryStore.setImportedCoverIfEmpty`), so later enrichment may still
upgrade it. See LIMITATIONS for the caveat about enrichment only filling *empty* covers.

## Schema

Migration **v7** removes the `products.source` CHECK (the allowed set is validated in Swift
by `ProductSource`), so this and future importers add a new source without another table
rebuild. New games created by the import get v6 `origin = 'delicious'`.

## Privacy

The store is private and read-only. The reader never selects non-game rows' contents; docs,
tests and reports quote only **game titles** (product names) and aggregate counts — never a
movie/book title or a borrower name. The file is never copied or committed.

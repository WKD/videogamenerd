# Off-screen snapshot rendering

Agents (and the owner) cannot drive the app's windows, so every screen is rendered
**off-screen into PNGs inside the normal unit tests**. This gives eyes on layout
and appearance — light + dark, at two window sizes where layout matters — without
any permission grant, session takeover, or screen capture. It covers *visual
layout only*; focus/keyboard routing, drag feel and animation stay on the human
checklist (`docs/ACCEPTANCE.md`).

## How it works

`VGNTests/Snapshots/SnapshotHarness.swift` renders any SwiftUI view like this:

1. Wrap it on an opaque SwiftUI backdrop of the appearance's window colour and a
   fixed frame, forcing `\.colorScheme` and disabling animations.
2. Host it in an `NSHostingController` set as the `contentViewController` of a
   **borderless, off-screen, never-ordered-front** `NSWindow` with a forced
   `NSAppearance` (aqua / darkAqua). The controller (not a bare `NSHostingView`)
   is what lets `NavigationSplitView` / toolbars lay out headless without
   asserting.
3. Pump the main run loop + cooperative executor (`settle`) so the one-shot async
   data sources deliver and SwiftUI's deferred text/glyph pass lands, then force a
   synchronous `layoutSubtreeIfNeeded()` + `display()`.
4. Capture with `bitmapImageRepForCachingDisplay` / `cacheDisplay`, downscale to a
   **1× RGBA** bitmap, composite over the window-background colour, and write PNG.

`ImageRenderer` is deliberately **not** used: it cannot render AppKit-backed
controls (List, TextField, split views, toolbars), which is most of this app. The
window approach renders them all.

Determinism: sample/preview data sources emit **once and finish** (no clocks, no
network, no live DB), models are driven to their loaded state *before* capture
(rather than relying on `onAppear`/`.task` firing in an unshown window), and
animations are disabled. Hosting windows are retained for the whole run because
destroying a SwiftUI graph host while an async observation transaction is still
pending trips an AttributeGraph precondition (SIGABRT).

## Running

```sh
# Generate PNGs + the contact sheet (this is what the normal test run does):
xcodebuild ... test -only-testing:VGNTests/LibrarySnapshotTests   # (etc.)

# Or all snapshot suites + verify against the committed references:
scripts/snapshots.sh

# Re-record the committed reference PNGs after an intentional UI change:
scripts/snapshots.sh --record

# Generate only, no compare:
scripts/snapshots.sh --generate
```

Every run writes to `.build/snapshots/` (git-ignored):

* `<name>@light.png` / `<name>@dark.png` for each screen,
* `index.html` — a **contact sheet** grouped by screen, light and dark side by
  side. Open it to review everything on one page:
  `open .build/snapshots/index.html`.

Generation is **always on** and part of the normal unit tests (kept well under the
~30 s budget). It never fails the build on pixel differences — see below.

## Reference comparison & thresholds

A committed reference set lives in `VGNTests/Snapshots/Reference/` (PNG files, each
prefixed `snap-…` because the test bundle flattens resources into one directory;
they are read from source on disk at 1× to stay small — the whole set is well under
8 MB).

Comparison is **opt-in** via `VGN_SNAPSHOT_VERIFY=1` (what `scripts/snapshots.sh`
sets). Reason: sub-pixel text anti-aliasing is **not bit-stable** across machines
and OS point releases, so making every run diff would flake. Stability matters more
than strictness, so the default `xcodebuild test` only *generates* (always green),
and verification is a deliberate local/CI step.

When verifying, a snapshot fails only when it differs **beyond a perceptual
tolerance**:

* **Per-pixel channel tolerance:** a pixel counts as changed only if any RGBA
  channel differs by more than **12 / 255** — this absorbs anti-aliasing jitter.
* **Changed-pixel budget:** the snapshot fails only if more than **2 %** of pixels
  changed.

On a failure a `<name>@<appearance>.diff.png` (changed pixels flagged red) is
written next to the output for inspection. Thresholds are constants at the top of
`SnapshotHarness.swift` (`SnapThresholds`).

## Coverage

| Suite | Screens |
|---|---|
| `LibrarySnapshotTests` | Main window shell (empty · sample · 1 000-game grid · platform selected · filter chips active · multi-select · inspector open), grid alone, sidebar, filter-chips bar, cell states |
| `InspectorSnapshotTests` | Single game (copies), multi-select, empty |
| `QuickAddSnapshotTests` | Idle, results (cached local + live catalogue rows), bundle row, offline hint, confirmation row |
| `RankingSnapshotTests` | Duel (placement / refine / border / empty), disputes sheet, Triage (active / done), Tier Board (small / empty / 300 tiles), The Top (unfiltered / filtered / short), tier legend, unavailable |
| `PlayNextSnapshotTests` | Hero + alternatives (wide + compact), small-library banner, empty (nothing fits / no rankings), unavailable, Ask Claude (asking / agreed / disagreed / failed) |
| `ScanSnapshotTests` | Input, progress rows, review sheet (all three buckets + greyed duplicates), review compact |
| `MiscSnapshotTests` | Settings (Accounts + Photo Scan tabs), compilation editor, ownership / copy-removal / group-compilation sheets, stats popover, database-error screen, shared components (chips, placeholder covers, ranking covers) |

Layout-sensitive screens (main window, Tier Board 300, Play Next, scan review) are
captured at two sizes (≈ 1200×780 and ≈ 900×600); the rest at one representative
size. Everything is captured in both light and dark.

## What cannot be rendered off-screen (documented, not faked)

* **The window toolbar** (PLAN §8: search field, Genre/Decade/Tier/Status/Format/
  Playtime/Platform/Sort menus, size slider, +, inspector toggle). Toolbars live in
  the window's titlebar; a borderless off-screen window has no titlebar, so the
  toolbar row does not appear in the `library-root-*` snapshots. Everything *below*
  the toolbar (sidebar, filter-chips bar, grid, inspector) is captured. The toolbar
  controls themselves are exercised by `RootView`'s logic and the model tests; the
  XCUITest suite (lane B) drives them live.
* **The Quick Add floating `NSPanel` and its key handling.** The palette *content*
  (`QuickAddView`) is captured; the panel window, its ↑↓/Tab/⌘-combo `NSEvent`
  monitor and focus behaviour are the XCUITest suite's job (and remain the #1 human
  runtime risk — `docs/LIMITATIONS.md §0`).
* **Menu-bar menus, context menus, tooltips, and the real `.sheet`/`.popover`
  presentation animation.** Sheet/popover *bodies* are captured by constructing the
  view directly (ownership sheets, stats popover, compilation editor); the
  presentation chrome around them is not.
* **The enrichment status footer** — its `status`/`counts` are `private(set)` and
  driven by live service actors, so no representative non-idle state can be built
  with sample data; it renders as its idle (hidden) state and is otherwise
  unverified here.
* **Live covers** — the cover pipeline is not wired in this preview mode, so every
  cell shows its generated placeholder art (the real day-one state). Real-cover
  scroll/quality is a separate hardening item.
* **Drag-and-drop, divider drag, scrolling, and any motion** — visual layout only.

## Defects found and fixed (snapshot review)

See `## Snapshot review — defects` below; each entry names the snapshot(s) it was
found in.

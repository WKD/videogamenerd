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

The snapshot suites are **off in a plain `xcodebuild test`** and are enabled by
the script (or `VGN_SNAPSHOTS=1`):

```sh
# Generate every screen's PNGs + the contact sheet, and verify against refs:
scripts/snapshots.sh

# Just generate (no compare) — the usual "give me eyes" command:
scripts/snapshots.sh --generate

# Re-record the committed reference PNGs after an intentional UI change:
scripts/snapshots.sh --record

# Or a single suite directly:
VGN_SNAPSHOTS=1 xcodebuild ... test -only-testing:VGNTests/RankingSnapshotTests
```

A run writes to `.build/snapshots/` (git-ignored):

* `<name>@light.png` / `<name>@dark.png` for each screen,
* `index.html` — a **contact sheet** grouped by screen, light and dark side by
  side. Open it to review everything on one page:
  `open .build/snapshots/index.html`.

### Why they are not in the default `xcodebuild test`

Rendering is main-thread / CPU-heavy. Swift Testing runs suites **in parallel**,
and when the snapshot suites render alongside the rest of the target they steal
enough of the main actor / CPU (especially with another agent building on the
same machine) to push timing-sensitive tests past their budget — e.g. Quick Add's
`debounceCoalescesAndCancelsPrevious` (a 30 ms debounce checked after 150 ms)
flakes. Measured: the full 655-test suite is green and fast on its own, and green
with the snapshot suites *disabled*; enabling them in parallel reproducibly flaked
that one debounce test. So they are gated behind `snapshotSuitesEnabled()`
(a `.build/snapshot-run` sentinel the script drops, or `VGN_SNAPSHOTS=1`), which
keeps the gate green, fast (0 s added) and non-flaky. The whole snapshot run is
~35 s of test time on its own. Getting eyes on the UI is one command
(`scripts/snapshots.sh --generate`); generation is always on **within that run**.

## Reference comparison & thresholds

A committed reference set lives in `VGNTests/Snapshots/Reference/` (PNG files, each
prefixed `snap-…` because the test bundle flattens resources into one directory;
they are read from source on disk at 1× to stay small — the whole set is well under
8 MB).

Comparison is **opt-in**: `scripts/snapshots.sh` turns it on by dropping a
`.build/snapshot-verify` sentinel file (a macOS unit-test host does not inherit
the shell's environment, so a file — which the test process reads anyway — is
used instead of an env var; `VGN_SNAPSHOT_VERIFY=1` still works for direct
`xcodebuild` calls). Reason: sub-pixel text anti-aliasing is **not bit-stable** across machines
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

**Stability — run the suites SERIALLY (wave 18).** `scripts/snapshots.sh` now passes
`-parallel-testing-enabled NO`. Rendering is main-thread work; when the snapshot suites
ran **in parallel** they stole main-actor time from each other's deferred glyph/text
pass, so the sub-pixel anti-aliasing came out **non-deterministic run to run** — a
same-machine record→verify (both parallel) flaked on ~16 *random* screens at 2–7 %
(different set each run, i.e. pure AA noise, not a real diff). This is worse than the
one-off `playnext-small-library` timing case the earlier note described. Serialising the
suites makes the round-trip **stable**: a full serial record→verify is clean, and a
repeated serial verify stays clean. Always record and verify with the script (or add the
flag yourself) so both sides use the same serial timing. References are downscaled to
560 px wide before committing (the current capture is downscaled to match before
comparing), which keeps the set small.

## Coverage

| Suite | Screens |
|---|---|
| `LibrarySnapshotTests` | Main window shell (empty · sample · 1 000-game grid · platform selected · filter chips active · multi-select · inspector open), grid alone, sidebar, filter-chips bar, cell states |
| `InspectorSnapshotTests` | Single game (copies), multi-select, empty |
| `QuickAddSnapshotTests` | Idle, results (cached local + live catalogue rows), bundle row, offline hint, confirmation row |
| `RankingSnapshotTests` | Duel (placement / refine / border / empty), disputes sheet, Triage (active / done), Tier Board (small / empty / 300 tiles), The Top (unfiltered / filtered / short), tier legend, unavailable |
| `PlayNextSnapshotTests` | Hero + alternatives (wide + compact), small-library banner, empty (nothing fits / no rankings), unavailable, Ask Claude (asking / agreed / disagreed / failed) |
| `ScanSnapshotTests` | Input, progress rows, review sheet (all three buckets + greyed duplicates), review compact |
| `MiscSnapshotTests` | Settings (Accounts + Photo Scan tabs), compilation editor, ownership / batch-mark-owned / copy-removal / group-compilation sheets, stats popover, database-error screen, shared components (chips, placeholder covers, ranking covers) |
| `StatsSnapshotTests` | Library Stats dashboard (populated + empty scope) — the new full-window stats view (`stats-popover` in Misc is the sidebar popover) |
| `BatoceraSnapshotTests` | ROM catalogue browser, Discover card, Settings ▸ Batocera pane |
| `GOGSnapshotTests` | Import-from-GOG review sheet, account pane (signed-out / signed-in / rejected) |
| `DeliciousSnapshotTests` | Import-from-Delicious review sheet |

The four suites above (Stats, Batocera, GOG, Delicious) were added to disk in waves 12–17
but were **missing from `scripts/snapshots.sh`** until wave 18, so their references had
never been recorded; they are now in the script and recorded.

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

## Snapshot review — defects

Every screen was reviewed by eye in both appearances against PLAN §8/§7/§7b.

### Fixed (surgical, in `VGN/UI/**`)

* **Bulk "Mark Owned" sheet leaked raw grammar-agreement markup (wave 18).** The title
  and subtitle read literally `Mark ^[4 Game](inflect: true) as Owned` /
  `^[4 game](inflect: true) to mark owned …` instead of "Mark 4 Games as Owned". Cause:
  `BatchOwnershipModel.title` and the summary were built as runtime `String`s and rendered
  with `Text(String)`, which is **verbatim** — SwiftUI's `inflect:` grammar agreement only
  runs for a string *literal* (`LocalizedStringKey`). This is a real app bug (not an
  off-screen artifact — the live app rendered the markup too). Fixed in
  `BatchOwnershipSheet` by rendering the title + summary from string literals (the summary
  as a concatenated `Text`). Found by eyeballing `sheet-batch-owned` before recording it.

* **Duel header showed the progress count twice** — `ranking-duel-placement`
  read "Placing Bloodborne in S · 3 of ~6" *and* a second "3 of ~6" beside it.
  The presentation's `text` already embeds the step and the view also rendered
  `stepText` separately. Fixed in `DuelView.headerAttributed` by stripping the
  " · <step>" suffix from the title (the separate monospaced step stays); the
  `DuelPresentation` value + its tests are untouched.
* **Play Next "Completionist" toggle wrapped to three lines** — `playnext-hero`
  at ≤ ~940 pt the checkbox label broke as "Com-/ple-/tionist" because the
  bracket row is busy. Fixed with `.fixedSize()` on the toggle in
  `PlayNextBracketBar` so the label never wraps.
* **Placeholder cover tint changed on every launch** — `Color.stableTint(for:)`
  (behind every generated cover) used `Hasher`, whose per-process random seed
  made each game's tile a different colour every run (the comment claimed
  "stable"; it wasn't). Switched to FNV-1a over the UTF-8 bytes — deterministic
  across launches. This was also the sole source of snapshot non-reproducibility:
  it took the opt-in verify from 59 changed snapshots down to 1.

### Root cause fixed upstream (cherry-picked, not this lane's find)

* **100 % CPU render loop in `LibraryGridView`** — its context-menu builder
  mutated the selection (`vm.selectOnly`) during view updates, so a hosted grid
  never went idle (this is *why* the live grid could not be snapshotted). Fixed
  on `main` (84381e8) and cherry-picked here; the empty grid path (no ScrollView)
  now snapshots as the real `LibraryGridView`, the populated grid via
  `GridContent`.

### Deferred (needs an owner decision — added to `docs/LIMITATIONS.md`)

* **Inspector "Status" row renders "100 %"** for a completed game
  (`inspector-single`) rather than a status word (Backlog/Playing/Finished/…).
  It may be an intentional completion-percentage control; left as-is pending the
  owner's call rather than changed blind.

## Overall visual quality (for the owner)

Uniformly high. Spacing, corner radii and chip styling are consistent across
screens; dark mode is correct everywhere (no white-on-white, tier-colour chips
stay legible); covers aspect-fit (never cropped); empty states use tasteful
`ContentUnavailableView`s. Per screen:

* **Main window** — clean three-pane composition; sidebar counts, grid badges
  (tier · owned/played · ROM · compilation stack) and the inspector all read
  well at both sizes.
* **Quick Add** — polished Spotlight-style palette; rows, "in library" markers,
  flags and shortcut hints are crisp.
* **Ranking** — Duel (fixed), Triage, Tier Board (dense to 300 tiles) and The Top
  (podium + distribution strip + dividers) all look production-ready.
* **Play Next** — rich hero + alternatives with reason lines and match-strength
  badges; the Ask-Claude two-column layout works; one wrap fixed.
* **Photo scan** — the review sheet's three buckets, greyed duplicates and
  edition hints are clear (the photo pane shows "No photo" as a real image can't
  be bundled).
* **Settings / sheets / components** — tidy and consistent.

# VGN — On-demand XCUITest smoke suite

A `VGNUITests` bundle that launches the **real** app in sample-data mode and drives
its keyboard/focus flows through the accessibility layer, attaching **window-only**
screenshots. It exists because "nobody has driven the GUI" (`docs/LIMITATIONS.md`
§0) — the 655 unit tests and off-screen snapshots cover models and layout, but not
focus routing, key leakage, panel first-responder, or default buttons. This suite
exercises exactly those.

It is **on demand only**. It is NOT in the everyday `VGN` scheme's Test action and
NOT part of any agent gate: `xcodebuild -scheme VGN test` still runs only the unit
tests. The UI suite has its **own** shared scheme, `VGN-UITests`.

**Run status 2026-09-26 00:38 (main `6dea446`, orchestrator): all 12 classes PASS** — 1 intended skip (Tier Board drag). The launch-with-stale-saved-state test now passes with the W23-B guard. No screen recordings saved.

## Prerequisites (owner, one time)

Running XCUITest **takes over the keyboard and mouse** in the live login session
for a minute or two. The first run also triggers a one-time macOS permission
prompt that **only the owner can approve**:

1. When prompted, allow the test runner (Xcode / `xcodebuild`, shown as
   *"… would like to control this computer using accessibility features"* and/or an
   Automation prompt) in **System Settings ▸ Privacy & Security ▸ Accessibility**
   and **▸ Automation**. Toggle the entry on.
2. Sit an XCUITest session out — **do not touch the Mac while it runs.** A stray
   keystroke or click derails the flow (and it is driving *your* session).
3. Run it when you are away from the machine. Each run hijacks input for ~1–2 min.

If the grant is missing, the run fails early with an authorization error and no
flow executes — grant it once, then re-run. Nothing is added to your real library:
every flow launches with `-VGNSampleData YES` (in-memory DB, no network).

## How to run

```sh
# Whole suite, ONE xcodebuild run, screenshots → .build/uitests/<timestamp>/index.html
scripts/uitests.sh

# One class or one test
scripts/uitests.sh -only VGNUITests/DuelFlowTests
scripts/uitests.sh -only VGNUITests/SearchFlowTests/testSearchFocusFilterAndClear

# One xcodebuild run PER CLASS (each class becomes the "first" test → frontmost window)
scripts/uitests.sh --per-class                 # all 12 classes
scripts/uitests.sh --per-class DuelFlowTests SettingsTests   # a subset (bare class names)

# One xcodebuild run PER TEST METHOD (fallback if per-class still foregrounds only one)
scripts/uitests.sh --per-test

# Dry run — print exactly what WOULD run, execute NOTHING (safe any time)
scripts/uitests.sh --list                # the whole-suite plan
scripts/uitests.sh --list --per-class    # the per-class invocations
scripts/uitests.sh --list --per-test     # the per-method invocations
```

Or directly:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN-UITests -destination 'platform=macOS' \
  -derivedDataPath .build/dd-uitests -resultBundlePath .build/uitests/run.xcresult test
```

`scripts/uitests.sh` builds-for-testing first (fails fast without taking over the
machine), then runs, then exports every attached window screenshot to
`.build/uitests/<timestamp>/attachments/` and writes an `index.html` gallery —
**look at the screenshots** after a run. `.build/` is git-ignored.

### `--per-class` / `--per-test` (isolation; no longer required)

Written as the workaround for the old "only the first test gets a window" blocker —
which turned out to be saved-window-state restoration, fixed in wave 22 (see Run
status — 2026-09-25). The **whole-suite run now passes in one invocation**; the
per-class mode stays useful to isolate one class and to get one gallery per class.
`--per-class` runs one
`build-for-testing` up front, then **one `test-without-building` invocation per
test class** so each class is the "first" test of its own run — each with its own
`.xcresult` and screenshot gallery under `.build/uitests/<timestamp>/<Class>/`, a
short pause between runs, a `PASS`/`FAIL` line each, a final summary table, and a
non-zero exit if any class failed. `--per-test` is the same, one invocation per
`testXxx` method — the fallback if per-class still only foregrounds one window per
invocation. Classes/methods are discovered by scanning `VGNUITests/*.swift`
(`final class … : VGNUITestCase`); positional bare class names restrict the run;
`--list` prints the plan and runs nothing. `-only` applies to the whole-suite
mode only.

**Timing / takeover:** `--per-class` is ~12 invocations, `--per-test` ~23; each
launches, runs and quits a sample-data app (plus a ~3 s settle between them), so
budget roughly **10–20 min** of continuous keyboard/mouse takeover for a full
per-class run and longer for per-test. Same one-time Accessibility/Automation
grant as any run (see Prerequisites). Run only when the owner is away from the
Mac.

Screenshots are always `app.windows.firstMatch.screenshot()` (the VGN window only),
**never** `app.screenshot()` or `XCUIScreen.main.screenshot()` — on macOS both of
those capture the whole desktop, i.e. the owner's other windows. If the VGN window
can't be resolved at that instant, `VGNUITestCase.attachWindowScreenshot` (and the
Settings variant) attach **nothing** rather than fall back to a desktop capture.

**XCTest's own captures are off (wave 22).** Xcode 26 records a full-screen **video**
of every UI test by default and keeps automatic full-screen screenshots — i.e. the
owner's whole desktop. The `VGN-UITests` scheme's Test action therefore sets
`systemAttachmentLifetime = "keepNever"` and `preferredScreenCaptureFormat =
"screenshots"` (no recordings), and `scripts/uitests.sh` passes
`-collect-test-diagnostics never` (no ~100 MB log archive per failure). On a failure
`VGNUITestCase.record(_:)` attaches the **windows' and dialogs'** accessibility tree
as text instead (never `app.debugDescription`: its menu bar includes Apple ▸ Recent
Items, i.e. the owner's recent file names). XCTest still keeps its own failure-triage
text dumps (whole app tree, menu bar included) *inside* the local `.xcresult`; the
export script deletes them from the exported gallery.

## The project wiring (for future agents — do not break)

The suite is a hand-written addition to the `objectVersion 77` project
(`VGN.xcodeproj/project.pbxproj`), which uses `PBXFileSystemSynchronizedRootGroup`
(no per-file references — dropping a `.swift` under `VGNUITests/` compiles it
automatically). What was added, all in the `AA00…00NN` id namespace:

- target `VGNUITests` (id `…12`), product type
  `com.apple.product-type.bundle.ui-testing`, build setting `TEST_TARGET_NAME = VGN`
  (no `TEST_HOST`/`BUNDLE_LOADER` — a UI-testing bundle does not host the app),
  bundle id `com.pomatelier.VideoGameNerdUITests`, Swift 6, macOS 15, ad-hoc signing (`CODE_SIGN_IDENTITY = "-"` inherited).
- its synchronized root group `VGNUITests/` (id `…32`), Sources/Frameworks/Resources
  phases (`…46/47/48`), config list (`…53`), Debug/Release configs (`…66/67`), a
  dependency on the `VGN` app target (`…82` + proxy `…83`), and the product file
  reference (`…22`).
- a second shared scheme, `VGN.xcodeproj/xcshareddata/xcschemes/VGN-UITests.xcscheme`,
  whose Test action runs only `VGNUITests`. The existing `VGN.xcscheme` was **not**
  touched, so its Test action still runs only `VGNTests`.

Gate checks that must stay green:

```sh
xcodebuild -scheme VGN         -destination 'platform=macOS' test               # only the 655 unit tests
xcodebuild -scheme VGN-UITests -destination 'platform=macOS' build-for-testing  # compiles even if running is blocked
```

## Launch hooks (DEBUG-friendly, test-only)

The flows pass, in addition to `-VGNSampleData YES`:

- `-VGNDisableAnimations YES` — suppresses implicit animations so focus/label
  assertions don't race transitions. Honored in `RootView` (a `.transaction` that
  sets `disablesAnimations`, gated on the flag). Harmless in the real app.
- `-VGNOpen <screen>` — deep-links the window to a sidebar selection so a flow can
  land on a screen without clicking through the sidebar. Values: `all`, `owned`,
  `played`, `backlog`, `unranked`, `playNext`, `tierBoard`, `theTop`, `duel`,
  `triage` (opens Duel), `platform:<slug>` (e.g. `platform:ps4`). Parsed in
  `AppEnvironment.initialSelection()`.

## Accessibility identifiers

Stable, namespaced identifiers were added across `VGN/UI/**` via
`.accessibilityIdentifier(…)` — see `VGN/UI/Support/A11yID.swift` (app) and the
byte-for-byte copy in `VGNUITests/A11yIdentifiers.swift` (the UI-test bundle can't
import the app). Where state is visual only (tier chip, owned/played/ROM badges,
status, playtime, progress) an `.accessibilityLabel`/`.accessibilityValue` was added
too — a grid cell's `.value` reads e.g. `"Tier A, Owned, Played"`, which both the
tests and real VoiceOver can read. Examples: `sidebar.row.all`, `grid.cell.<id>`,
`toolbar.search`, `quickadd.field`, `duel.left`, `triage.cover`, `top.row.<id>`,
`playnext.hero`, `settings.tab.photoscan`.

## The flows

Each flow is an independent test that launches its own sample-data app and attaches
screenshots at key moments. (a)–(l) map to the hardening brief:

| # | File | What it asserts |
|---|------|-----------------|
| a | `LaunchSmokeTests` | launch → sidebar smart-list rows present → grid fills → selecting Owned/Played re-scopes the grid |
| b | `SearchFlowTests` | ⌘F focuses search; typing filters; ↓ into grid + ↩ opens inspector; esc clears then unfocuses; **typing S/A/B in search does NOT re-tier** |
| c | `GridKeyTests` | select a game + `A` → tier chip shows A; `P` toggles played; multi-select + tier; `⌘Z` undo |
| d | `QuickAddFlowTests` | ⌘N opens the floating panel focused; offline hint shown (sample mode); flag/format shortcuts change visible state; "Create '…' manually" + ↩ stays open, cleared + focused; esc closes; new game appears in the grid |
| e | `DuelFlowTests` | open Duel; ←/→ answer, progress advances, ⌘Z undo, ↓ skip; **arrows don't change the sidebar/grid selection behind it** |
| f | `TriageFlowTests` | switch to Triage; tier letters advance the queue; ← goes back |
| g | Tier Board + The Top | rows/tiles exist; ⌥→ nudges order; ⌘E presents the save panel then cancel; one simple drag (XCTSkip if flaky) |
| h | inspector edits | played toggle; status; playtime accepts `45h` and formats it; invalid input shows validation |
| i | filter chips | apply Tier + Status → chips appear → remove one by keyboard → grid updates → Clear all |
| j | Play Next | open; brackets via 1–4 change hero or show an explanatory empty state; `R` re-rolls; Ask Claude button exists (**never triggered** — it spends the owner's usage) |
| k | Scan | ⇧⌘O opens the scan sheet; input state + usage notice shown; close it (**no scan started**) |
| l | Settings | open Settings; three tabs exist; Photo Scan tab shows the detected `claude` path / Check button |

These 12 classes (a–l) are all committed under `VGNUITests/`. Each is independent
and launches its own sample-data app. They compile and the bundle loads/executes;
their assertions are gated on the window becoming snapshot-able (see Run status).

## Known skips / caveats

- **Drag & drop** under XCUITest + SwiftUI is flaky (no insertion location in
  `dropDestination`'s `isTargeted`). The Tier Board / The Top flow attempts **one**
  simple drag; if unreliable it is marked `XCTSkip` with a note rather than
  committed flaky. Drag *feel* stays on the owner's checklist (`docs/ACCEPTANCE.md`).
- **Ask Claude** (Play Next) and **starting a photo scan** are never triggered by a
  test — both spend the owner's Claude subscription usage. The flows assert the
  controls *exist* and stop there. Settings ▸ Photo Scan ▸ **Check** is safe to
  press: it only runs `claude --version` (and `command -v claude`), verified in
  `ClaudeShellProbe.version` — no `claude -p`, no cost. The tab also runs Check on
  appear, so the detected path/version populates without a click.
- **Continuity Camera** ("Take Photo") is untestable without the owner's iPhone.
- Sample mode is **offline**: Quick Add finds local/manual results only, so the
  offline hint is asserted rather than streamed IGDB rows.

## Bugs found → fixed / open

Each app-side fix is a separate commit `Fix: … (found by UI test …)`.

**Fixed**

- **No window at all under XCUITest — saved-state restoration** (wave 22 root cause of
  "Expected main window / grid to exist" in 9 classes, and of the old "only the first
  test gets a window" blocker). XCUITest launches the app *without* making it
  frontmost; AppKit then restores the persisted main window
  (`hasPersistentStateToRestore=1`), SwiftUI's `AppWindowsController` returns
  `window=0x0`, and because a restoration ran, SwiftUI opens no default `WindowGroup`
  window: menu bar, no window, no AX `Window`. Reproduced outside XCUITest with
  `open -g` (no window) vs `open -g … -ApplePersistenceIgnoreState YES` (window).
  Fix (test-side): `launchSample` passes `-ApplePersistenceIgnoreState YES`. The same
  thing can happen to a real background launch — see "Open" below.
- **Grid cell lost its state value once it had a tier chip** (found by
  `GridKeyTests`). `TierChip`'s `appKitTooltip` overlay is an `NSView`; inside the
  cell's `.accessibilityElement(children: .combine)` it turned the combined element
  into `AXUnknown` with **no** `AXValue`, so every tiered cell read nothing ("Tier A,
  Physical, Played" gone for XCUITest *and* VoiceOver). Fix: the tooltip overlay is
  `accessibilityHidden` and its `TooltipPassthroughView` is not an accessibility
  element (the text is still the view's hint; the AppKit tooltip is unchanged).
- **⌘F / View ▸ Find never focused the search field** (found by `SearchFlowTests`).
  `RootView` owned the `@FocusState` and passed it to the field hosted in the window
  toolbar; writing it never moved focus there — typed text went to the sidebar.
  Fix: `LibrarySearchField` owns its focus, takes `focusRequests` (the vm's ⌘F
  counter) and reports changes via `onFocusChange`; a click-through, AX-hidden
  `SearchFieldFocusAnchor` also makes the field's `NSTextField` first responder,
  which is what actually works in the toolbar. esc / clear behave as before.
- **Identifier on a plain container overrode its children's identifiers** (found by
  `ScanSheetTests`, `FilterChipsTests`). `.accessibilityIdentifier` on a non-element
  `Group`/stack is pushed down onto every child, so in the scan sheet the usage notice,
  Cancel, "Scan 0 Photos"… all read `scan.sheet`. Fix: `.accessibilityElement(children:
  .contain)` before the identifier on `PhotoScanView` and `FilterChipsBar`.
- **Sample mode could not show a Play Next pick** (found by `PlayNextTests`): no sample
  game had a time-to-beat, so every candidate fell in the unknown-length lane and the
  page showed its empty state. `SampleLibrarySeeder` now writes rough `igdb` times for
  the owned backlog (Disco Elysium, Silksong, MGS4) through `updateMetadata`.
- **UI-test bundle failed to load — code-signing / library validation** (found on
  the first real run). The `VGNUITests.xctest` bundle would not `dlopen` into the
  runner: *"code signature … not valid for use in process: mapping process and
  mapped file (non-platform) have different Team IDs."* The UI-test target inherited
  `ENABLE_HARDENED_RUNTIME = YES` from the project config, and hardened runtime's
  library validation rejects the ad-hoc-signed (`CODE_SIGN_IDENTITY = "-"`, no team)
  bundle inside the runner. Fix: `ENABLE_HARDENED_RUNTIME = NO` on the `VGNUITests`
  target's Debug+Release configs (consistent with the app, which auto-relaxes it
  under ad-hoc signing). After this the bundle loads and tests execute.
- **Query timeout — `descendants(matching: .any)` subscript** (found on the first
  run that executed). Looking an element up with `app.descendants(matching: .any)[id]`
  makes XCUITest evaluate the whole accessibility tree to prove uniqueness, which on
  this app throws *"Failed to get matching snapshots: Timed out while evaluating UI
  query"* (~112 s). Fix: `VGNUITestCase.el(_:)` now uses
  `.matching(identifier:).firstMatch`, which short-circuits. (Test-harness fix, not
  an app bug.)
- **Scan sheet could not be closed from its input state** (found while writing
  flow k). `PhotoScanInputView`'s only Cancel was `Button("Cancel", role: .cancel) {}`
  — `.hidden()` and with an **empty action** — so before any photo was queued there
  was no working close control and `esc` did nothing (the sheet was a dead end).
  Fix: thread the sheet's `onClose` into `PhotoScanInputView` and show a real,
  tagged (`scan.close`) Cancel button that calls it; `esc` (`.cancelAction`) now
  dismisses. This is exactly the "missing default button / first-responder" class of
  risk in `LIMITATIONS.md` §0. Smallest change; no behavior change once a scan is
  running.
- **App-quiescence hang on the launch window** — the app pegged 100 % CPU and never
  went idle, so XCUITest could not snapshot any window. Root cause (fixed on `main`
  by the data lane, commit `84381e8`): `LibraryGridView`'s context-menu builder
  called `vm.selectOnly(...)` while SwiftUI built every cell's menu → endless
  invalidate/rebuild loop. Idle CPU is now 0 % on every destination and the window is
  snapshot-able. (This was the blocker in the previous hand-off.)
- **Quick Add sticky flags wrote to the owner's real `UserDefaults` in sample mode.**
  A UI run (or any `-VGNSampleData`/`-VGNSeedGames` launch) would flip the owner's
  real owned/played/format stickiness. Fix (`AppEnvironment`): inject
  `InMemoryQuickAddPreferences` in non-live modes so the flags stay in-memory there.
- **`scripts/uitests.sh` crashed on a full run** — under `set -u`, expanding the
  empty `ONLY_ARGS` array is an "unbound variable" error on macOS's bash 3.2, so a
  run with no `-only` aborted before testing. Fixed with the
  `"${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"}"` idiom.

**Observations / watch (not bugs)**

- `playnext.bracket(n)` identifiers were **not** added: the brackets are a single
  segmented `Picker`, so there are no per-bracket elements. The flow switches
  brackets with the `1`–`4` keys instead.

### Run status — 2026-09-25 (wave 22) — ALL GREEN, whole suite in one run

Owner away; run by the W22-B lane, one class at a time (`--per-class <Class>`, a `pgrep
-x VGN` check before each), then the whole suite once. Every launch used
`-VGNSampleData YES` (verified in the launched process's arguments).

**Why the 2026-09-25 02:23 orchestrator run failed everywhere:** every
"App UI hierarchy" dump in its `.xcresult`s shows only `MenuBar` + `TouchBar` under
the application — **no window at all** (Window menu: Minimize/Zoom/Bring All to Front
disabled). The app's unified log shows AppKit restoring saved state and SwiftUI's
restorer returning `window=0x0`, then no default window (see Fixed ▸ "No window at
all"). The three "PASS" classes had only skipped for the same reason.

| Class | 02:23 run (main `d17e6a6`) | After (wave 22) |
|---|---|---|
| DuelFlowTests (2) | "PASS" = 2 skips | **2 pass** |
| FilterChipsTests (1) | FAIL (no grid) | **pass** (menu item pick scoped to its pop-up) |
| GridKeyTests (3) | FAIL ×3 (no grid) | **3 pass** (⇧-keys; played game for tiers; cell value fix) |
| InspectorEditTests (3) | FAIL ×3 (no grid) | **3 pass** |
| LaunchSmokeTests (1) | FAIL (no window) | **pass** |
| PlayNextTests (1) | "PASS" = skip | **pass**, hero pick asserted (sample estimates) |
| QuickAddFlowTests (3) | FAIL ×3 (no grid) | **3 pass** (format = selected segment) |
| RankingViewsTests (3) | FAIL ×2 (no window) + skip | **2 pass + 1 intended skip** (drag) |
| ScanSheetTests (1) | FAIL (no grid) | **pass** (container identifier fix) |
| SearchFlowTests (3) | FAIL ×3 (no grid) | **3 pass** (⌘F focus fix; polled narrowing) |
| SettingsTests (1) | FAIL (no grid) | **pass** (tab "IGDB", matched by title) |
| TriageFlowTests (1) | "PASS" = skip | **pass** (opens Triage after the seed; empty = fail) |

Whole suite, one `xcodebuild` (`scripts/uitests.sh`): **23 tests, 22 pass, 1 intended
skip, 0 failures, ≈ 3 min.** The "later tests stay behind the runner" limitation is gone.

**Test-side updates for waves 7–22** (stale expectations, not app bugs): grid action
keys are ⇧-letters; only played games take a tier (Broken Sword instead of the unplayed
Disco Elysium); Quick Add's format is a 3-segment control; the Settings account tab is
"IGDB"; The Top's save panel has a Touch Bar "Cancel" mirror (query scoped to the
`save-panel` dialog); the search narrows asynchronously (poll); the filter menu's first
item must be read from the pop-up, not `app.menuItems` (menu bar first → 45 s stall).

**Closed in wave 23 (W23-A)** — the three app bugs below are fixed (see
`docs/LIMITATIONS.md` §2 for the how); a new `LaunchSmokeTests` case,
`testLaunchWithSavedStateStillShowsWindow`, launches twice WITHOUT
`-ApplePersistenceIgnoreState` (the first run leaves saved state) and expects exactly
one main window. **UI suite not run in wave 23:** the owner's own VGN build (launched
from Xcode) was running the whole session, and `XCUIApplication.launch()` terminates a
running instance of the same bundle id — so the per-class run was skipped, not failed.
Run `scripts/uitests.sh --per-class` once that app is quit.

**2026-09-26 00:10 per-class run (orchestrator, main `6da5f92`): 11/12 PASS**; only
`LaunchSmokeTests.testLaunchWithSavedStateStillShowsWindow` failed — no window at its
FIRST launch (stale saved state from an older build). Cause: the W23-A guard opened
windows through an `openWindow` captured in `Commands`, which SwiftUI never evaluates
while no window exists (guard log: `opener=false`). W23-B switched it to SwiftUI's
delegate `applicationOpenUntitledFile(_:)` and gave the WindowGroup a stable id (see
`docs/LIMITATIONS.md` §2); hand-verified with `open -g`. The W23-B re-run of
`--per-class LaunchSmokeTests` at 00:21 could not execute: **the login session was
locked** (`CGSSessionScreenIsLocked = 1`), so XCUITest failed both tests with "Failed to
activate application … (current state: Running Background)" — environmental, the
previously green `testLaunchShowsSidebarSmartListsAndGrid` failed identically. Re-run
`scripts/uitests.sh --per-class` with the session unlocked.

**Were open (app, written up in wave 22 — fixed in wave 23):**
- *Background launch shows no window.* Steps: quit VGN with its window open; launch it
  without activating (`open -g "Video Game Nerd.app"`, a login item, a script). Expected:
  the library window. Actual: menu bar only, no window (restoration yields nil; SwiftUI
  skips the default window). Clicking the Dock icon/reopen brings one. Low impact for a
  normal Finder/Dock launch (that one activates and gets a window).
- *Play Next hides the unknown-length lane behind "Nothing to play here yet".* Steps: a
  library whose owned backlog has no time-to-beat (sample mode before this wave, a fresh
  import before enrichment). Expected: the unknown-length games listed. Actual:
  `PlayNextResult.isEmpty` ignores `unknownLength`, so the page says "There are no owned,
  unfinished games" although there are.
- *Triage snapshots its queue on appear* and does not refresh while shown (a game marked
  played elsewhere, or data landing just after, appears only when Triage is re-opened).

### Run status — 2026-09-20 (wave 18, `--per-class` attempt) — BLOCKED at init (superseded)

`--per-class` was attempted (owner away, authorised window). It **could not be
evaluated** — the runner never reached any flow. `build-for-testing VGN-UITests`
succeeded (the target compiles after the wave 14–18 merge), but every
`test-without-building` invocation **failed to initialize for UI testing**, twice in a
row on the first class:

```
Failed to initialize for UI testing: Error Domain=com.apple.LocalAuthentication Code=-4
"System authentication is running." … Authentication cancelled. BiometryType=1
… The test runner failed to initialize for UI testing.
```

This is an **environment/authorisation state on the login session**, not a test or app
bug: a system authentication dialog (`BiometryType=1` = Touch ID) is active and cancels
the UI-testing harness before it starts. The likely trigger is a **Keychain / Touch ID
prompt left on screen by the ad-hoc-signed app rebuilds** (the signing note in
`docs/LIMITATIONS.md` §1 warns macOS may re-ask for Keychain access after rebuilds), or a
missing/again-required Accessibility/Automation grant. It can only be cleared by the owner
at the machine (dismiss the auth dialog / re-grant the runner in **System Settings ▸
Privacy & Security ▸ Accessibility** and **▸ Automation**), then re-run
`scripts/uitests.sh --per-class`. The run was **stopped after two identical init failures**
rather than hammering all 12 classes to the same wall; no flow executed, **no keyboard/mouse
was hijacked** (it failed before that), and **no `VGN` process was left running**. So this
run neither confirms nor refutes whether `--per-class` dodges the frontmost-window blocker
below — that remains untested. **Not run: all 12 classes** (Duel, FilterChips, GridKey,
InspectorEdit, LaunchSmoke, PlayNext, QuickAddFlow, RankingViews, ScanSheet, SearchFlow,
Settings, TriageFlow).

### Run status — 2026-09-19 (full run ≈ 5m 20s, 23 tests) (superseded — see 2026-09-25)

The suite builds, signs, loads and **executes** against the real app (Accessibility/
Automation are granted here — the runner drives the session). The quiescence blocker
from the previous hand-off is fixed, so windows are now snapshot-able. The one flow
that runs as the **first** test in the process passes end-to-end; every later flow is
blocked by a macOS foreground limitation (below).

| Flow | Result | Note |
|---|---|---|
| e Duel (`DuelFlowTests`) | **pass** (as first test) | Answers, `⌘Z` undo, progress, and the no-arrow-leak guard all assert green when it runs first. |
| a Launch, b Search, c Grid keys, d Quick Add, f Triage, g Tier Board/The Top, h Inspector, i Filter chips, j Play Next, k Scan, l Settings | **blocked** | Fail/skip only because their window isn't queryable (see below), not because of the flow logic. |
| g Tier Board drag (`testTierBoardDragIsSkipped`) | **skip** (intended) | SwiftUI drag-and-drop is flaky under XCUITest; stays on the owner's manual checklist. |

**The remaining blocker — macOS "only the first test's app is frontmost".**
`XCUIApplication.launch()` reliably foregrounds the app — and so puts its window in
XCUITest's frontmost-app query snapshot — only for the **first** test in the run's
process. Every later test's app renders correctly (proven: the a11y debug dumps show
the full window with `grid`, `grid.cell.<id>`, `sidebar.row.*`, `toolbar.search`, the
correct counts) but stays **behind the test runner**, so `waitForExistence` returns
false for its `grid`/window even though the element is in the tree. `DuelFlowTests`
passes only because it is alphabetically first.

Remedies **tried and ruled out** (do not repeat blindly): `XCUIApplication.activate()`
after launch; explicitly terminating the prior VGN process before each launch; and the
app self-activating via `NSApp.activate()` / `NSApp.activate(ignoringOtherApps: true)`
in both `VGNApp.init` and `RootView.onAppear`. None foregrounded a later test's window
— and the app-side activation actually **broke the first test too** (Duel dropped from
pass to skip), so it was reverted. `-VGNDisableAnimations` is not enough either.

**What to try next** (each costs one hijacking run — batch them): (1) run each test
**class in its own `xcodebuild` invocation** so every class is "first" — now wired as
`scripts/uitests.sh --per-class` (with `--per-test` as the finer-grained fallback and
`--list` to preview). Prepared and syntax/`--list`/`build-for-testing`-verified, **not
yet executed** (needs the owner away from the Mac, ~10–20 min of input takeover);
promising since the first test always foregrounds, but unverified for multi-method
classes — if per-class still foregrounds only one window per invocation, use
`--per-test`; (2) investigate why the **Duel destination's**
window is frontmost-queryable while the library window (a `NavigationSplitView` whose
sidebar `List` holds keyboard focus) is not — possibly making the detail pane take key
focus on appear; (3) an Xcode/OS-level focus workaround for macOS 26 UI tests. Until
one of these lands, the identifiers, launch hooks, deep-links, screenshots (with an
window-only-or-nothing) and query approach are all proven correct by the Duel flow — the
suite is complete and will pass once a later test's window can be brought frontmost.

If a *future* run is instead blocked by permissions, it fails early with an
authorization error and no flow executes — grant the runner (`xcodebuild`/Xcode)
control of the computer in **System Settings ▸ Privacy & Security ▸ Accessibility**
(and **▸ Automation**), then re-run `scripts/uitests.sh`.

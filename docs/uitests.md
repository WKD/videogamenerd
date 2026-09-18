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
# Whole suite, with screenshots exported to .build/uitests/<timestamp>/index.html
scripts/uitests.sh

# One class or one test
scripts/uitests.sh -only VGNUITests/DuelFlowTests
scripts/uitests.sh -only VGNUITests/SearchFlowTests/testSearchFocusFilterAndClear
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

Screenshots are always `app.windows.firstMatch.screenshot()` (the VGN window only),
**never** `XCUIScreen.main.screenshot()` — the owner's other windows are never
captured. This is enforced by convention in `VGNUITestCase.attachWindowScreenshot`.

## The project wiring (for future agents — do not break)

The suite is a hand-written addition to the `objectVersion 77` project
(`VGN.xcodeproj/project.pbxproj`), which uses `PBXFileSystemSynchronizedRootGroup`
(no per-file references — dropping a `.swift` under `VGNUITests/` compiles it
automatically). What was added, all in the `AA00…00NN` id namespace:

- target `VGNUITests` (id `…12`), product type
  `com.apple.product-type.bundle.ui-testing`, build setting `TEST_TARGET_NAME = VGN`
  (no `TEST_HOST`/`BUNDLE_LOADER` — a UI-testing bundle does not host the app),
  bundle id `com.wkd.VGNUITests`, Swift 6, macOS 15, ad-hoc signing (`CODE_SIGN_IDENTITY = "-"` inherited).
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

**Observations / watch (not bugs)**

- Quick Add's sticky flags (owned / played / format) persist to the app's
  `UserDefaults` **even in sample mode**, so a UI run nudges the owner's real Quick
  Add stickiness. `QuickAddFlowTests` restores them at the end of the flag test, but
  a mid-test failure would leave them flipped. Harmless (three toggles) but noted.
- `playnext.bracket(n)` identifiers were **not** added: the brackets are a single
  segmented `Picker`, so there are no per-bracket elements. The flow switches
  brackets with the `1`–`4` keys instead.

### Run status (as of hand-off)

The suite was actually run (Accessibility/Automation were **not** blocked here —
the runner drove the session). What the runs established:

- **Infrastructure works end-to-end**: the `VGN-UITests` scheme builds, the runner
  and `.xctest` sign and launch, the bundle loads, and a test **executes** against
  the real app (after the hardened-runtime fix above). This is the hard part and it
  is done.
- **Open blocker — app never reaches XCUITest "idle" on the launch window.** Every
  query (even `app.windows.firstMatch`) fails with *"Failed to get matching
  snapshots: Timed out while evaluating UI query"* after ~110 s: the window
  **exists** (a non-retrying existence check finds it immediately) but XCUITest
  cannot capture a *stable* snapshot because the app is never quiescent in
  `-VGNSampleData` mode. There is **no** spinner or repeating animation on the launch
  screen (checked), so the churn is subtler — most likely continuous SwiftUI
  re-rendering from the `@Observable` store's observation streams, a known
  SwiftUI-on-macOS + XCUITest pain point. `-VGNDisableAnimations` (implicit-animation
  suppression) was not enough.

**What the next owner-away session should try** (each needs one hijacking run, so
batch them): (1) confirm whether a data-source observation is re-emitting in a loop
in sample mode (log emissions in `GRDBLibraryDataSource`); (2) if so, quiet it (it
would be a real app bug); (3) otherwise, a test-harness workaround — assert on a
specific identified element with a longer per-query patience instead of the whole
window, and/or gate the `@Observable` churn behind the existing
`-VGNDisableAnimations` flag. Until the window becomes snapshot-able, the assertions
in flows (a)–(l) cannot run even though the identifiers and flows are all in place.

If a *future* run is instead blocked by permissions, it fails early with an
authorization error and no flow executes — grant the runner (`xcodebuild`/Xcode)
control of the computer in **System Settings ▸ Privacy & Security ▸ Accessibility**
(and **▸ Automation**), then re-run `scripts/uitests.sh`.

# VGN — Limitations, decisions and postponed work

What is knowingly imperfect, deferred or unverified. Rewritten 2026-09-19 after the owner's review of every open item. Companions: `docs/ACCEPTANCE.md` (manual checks only the owner can do), `docs/recognition-accuracy.md`, `docs/snapshots.md`, `docs/uitests.md`.

Legend: **[doing]** being built now · **[later]** deliberately postponed · **[watch]** fine today, could bite later · **[owner]** needs the owner.

---

## 1. Owner decisions (2026-09-19)

| Topic | Decision |
|---|---|
| Quick Add tier keys | Keep `⌃S … ⌃F` (`⌃0` clears). |
| Bulk "Mark Owned" | **Ask once for the batch**: one sheet (format for all; platform = each game's primary one, ambiguous games listed and fixable), one transaction (`LibraryStore.addCopies`). Replaces the silent "physical on primary platform". Bulk **un-own** will not be built (owner decision 2026-09-19): a multi-selection ⇧O-off shows a banner ("un-own one game at a time") rather than half-removing copies. **[done]** |
| Grid: letters vs type-to-select | **Tier / owned / played keys need ⇧** in the library grid (`⇧S…⇧F`, `⇧O`, `⇧P`); plain letters always type-to-select. `0` still clears the tier. Tier Board, Triage and Quick Add keep their own keys. Deterministic rule in the pure `GridKeyRouter`; Caps Lock is not ⇧. **[done]** |
| Play Next snooze | Keep the fixed 21 days. |
| UI smoke suite | Prepare a `--per-class` runner (one `xcodebuild` run per test class) but **only execute it when the owner says they are away from the Mac** (10–20 min of keyboard/mouse takeover). **Script ready, never run**: `scripts/uitests.sh --per-class` (12 classes; `--list` previews; `--per-test` is the fallback). |
| Signing | Stay "Sign to Run Locally" (ad-hoc) for now. Consequence: macOS may re-ask for Keychain access after rebuilds; hardened runtime effectively relaxed. |
| Photo-scan tile size | **Measured 2026-09-19, no change.** IMG_3683 with 1100 × 2400 px tiles (rows kept whole; 16 calls instead of 8): recall 57/59 (97 %), precision 100 % — the same recall as the shipping 1850 × 2400 tiles for twice the calls, time (141 s) and notional cost ($6.76). The two misses (*The Last of Us Part I*, *Final Fantasy XIII-2*) are hard spines, not a resolution problem. Tiles under ~1 570 px high would cut each shelf row — and its spine titles — in two (20–24 calls); not tried. Re-run any geometry with `VGN_SCAN_TILE=WxH[xOverlap] scripts/scan-accuracy.sh IMG_3683` (`VGN_SCAN_DRYRUN=1` counts tiles for free). |
| Data folder | Stays `~/Library/Application Support/VGN/` although the app is now "Video Game Nerd" (`com.pomatelier.VideoGameNerd`). |
| Build now | "Choose cover…" sheet · Undo for Play Next "Start playing" · Library stats view · cleanup batch · insertion line for The Top's reorder drag. **[doing]** |
| Next milestone | **GOG import (M8)** — to be planned with the same cache-first / stop-and-ask posture as PSN (PLAN §13) before any live request. PSN (M7) and Polish (M9) after. |

## 2. The big caveat: the GUI has barely been driven

Agents cannot operate windows. Screens were built from model-level tests, SwiftUI previews and launch checks. Since the hardening pass there are two partial remedies:
- **Snapshots** (`scripts/snapshots.sh --generate` → `.build/snapshots/index.html`): ~120 screens, light + dark, off-screen. Opt-in (rendering in parallel with the unit tests made a debounce test flake). Cannot render window toolbars, the Quick Add floating panel, menus, sheet/popover chrome, live covers, motion. One reference (`playnext-small-library@light`) is timing-dependent. Reference comparison is not bit-stable run to run on this machine (anti-aliasing), so re-recording is done per affected screen.
- **UI smoke suite** (`VGNUITests`, scheme `VGN-UITests`, `scripts/uitests.sh`): builds, loads, runs; `DuelFlowTests` **passes end to end**. The other 11 flows are blocked: on this macOS only the *first* test of a run gets a frontmost-queryable window (later windows render but stay behind the runner). Ruled out: `XCUIApplication.activate()`, terminating the previous app, app-side `NSApp.activate`. Next: per-class runs (see §1). The UI-test target needs `ENABLE_HARDENED_RUNTIME = NO`.

Still human-only: drag feel (Tier Board, divider drag's fixed 44 pt per game), animation, Continuity Camera (needs the owner's iPhone), grid scrolling with real covers, and everything in `docs/ACCEPTANCE.md`. Highest-risk interaction: Quick Add's floating panel owning the keyboard on macOS 15.

## 3. Found and fixed by the hardening pass (kept as lessons)

- **100 % CPU while idle** — the grid's context-menu builder wrote the selection during view updates (present since the first shell; no test could see it). Rule: nothing reachable from a `body` / `@ViewBuilder` / menu builder may write observable state; launch checks assert idle CPU ≈ 0 %.
- **Covers could be lost for good** — the 7-day "no cover" marker was timed with uptime (resets at reboot), and a network blip was cached as a genuine miss.
- **Stale stream emissions overwrote fresh ranking boards** (a tile could snap back; showed up as a flaky test). Tier Board and The Top now re-read on emission.
- **IGDB bundle members** — a game's `bundles` field lists its *parents*, not its members ("God of War Collection" got "God of War Trilogy" as its only member). Members now come from the reverse lookup; nested bundles expand; DLC/packs are dropped. The owner's library was repaired on 2026-09-19 (backup `vgn-pre-bundle-fix-…`).
- Matching: empty-normalised titles matched at 100 %; budget labels ("Pokémon Platinum") were over-stripped. Photo-scan sheet could not be dismissed from its first screen. Quick Add wrote sticky flags to real preferences in sample mode. **Unit tests read the owner's real preferences** (they run inside the app) — now isolated via `AppPreferences.defaults`.
- **Privacy incidents (2):** one full-screen screenshot by the orchestrator on day one, and a UI-test screenshot *fallback* (`app.screenshot()` captures the whole desktop on macOS) that showed other apps' windows. Both deleted, never committed; the second was read by an agent (processed by the model) and may persist in that agent's local transcript in the temp folder. Rules: never full-screen captures; UI tests screenshot `app.windows.firstMatch` or nothing.

## 4. Open items

### Library, Quick Add, search
- IGDB `search` misses mid-word prefixes and alt-name-only titles; the name-prefix / alternative-name fallback and the **typed-year filter** ("super mario bros 1985") cover the known cases; odd titles may still need "Create '…' manually". [watch]
- Enrichment never overwrites non-empty fields (plus the `user_edited` marker): a wrong-but-non-empty IGDB value is only replaced by "Refresh metadata". Manual entries (no IGDB id) get no metadata/time-to-beat, and a cover job only on platforms with a libretro repo.
- Placeholder covers print a large platform label that the badges can overlap; redundant now that platform pills sit under the title. [later, cosmetic]
- Compilation members keep IGDB's order (e.g. Mass Effect 2 · 1 · 3); reorder in the editor. [later: sort by release date on creation]
- Grid query ≈ 33 ms at 2 000 games (DEBUG), one full re-query per emission, no paging. [watch]

### Ranking
- The Top: no insertion line while hovering during a reorder drag. **[doing]** Reorder and divider drag are disabled while a filter is active (by design).
- Divider drag maps a fixed 44 pt to one game. [owner: judge the feel]
- Derived-score bands are constants for six tiers; any other tier count falls back to equal bands. Border duels are logged as `refine`; accepting a border suggestion moves the game to the new tier *unplaced*. Undo: per answer inside a placement + one step for the last completed action (history 50). Triage "back" clears the tier directly; a `U` un-play is not restored by "back".
- Perf at 2 000 ranked games (DEBUG): tier board 43 ms, The Top ~50 ms, duel answer 7 ms. [watch]

### Play Next
- A shortlist-ranker by design: < 15 ranked games ⇒ "not enough data", match strength always weak; weights and the backtest threshold (ρ ≥ 0.45 = good) are **not yet tuned on the real library**. [owner: revisit once ~25 games are ranked]
- "Start playing" has no Undo. **[doing]**
- IGDB traits are uneven (*Bloodborne* has no franchise/series; keywords capped at 12). "Ask Claude": ~10–20 s, non-deterministic, first call in an hour ≈ $0.70 notional (the CLI caches its own system prompt), sends only the tier list + shortlist.

### Photo scan
- Measured on one shelf, one lighting: recall 97–98 %, precision 92–100 %, IGDB pre-match 96–97 %. 1–2-character spine fragments still land in *No match* (unchecked); complete titles sharing a prefix are never merged (deliberate). ≈ 8 `claude -p` calls, 1–2 min and ≈ $4 notional per photo on the owner's default model (`claude-fable-5-1`); the model is configurable in Settings ▸ Photo Scan; a cheaper model has not been evaluated (owner: not now).
- Vision OCR fallback is rough; serial codes only boost platform/region (no serial→title database).

### Covers & matching
- Cover downloads are not cancelled when a cell scrolls away; thumbnail decoding runs on the `CoverStore` actor. [watch — owner chose not to fix until scrolling actually stutters]
- "Choose cover…" sheet (browse every candidate) — **built (wave 7, lane B).** Inspector button next to the cover actions; grid of candidates grouped by provider (provider · region · size), current cover shown, "Use This Cover" / double-click / "Choose File…". Notes:
  - **IGDB contributes only the game's cover** — `artworks` are not modelled anywhere in the app, so they can't be enumerated. If wanted, model `game.artworks` (image ids) during enrichment and add them in `IGDBCoverProvider.allCandidates`. **[later]**
  - **libretro browsing shows the best-matching title's regions/discs/revisions only** (the top fuzzy-score cluster), not near-but-different titles like numbered sequels. Capped at 60 tiles.
  - **Candidate listing is live-mode only.** Sample mode (`-VGNSampleData`) must not touch the network, so the sheet lists no remote candidates there — the local "Choose File…" path still works. [watch]
  - **Entry point is the inspector only.** A grid context-menu entry was out of reach this wave (another lane owns `LibraryGridView.swift`); add "Choose Cover…" there in a wave that owns the grid. **[later]**
- Catalogue-cache title search is a linear scan per keystroke and the cache is never pruned. [later — owner chose not now]
- Libretro hit rate on a real retro library is unmeasured (9 of 10 covers came from IGDB in the smoke test, as expected for modern platforms). Fuzzy thresholds 0.90 / 0.74 were hand-tuned, then held up in the live scan.

### Safety
- Export (JSON/CSV) and Restore from Backup… are in the File menu; the restore glue (`PendingRestore`, applied at next launch after a safety snapshot) is unit-tested since 2026-09-19 (no bug found). [owner: still try a restore once before relying on it]

## 5. Out of scope for now [later]
PSN import (M7, fully planned in PLAN §13) · Polish M9 (Liquid Glass touches, Dark/Tinted icon via Icon Composer — masters in `design/app-icon/`, Top export as image, richer empty states) · HowLongToBeat scraping (the "Open on HowLongToBeat" link exists) · TheGamesDB covers · `ClaudeAPIRecognizer` · editable tier labels/colours (owner: not now) · adjustable snooze.

## 6. Owner to glance at [owner]
- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**.
- Tier palette and derived-score bands (`VGN/Ranking/DerivedScore.swift`) — constants.

## 7. Engineering notes
- `claude -p` runs with an allow-listed environment (no `ANTHROPIC_*` can reach it, never `--bare`) → the owner's subscription; `total_cost_usd` is notional.
- The Xcode project was hand-written, then normalised by Xcode on 2026-09-19 (ids reordered, a "Recovered References" group) — harmless. Never add source files to it by hand; Swift basenames and type names must be unique across the target; bundle resources are flattened.
- Tests: hosted in the app (XCTest-host guard builds nothing), `@MainActor` + GRDB ⇒ serialized suite, async tests need hard timeouts, `UndoManager.undo()` hangs headless, preferences are isolated. Never launch a dev build against the real library except at the owner's request; use `-VGNSampleData YES` / `-VGNSeedGames n`.
- The live accuracy harness finds `samples/` from `main/` or a worktree; subset runs write to `.build/scan-accuracy/` and no longer touch the committed report.
- Subagents run on the `opus` alias (not pinned to a version). Two harmless build notes remain (AppIntents metadata; "Disabling hardened runtime with ad-hoc codesigning").

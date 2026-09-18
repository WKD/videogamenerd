# VGN — Limitations, shortcuts and postponed work

Everything that is knowingly imperfect, deferred, or unverified, collected from the agents' hand-off reports and the orchestrator's integration notes. Snapshot: 2026-09-18, `main` at the `m1`/`m2`/`m4` tags (537 tests). Companion files: `docs/ACCEPTANCE.md` (what only the owner can verify by hand) and `docs/recognition-accuracy.md` (photo-scan numbers).

Legend: **[decide]** needs an owner decision · **[follow-up]** small, scheduled or easy · **[later]** out of scope for milestones 0–6 · **[watch]** fine today, could bite later.

---

## 0. The big caveat: nobody has driven the GUI

Agents cannot operate the app's windows. Every screen was built from model-level tests (537 of them), SwiftUI previews that compile, and "process stays alive, console clean" launch checks in sample-data mode. **Layout, focus/keyboard routing, drag feel, animation, and anything visual are unverified.** The per-milestone checklists in `docs/ACCEPTANCE.md` are the real acceptance tests. **Mitigation decided 2026-09-18 (hardening pass):** off-screen snapshot rendering of every screen inside the unit tests (agents get eyes on layout) and an on-demand XCUITest smoke suite with window-only screenshots (keyboard/focus flows); drag feel, animation and taste remain human-only. Highest-risk items, in order:
1. Quick Add's floating `NSPanel` owning the keyboard on macOS 15 (Tab/arrows/⌘-combos while the text field keeps focus).
2. Duel/Triage key focus — keys must not leak into the search field or re-tier the grid selection behind it.
3. Tier Board drag & drop (insertion position, multi-select drags) and the divider drag in The Top.
4. Grid scroll smoothness with real covers (only measured as query time + cell-diffing assertions, never as frames).

## 1. Still to build inside milestones 0–6

- **M3 Compilations UI** — the data layer is complete (products with n games, all-or-nothing ownership, Quick Add adds IGDB bundles as compilations), but there is **no compilation editor** (add/remove/reorder members, rename), and the copy-removal warning shows the compilation title + game count, **not the list of member titles** PLAN §8 asks for (`GameDetail.Copy` doesn't carry sibling titles). [follow-up]
- **M5 Playtime polish** — manual playtime field, status picker and a minimal me-vs-average bar exist; sort/filter by playtime exists; the polished bar, the stats touches and **the inspector's derived-score line ("9.6 · #4 overall")** are not done (helper `RankingStore.derivedScore(for:)` is merged). [follow-up]
- **M5b Play Next view + "Ask Claude"** — engine, store, schema and CLI runner merged; the view is being built (`w5/b-playnext-ui`). Sidebar entry currently shows a placeholder.
- **M6 Photo-scan UI** — engine merged and measured; review sheet, photo input, Settings tab being built (`w5/a-scan-ui`). Until it lands there is no way to scan from the app.
- **Final hardening pass** — whole-app review, concurrency audit, real-cover perf check, CLAUDE.md refresh. Not started.
- Milestone tags: `m0 m1 m2 m4` pushed (m4 before m3 because ranking finished first). `m3`, `m5`, `m5b`, `m6` pending.

## 2. Out of scope for this run (PLAN milestones 7–9 and optional items) [later]

- **PSN import** (M7), **GOG import** (M8) — only the `import_titles` staging table exists.
- **Polish** (M9): Liquid Glass touches under `#available(macOS 26)`, stats view, Top export as image, app icon **Dark/Tinted appearances** (the "Console Grey" icon shipped 2026-09-19 as a single-appearance `AppIcon` set; SVG masters incl. dark and tinted variants are in `design/app-icon/`; the macOS 26 layered `.icon` file via Icon Composer is still to do), richer empty states.
- **HowLongToBeat provider** — skipped by decision; only the "open on HLTB" idea remains, and even that link is not in the inspector yet.
- **TheGamesDB cover provider** — not built (PLAN marks it optional).
- **"Choose cover…" sheet** — `CoverStore` returns every candidate from every provider, but there is no UI to browse them; today you get the first good hit or drop your own image.
- **`ClaudeAPIRecognizer`** (API-key variant of photo scan) — protocol seam exists, not built.
- **Editable tier labels/colours** — tiers are data (seeded S–F) but there is no editing UI.
- **Library export (JSON/CSV)** from PLAN §9 "Safety" — not built. Only The Top exports CSV. Launch snapshots (last 10) are the only backup.
- **Signing**: "Sign to Run Locally" (ad-hoc). Consequence: macOS may re-prompt for Keychain access after each rebuild, and the hardened runtime is effectively relaxed. Switch to an Apple Development team id when convenient. [decide]

## 3. Library, Quick Add, search

- **Quick Add tier keys are `⌃S … ⌃F`, not bare letters** (PLAN §6.1 said "S A B C D") — letters are text input in a search field. [decide if you dislike it]
- **Adding a bundle is `↩` on the bundle row** (adds as compilation; falls back to a single game with a note if IGDB returns no members). IGDB's `bundles` field is empty in practice — members come from a reverse lookup, so coverage is whatever IGDB has.
- **IGDB `search` quirks**: returns nothing for mid-word prefixes and alt-name-only titles; a name-prefix + alternative-name fallback covers "bloodb" and "chevaliers de baphomet", verified live, but odd titles may still need "Create '…' manually".
- **Bulk "Mark Owned"** adds a *physical* copy on each game's *primary platform* without asking (the platform/format popover only appears for a single ambiguous game). [decide]
- **Type-to-select vs tier keys in the grid**: with a selection, S/A/B/C/D/F/O/P/0 act immediately; to type-to-select a title starting with one of those letters you must deselect first (or already be typing within ~1 s). [watch]
- **Manual cover edge case**: setting a custom cover *before* enrichment has fetched the IGDB image id writes a 7-day "no cover" sentinel, so "Remove custom cover" won't re-fetch until it expires. Normal order (enrich → override) is fine. [follow-up]
- **Enrichment never overwrites non-empty fields** (plus the `user_edited` marker) — so a wrong-but-non-empty IGDB value is only replaced by an explicit "Refresh metadata". Manual entries (no IGDB id) get no metadata/time-to-beat; they get a cover job only on platforms that have a libretro repo.
- **Grid query** ≈ 33 ms at 2 000 games in DEBUG (was ~45 ms); fine, but it is one full re-query per emission — no paging. [watch]
- **`ManualAddSheet` view is now unused** (Quick Add reuses its model inline). Dead code to remove in hardening. [follow-up]
- **Unsafe "un-play"**: marking a played-but-not-owned game as not played asks to delete it (invariant 1). Correct by design, but it is why Triage has no "not actually played" key (see §4).

## 4. Ranking

- **Triage has no `U` ("not actually played") key** — it would trigger the orphan/delete confirmation, which Triage must never show. Needs a safe un-play in the data layer. [follow-up]
- **Triage "back"** clears the tier directly instead of using the store's undo (multi-select `setTier` isn't in the duel undo history). Same visible result.
- **Disputes → "Settle" re-places the games in the cycle** — there is no "duel exactly this pair" API yet. [follow-up]
- **Multi-select drag on the Tier Board = N store calls = N undo steps** (no batch move in `RankingStore`). [follow-up]
- **The Top: no insertion line while hovering during a reorder drag** (SwiftUI `dropDestination` gives no location in `isTargeted`); the drop lands correctly. Reorder and divider drag are disabled while a filter is active (by design).
- **Divider drag maps a fixed 44 pt to one game** although rows have different heights — the maths is tested, the feel is not. [watch]
- **Drag payload UTType (`com.videogamenerd.ranking-item`) isn't declared in Info.plist** → benign console note during drags. [follow-up]
- **Derived scores**: bands S 9.0–10 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9 are constants for exactly six tiers; with any other tier count the engine falls back to *equal* bands across 1–10 (PLAN said "proportionally" without defining it). Scores are relative to tier membership, so moving a divider changes them — intended.
- **Border duels are logged with context `refine`** (the schema only knows `placement|refine`); accepting a border suggestion moves the game to the new tier **unplaced** (it then needs a placement duel) rather than guessing a slot.
- **Undo horizon**: per-answer inside the current placement + one step for the last completed action, history bounded to 50; dismissed border pairs remembered (last 32).
- **Perf at 2 000 ranked games (DEBUG)**: tier board 43 ms, The Top 53 ms (slightly over the 50 ms target; it builds full rows), duel answer 7 ms. CSV export fetches game detail per row for playtime. [watch]
- Sharp edge for future code: `PlacementSession.revalidated(against:)` drops the session's undo history — only call it when the tier actually changed.

## 5. Play Next (recommendations)

- **It is a shortlist-ranker, not a learner** — by design (PLAN §7b). Under ~15 ranked games the backtest says "not enough data" and match strength is always "weak"; "strong" needs ≥ 25 ranked games plus real evidence.
- **IGDB trait coverage is uneven**: e.g. *Bloodborne* has no franchise or series in IGDB; keywords are noisy (capped at 12 per game). Games without an IGDB match compete on time fit only ("no metadata").
- **Snooze is a fixed 21 days** (the feedback table has no "until" column). [follow-up if you want it adjustable]
- Genre/platform/decade affinities are synthesised at query time, not stored as traits.
- Weights and backtest thresholds (ρ ≥ 0.45 = "good") are reasoned constants, **not yet tuned on your real library** — that is what the backtest is for once you have rankings.
- **"Ask Claude"** is non-deterministic, takes ~10–20 s, needs the `claude` CLI logged in, and sends your tier list (top ~60 + D–F titles) and the shortlist — nothing else. On demand only.

## 6. Photo scan

- **Measured once** on your 5 photos: recall 98 %, precision 92 %, platform 94 %, IGDB pre-match 97 % (details and every miss/false positive in `docs/recognition-accuracy.md`). One shelf, one lighting — other shelves may differ.
- **17 false positives = spine fragments at tile edges** ("God of W…"); a prefix-aware merge is being added with the scan UI. 5 misses were faint spines the model declined to guess (intended: it must never invent a title; the two unlabelled spines are in the answer key's `skip` list).
- **Usage**: ≈ 8 `claude -p` calls and ~1–2 minutes per photo; the CLI priced the 5-photo run at $19.66 *notional* (≈ $4/photo on the default model) — it counts against your subscription's usage limits, it is not charged (see the note in §9). A cheaper model has **not** been evaluated — owner decision 2026-09-18: not for now (the model stays configurable in Settings ▸ Photo Scan). [later]
- One earlier full run (~$12–15 notional) was **wasted**: killed by a 600 s test timeout before results were saved. Fixed (per-photo incremental writes, timeouts disabled for the harness).
- Tiling was tuned toward fewer, larger tiles (~8/photo) to bound usage — a deviation from PLAN's "~1 500 px tiles"; the row detector is a brightness heuristic with a plain-grid fallback.
- The Vision OCR fallback is rough (spine text is rotated/stylised); serial-code extraction only *boosts* platform/region, there is no serial→title database.
- The accuracy harness is a gated test (inert unless `scripts/scan-accuracy.sh` arms it), never part of the normal run.

## 7. Title matching & covers

- **Title normaliser over-strips budget labels** at its loosest level ("Pokémon Platinum" → "pokemon"); exact matching protects precision. Gate behind a flag if it ever mis-merges. [watch]
- **Fuzzy thresholds** (0.90 confident / 0.74 plausible) were tuned on a hand-made table, then held up in the live scan — still worth re-checking on libretro cover matching with your real library.
- Libretro cover matching is fuzzy against No-Intro/Redump names with Europe → USA → World → Japan preference; in the 10-game live smoke test 9 of 10 covers came from IGDB, only 1 from libretro (modern platforms have no libretro art, so this is expected — but retro hit rate is unmeasured). [watch]
- LibretroIndex (DEBUG): indexing 10 k names ≈ 620 ms, 1 k lookups ≈ 950 ms — off the main thread.
- GitHub unauthenticated rate limit (60/h) applies to fetching libretro file listings; they are cached on disk for ~30 days.

## 8. Data the owner should glance at

- `VGN/Resources/platforms.json` — 61 platforms; **slugs are permanent database keys**, sidebar `group` assignments, anything missing. [decide before adding many games]
- `docs/shelf-truth-draft.json` — owner-reviewed; two unlabelled spines deliberately skipped.
- Tier palette (classic tier-list colours) and derived-score bands — constants, easy to change.

## 9. Engineering & process notes

- **Claude usage/billing**: photo scan and "Ask Claude" run `claude -p` with an **allowlisted environment** (HOME, PATH, LANG/LC_*, TMPDIR, USER, LOGNAME, SHELL, TERM) — no `ANTHROPIC_*` variable can reach the child, and `--bare` is never used, so it authenticates with Claude Code's own OAuth login (subscription). The CLI's `total_cost_usd` is a notional price, reported regardless of how you are billed.
- The Xcode project file is **hand-written** (objectVersion 77, synchronised folders). If Xcode re-saves it, ids get rewritten — harmless. Never add source files to it by hand.
- **Swift file basenames and type names must be unique across the target**, and bundle resources are flattened (fixture names must be unique) — both bit us once; rules are in `docs/EXECUTION.md`.
- **Test infrastructure quirks**: hosted unit tests need the XCTest-host guard (the app renders nothing and builds no services under tests); `@MainActor` tests touching GRDB must sit in a serialized suite; `UndoManager.undo()` hangs headless, so undo is asserted indirectly.
- A dev build was launched **once** against the real library (to verify `m0`); it created the empty database and the first backup. Everything since uses `-VGNSampleData YES` / `-VGNSeedGames n`. One full-screen screenshot was taken by mistake early on and deleted; full-screen captures are now forbidden in agent briefs.
- The wave table in `docs/EXECUTION.md` describes the original plan; actual sequencing diverged (lanes were re-sequenced whenever one freed up). Treat git history + this file as the record.
- Subagents run with the `opus` model alias — whichever Opus version the local configuration resolves, not pinned to 4.8.
- Two harmless build notes remain: the AppIntents metadata note at build time, and "Disabling hardened runtime with ad-hoc codesigning".

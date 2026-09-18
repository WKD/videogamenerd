# VGN — Video Game Nerd

Native macOS app to catalogue every game I've owned or played, and rank them
(tiers + one ultimate Top). Spec: **`PLAN.md`**. Process/rules for the parallel
build: **`docs/EXECUTION.md`** (binding; PLAN.md wins on *what*, EXECUTION on *how*).

## Build / test / run

Build and test with a scoped DerivedData so parallel worktree builds don't collide:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd build
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd test
```

Run the built app:

```sh
open .build/dd/Build/Products/Debug/VGN.app
```

Run a single test (Swift Testing) by name:

```sh
xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath .build/dd test -only-testing:VGNTests/SmokeTests/sqliteHasFTS5
```

`.build/` is git-ignored. `VGN` is the only shared scheme; it builds + tests from a
fresh clone.

## Toolchain

macOS 15 deployment, built against the macOS 26 SDK. Xcode 26.x / Swift 6.
Requires `xcode-select -s /Applications/Xcode.app`.

## Project conventions

- **Single app target `VGN`** + unit-test target `VGNTests` (hosted by the app,
  Swift Testing, `@testable import VGN`). Internal-by-default — no `public` tax.
- **Folder-synchronised groups** (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77).
  Any file created on disk under `VGN/` or `VGNTests/` is picked up automatically:
  `.swift` compiled, everything else (`.json`, `.plist`, `.jpg`, `.xcassets`) copied
  as a bundle resource. **Never edit `project.pbxproj` to add files** — just drop
  them in. Only edit the pbxproj for targets, build settings or package deps.
- **Layering by folder, enforced by discipline** (not separate modules):
  - `VGN/Model/` — plain `Sendable`/`Hashable`/`Identifiable` value types (contracts
    for the UI lane). Foundation only.
  - `VGN/Ranking/` and `VGN/Matching/` — **pure logic**: Foundation only, no
    GRDB / SwiftUI / AppKit imports; operate on plain values (`Int64` ids, keys).
  - `VGN/Database/` — GRDB, the schema and migrations (**one closure per version**,
    owned by the Database lane). All schema changes go through a new numbered
    migration there.
  - `VGN/Services/`, `VGN/UI/` — everything else.
- **Swift 6 language mode, strict concurrency.** UI state in `@MainActor @Observable`
  stores; all I/O in actors. Target zero warnings. Do **not** set
  `SWIFT_DEFAULT_ACTOR_ISOLATION` (code must stay nonisolated-by-default).
- **GRDB 7 is the only dependency** (SwiftPM, `upToNextMajor` from 7.0.0). No XcodeGen.
- **No network in tests** — stub with `URLProtocol` + recorded fixtures. Strip
  credentials/tokens from anything recorded.
- IDs: `Int64` row ids for games/products/tiers; platform id = slug `String`
  (`ps5`, `snes`, `pc`, `mac`). Fine-rank key aliased once as `RankKey` in
  `VGN/Model/RankKey.swift`.

## On-disk layout

```
~/Code/videogamenerd/          container (NOT a repo)
├── samples/                   original shelf photos — git-ignored, read-only
├── main/                      checkout of `main` — only the orchestrator writes here
└── worktrees/<name>/          one git worktree + branch per agent task
```

App support dir at runtime: `~/Library/Application Support/VGN/`
(`vgn.sqlite`, `covers/`, `thumbs/`, `backups/`). Tests use in-memory / temp-dir
DBs, never the real one.

## Signing

**Sign to Run Locally** for now: `CODE_SIGN_IDENTITY = "-"`, no team.
App Sandbox **off** (the photo scanner spawns the `claude` CLI; a sandboxed app
can't). Hardened runtime is on in settings but ad-hoc signing effectively relaxes
it locally — expect the "Disabling hardened runtime with ad-hoc codesigning" note.

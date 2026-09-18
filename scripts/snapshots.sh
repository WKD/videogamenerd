#!/usr/bin/env bash
# VGN off-screen snapshot rendering.
#
#   scripts/snapshots.sh              generate PNGs + contact sheet, and verify
#                                     against the committed references
#   scripts/snapshots.sh --record     (re)write the committed reference PNGs
#   scripts/snapshots.sh --generate   only generate (no verify, no record)
#
# PNGs land in .build/snapshots/ (git-ignored); open .build/snapshots/index.html
# for the light/dark contact sheet. References live in VGNTests/Snapshots/Reference.
#
# Verification is opt-in because sub-pixel text anti-aliasing is not bit-stable
# across machines/OS point releases; the normal `xcodebuild test` only generates
# (always green, no flakiness). Thresholds + what cannot render off-screen are in
# docs/snapshots.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="verify"
case "${1:-}" in
  --record)   MODE="record" ;;
  --generate) MODE="generate" ;;
  "" )        MODE="verify" ;;
  * ) echo "usage: scripts/snapshots.sh [--record|--generate]"; exit 2 ;;
esac

# A macOS unit-test host does not inherit this shell's environment, so the mode
# is signalled to the test process by a sentinel file under .build/ (removed on
# exit) that SnapshotHarness checks.
mkdir -p .build
rm -f .build/snapshot-record .build/snapshot-verify .build/snapshot-run
cleanup() { rm -f .build/snapshot-record .build/snapshot-verify .build/snapshot-run; }
trap cleanup EXIT

# Enable the snapshot suites (they are skipped in a plain `xcodebuild test`).
touch .build/snapshot-run

if [[ "$MODE" == "record" ]]; then
  touch .build/snapshot-record
  echo "Recording reference snapshots into VGNTests/Snapshots/Reference …"
elif [[ "$MODE" == "verify" ]]; then
  touch .build/snapshot-verify
  echo "Verifying snapshots against committed references …"
else
  echo "Generating snapshots (no verify) …"
fi

  xcodebuild -project VGN.xcodeproj -scheme VGN -destination 'platform=macOS' \
    -derivedDataPath .build/dd \
    test \
    -only-testing:VGNTests/SnapshotSmokeTests \
    -only-testing:VGNTests/LibrarySnapshotTests \
    -only-testing:VGNTests/InspectorSnapshotTests \
    -only-testing:VGNTests/QuickAddSnapshotTests \
    -only-testing:VGNTests/RankingSnapshotTests \
    -only-testing:VGNTests/PlayNextSnapshotTests \
    -only-testing:VGNTests/ScanSnapshotTests \
    -only-testing:VGNTests/MiscSnapshotTests

echo
echo "Done. Contact sheet: $ROOT/.build/snapshots/index.html"

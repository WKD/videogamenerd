#!/bin/sh
#
# scan-accuracy.sh — run the LIVE photo-scan accuracy harness and (re)write
# docs/recognition-accuracy.md.
#
# This spends real Claude subscription usage (one `claude -p` call per tile, ~8 tiles
# per full photo) and IGDB calls. It drives the real pipeline via the
# RecognitionAccuracyHarness test, which is inert during a normal `xcodebuild test`
# and only runs when this script drops a sentinel file under .build/.
#
# Usage:
#   scripts/scan-accuracy.sh                        # all 5 photos, default model
#   scripts/scan-accuracy.sh IMG_3686 IMG_3687      # a subset
#   VGN_SCAN_MODEL=opus scripts/scan-accuracy.sh IMG_3686
#   VGN_SCAN_CONCURRENT=2 scripts/scan-accuracy.sh
#   VGN_SCAN_TILE=1400x1500 scripts/scan-accuracy.sh IMG_3683   # experimental tile size
#                                     (WxH or WxHxOverlap; report goes to .build/scan-accuracy/)
#
# Requires: `claude` installed and logged in; IGDB creds in ~/.config/vgn/igdb.env;
# the original photos in ../samples (git-ignored).
set -e
WT="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL="$WT/.build/vgn-live-scan"
mkdir -p "$WT/.build"

# Build first (no sentinel present, so a stray build never runs the live harness).
echo "Building test bundle…"
xcodebuild -project "$WT/VGN.xcodeproj" -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath "$WT/.build/dd" build-for-testing 2>&1 | grep -E "error:|TEST BUILD (SUCCEEDED|FAILED)" || true

# Drop the sentinel only around the live test run, then remove it.
{
  if [ "$#" -gt 0 ]; then printf 'photos:%s\n' "$(echo "$@" | tr ' ' ',')"; fi
  if [ -n "$VGN_SCAN_MODEL" ]; then printf 'model:%s\n' "$VGN_SCAN_MODEL"; fi
  if [ -n "$VGN_SCAN_CONCURRENT" ]; then printf 'concurrent:%s\n' "$VGN_SCAN_CONCURRENT"; fi
  if [ -n "$VGN_SCAN_TILE" ]; then printf 'tile:%s\n' "$VGN_SCAN_TILE"; fi
  if [ -n "$VGN_SCAN_DRYRUN" ]; then printf 'dryrun:%s\n' "$VGN_SCAN_DRYRUN"; fi
} > "$SENTINEL"
trap 'rm -f "$SENTINEL"' EXIT INT TERM

echo "Running live accuracy harness (this spends Claude usage)…"
# Timeouts disabled: a full 5-photo run makes ~40+ live `claude` calls and exceeds
# xctest's default 600 s per-test limit. Each tile call is itself bounded
# (SIGTERM→SIGKILL) so the run can't hang, and the report is written incrementally.
xcodebuild -project "$WT/VGN.xcodeproj" -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath "$WT/.build/dd" -test-timeouts-enabled NO \
  test-without-building -only-testing:VGNTests/RecognitionAccuracyHarness 2>&1 | \
  grep -E "HARNESS:|error:|Test .* (passed|failed)|Issue" || true
echo "Done. See docs/recognition-accuracy.md"

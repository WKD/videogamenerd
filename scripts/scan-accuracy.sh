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
#
# Requires: `claude` installed and logged in; IGDB creds in ~/.config/vgn/igdb.env;
# the original photos in ../samples (git-ignored).
set -e
WT="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL="$WT/.build/vgn-live-scan"
mkdir -p "$WT/.build"
{
  if [ "$#" -gt 0 ]; then printf 'photos:%s\n' "$(echo "$@" | tr ' ' ',')"; fi
  if [ -n "$VGN_SCAN_MODEL" ]; then printf 'model:%s\n' "$VGN_SCAN_MODEL"; fi
  if [ -n "$VGN_SCAN_CONCURRENT" ]; then printf 'concurrent:%s\n' "$VGN_SCAN_CONCURRENT"; fi
} > "$SENTINEL"
trap 'rm -f "$SENTINEL"' EXIT INT TERM

echo "Running live accuracy harness (this spends Claude usage)…"
xcodebuild -project "$WT/VGN.xcodeproj" -scheme VGN -destination 'platform=macOS' \
  -derivedDataPath "$WT/.build/dd" \
  test -only-testing:VGNTests/RecognitionAccuracyHarness/run 2>&1 | \
  grep -E "Wrote |error:|Test .* (passed|failed)|Issue" || true
echo "Done. See docs/recognition-accuracy.md"

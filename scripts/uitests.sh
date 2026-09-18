#!/usr/bin/env bash
#
# Run VGN's on-demand XCUITest smoke suite and export its window-only
# screenshots to a timestamped folder with an index.html.
#
# WARNING: UI tests take over the keyboard and mouse of the *live* session and
# macOS shows a one-time permission prompt ("… would like to control this
# computer" / Accessibility / Automation) that only the owner can approve. Run
# this only when the owner is away from the Mac and don't touch it while it runs.
# See docs/uitests.md.
#
# Usage:
#   scripts/uitests.sh                       # run every flow
#   scripts/uitests.sh -only VGNUITests/DuelFlowTests
#   scripts/uitests.sh -only VGNUITests/DuelFlowTests/testDuelAnswerAdvancesProgressAndUndo
#
# Passes any -only <id> straight through to xcodebuild as -only-testing:<id>.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/VGN.xcodeproj"
SCHEME="VGN-UITests"
DERIVED="$ROOT/.build/uitests-dd"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$ROOT/.build/uitests/$STAMP"
RESULT="$OUTDIR/result.xcresult"

mkdir -p "$OUTDIR"

ONLY_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -only) ONLY_ARGS+=("-only-testing:$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Compile first, WITHOUT taking over the machine, so a build break fails fast.
echo "▶︎ build-for-testing $SCHEME (compile check before hijacking input)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build-for-testing

echo "▶︎ Running $SCHEME (results → $OUTDIR)"
echo "  Do not touch the keyboard or mouse while this runs."

set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" \
  "${ONLY_ARGS[@]}" \
  test-without-building
STATUS=$?
set -e

echo "▶︎ Exporting window screenshots from the .xcresult"
"$ROOT/scripts/uitests-export.sh" "$RESULT" "$OUTDIR" || true

echo
if [[ $STATUS -eq 0 ]]; then
  echo "✅ UI smoke suite passed. Screenshots: $OUTDIR/index.html"
else
  echo "⚠️  UI smoke suite finished with failures (exit $STATUS)."
  echo "   Screenshots (incl. failing flows): $OUTDIR/index.html"
fi
exit $STATUS

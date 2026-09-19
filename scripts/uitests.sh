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
#   scripts/uitests.sh                       # whole suite, ONE xcodebuild run
#   scripts/uitests.sh -only VGNUITests/DuelFlowTests
#   scripts/uitests.sh -only VGNUITests/DuelFlowTests/testDuelAnswerAdvancesProgressAndUndo
#
#   scripts/uitests.sh --per-class [Class ...]   # ONE xcodebuild run per test class
#   scripts/uitests.sh --per-test  [Class ...]   # ONE xcodebuild run per test method
#   scripts/uitests.sh --list [--per-class|--per-test] [Class ...]   # dry run, runs NOTHING
#
# Why --per-class / --per-test: on this macOS only the *first* test of an
# xcodebuild invocation gets a frontmost, queryable window, so every flow after
# the first in a single run is blocked. Giving each class (or each method) its
# own invocation makes each one "first". --per-test is the fallback if per-class
# still only foregrounds one window per invocation. See docs/uitests.md.
#
# Positional CLASS arguments (bare class names, with or without a `VGNUITests/`
# prefix) restrict --per-class / --per-test / --list to those classes; with none,
# every class discovered under VGNUITests/ runs. `-only <id>` applies to the whole
# -suite mode only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/VGN.xcodeproj"
SCHEME="VGN-UITests"
DERIVED="$ROOT/.build/uitests-dd"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$ROOT/.build/uitests/$STAMP"
PAUSE_SECONDS=3   # settle time between invocations (previous app quits, windows drop)

MODE=whole            # whole | per-class | per-test
LIST_ONLY=0
ONLY_ARGS=()          # -only passthrough (whole mode)
CLASS_FILTER=()       # positional class names (per-class / per-test / --list)

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --per-class) MODE=per-class; shift ;;
    --per-test)  MODE=per-test;  shift ;;
    --list)      LIST_ONLY=1;    shift ;;
    -only)       ONLY_ARGS+=("-only-testing:$2"); shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          echo "unknown arg: $1" >&2; exit 2 ;;
    *)           CLASS_FILTER+=("$1"); shift ;;
  esac
done

# --- Discovery -------------------------------------------------------------

# Every concrete UI-test class = `final class <Name>: VGNUITestCase` (the shared
# base) or `: XCTestCase`. The non-final base `VGNUITestCase` is excluded by the
# `final` filter; A11yIdentifiers.swift declares no class.
discover_classes() {
  grep -hE 'final class [A-Za-z0-9_]+ *: *(VGNUITestCase|XCTestCase)' \
       "$ROOT"/VGNUITests/*.swift 2>/dev/null \
    | sed -E 's/.*final class ([A-Za-z0-9_]+).*/\1/' | sort -u
}

file_for_class() {
  grep -lE "final class $1 *:" "$ROOT"/VGNUITests/*.swift 2>/dev/null | head -1
}

# Test methods of a class (XCTest: `func testXxx()`), one per line.
methods_for_class() {
  local f; f="$(file_for_class "$1")"
  [[ -n "$f" ]] || return 0
  grep -oE 'func test[A-Za-z0-9_]*\(' "$f" \
    | sed -E 's/func (test[A-Za-z0-9_]*)\(/\1/' | sort -u
}

# Resolve the class list: explicit positional args (strip any VGNUITests/ prefix)
# or every discovered class.
CLASSES=()
if [[ ${#CLASS_FILTER[@]} -gt 0 ]]; then
  for c in "${CLASS_FILTER[@]}"; do CLASSES+=("${c#VGNUITests/}"); done
else
  # Class names are single words (no spaces), so word-splitting is safe here and
  # keeps the script parseable by a POSIX `sh -n` (no process substitution).
  for c in $(discover_classes); do CLASSES+=("$c"); done
fi

if [[ ${#CLASSES[@]} -eq 0 ]]; then
  echo "No UI test classes found under $ROOT/VGNUITests/." >&2
  exit 2
fi

# --- --list (runs NOTHING) -------------------------------------------------

if [[ $LIST_ONLY -eq 1 ]]; then
  echo "Would run ${#CLASSES[@]} class(es) from VGNUITests/ in '$MODE' mode:"
  if [[ "$MODE" == per-test ]]; then
    total=0
    for c in "${CLASSES[@]}"; do
      for m in $(methods_for_class "$c"); do
        echo "  test-without-building -only-testing:VGNUITests/$c/$m"
        total=$((total + 1))
      done
    done
    echo "→ $total invocation(s) (one per test method), each its own xcodebuild run."
  elif [[ "$MODE" == per-class ]]; then
    for c in "${CLASSES[@]}"; do
      echo "  test-without-building -only-testing:VGNUITests/$c"
    done
    echo "→ ${#CLASSES[@]} invocation(s) (one per class), each its own xcodebuild run."
  else
    echo "  test  (single run over the whole scheme; add --per-class to split it)"
    for c in "${CLASSES[@]}"; do echo "    · VGNUITests/$c"; done
  fi
  echo "(--list ran nothing.)"
  exit 0
fi

mkdir -p "$OUTDIR"

# --- Shared helpers --------------------------------------------------------

build_for_testing() {
  echo "▶︎ build-for-testing $SCHEME (compile check before hijacking input)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build-for-testing
}

# run_one <result-bundle> <export-subdir> <only-testing-id...>
# Runs one test-without-building invocation; echoes nothing on success/failure
# itself (caller records it). Returns xcodebuild's exit status.
run_one() {
  local rb="$1"; local sub="$2"; shift 2
  local only=()
  for id in "$@"; do only+=("-only-testing:$id"); done
  set +e
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$rb" \
    "${only[@]}" \
    test-without-building
  local st=$?
  set -e
  "$ROOT/scripts/uitests-export.sh" "$rb" "$sub" || true
  return $st
}

print_summary() {
  echo
  echo "──────────────── UI smoke summary ────────────────"
  printf '  %s\n' "$@"
  echo "──────────────────────────────────────────────────"
  echo "Screenshots: $OUTDIR (index.html per run)"
}

# --- Whole-suite mode (default) --------------------------------------------

run_whole() {
  build_for_testing
  local RESULT="$OUTDIR/result.xcresult"
  echo "▶︎ Running $SCHEME (results → $OUTDIR)"
  echo "  Do not touch the keyboard or mouse while this runs."
  set +e
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULT" \
    "${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"}" \
    test-without-building
  local STATUS=$?
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
}

# --- Per-class / per-test modes --------------------------------------------
#
# One build-for-testing up front, then one test-without-building invocation per
# class (or per method) so each is the "first" test of its own run and gets a
# frontmost, queryable window. A short pause lets the previous app fully quit.

run_split() {
  build_for_testing
  echo "▶︎ Running $SCHEME in '$MODE' mode (results → $OUTDIR)."
  echo "  Do not touch the keyboard or mouse while this runs."

  local summary=()
  local overall=0

  for c in "${CLASSES[@]}"; do
    if [[ "$MODE" == per-test ]]; then
      local methods
      methods="$(methods_for_class "$c")"
      if [[ -z "$methods" ]]; then
        echo "  ⚠︎  $c: no test methods found — skipping."
        summary+=("SKIP  $c (no methods)")
        continue
      fi
      for m in $methods; do
        echo "▶︎ [$c/$m]"
        local rb="$OUTDIR/$c.$m.xcresult"
        if run_one "$rb" "$OUTDIR/$c.$m" "VGNUITests/$c/$m"; then
          echo "  ✅ $c/$m PASS"; summary+=("PASS  $c/$m")
        else
          echo "  ❌ $c/$m FAIL"; summary+=("FAIL  $c/$m"); overall=1
        fi
        sleep "$PAUSE_SECONDS"
      done
    else
      echo "▶︎ [$c]"
      local rb="$OUTDIR/$c.xcresult"
      if run_one "$rb" "$OUTDIR/$c" "VGNUITests/$c"; then
        echo "  ✅ $c PASS"; summary+=("PASS  $c")
      else
        echo "  ❌ $c FAIL"; summary+=("FAIL  $c"); overall=1
      fi
      sleep "$PAUSE_SECONDS"
    fi
  done

  print_summary "${summary[@]}"
  if [[ $overall -ne 0 ]]; then
    echo "⚠️  One or more runs failed."
  else
    echo "✅ All runs passed."
  fi
  exit $overall
}

case "$MODE" in
  whole)              run_whole ;;
  per-class|per-test) run_split ;;
esac

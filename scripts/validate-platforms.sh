#!/usr/bin/env bash
# Validate VGN/Resources/platforms.json against the IGDB platform dump.
#
# Checks:
#   1. platforms.json is valid JSON (jq parses it)
#   2. platform ids are unique
#   3. every igdbID referenced exists in the IGDB fixture dump
#   4. no igdbID is used by two different platforms
#   5. required fields present with the right types; enums valid
#
# Usage: scripts/validate-platforms.sh
# Exits non-zero on the first failed check.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORMS="$ROOT/VGN/Resources/platforms.json"
# Trimmed IGDB dump committed as a test fixture (id, name, abbreviation, slug).
IGDB="$ROOT/VGNTests/Fixtures/igdb/platforms.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$PLATFORMS" ] || fail "missing $PLATFORMS"
[ -f "$IGDB" ] || fail "missing $IGDB"

echo "Validating $PLATFORMS"

# 1. Valid JSON, is an array.
jq -e 'type == "array" and length > 0' "$PLATFORMS" >/dev/null \
  || fail "platforms.json is not a non-empty JSON array"
pass "valid JSON array ($(jq length "$PLATFORMS") platforms)"

# 2. Unique ids.
dupe_ids=$(jq -r '[.[].id] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$PLATFORMS")
[ -z "$dupe_ids" ] || fail "duplicate platform ids: $dupe_ids"
pass "platform ids unique"

# 3. Required fields + types + enums.
jq -e '
  all(.[];
    (.id|type=="string") and (.id|test("^[a-z0-9]+$")) and
    (.name|type=="string") and
    (.short|type=="string") and
    (.manufacturer|type=="string") and
    (.group|type=="string") and
    (.kind|type=="string") and (.kind|IN("console","handheld","computer","arcade")) and
    ((.generation==null) or (.generation|type=="number")) and
    (.igdbIDs|type=="array") and (.igdbIDs|length>=1) and (all(.igdbIDs[]; type=="number")) and
    ((.libretroRepo==null) or (.libretroRepo|type=="string")) and
    (.sort|type=="number")
  )
' "$PLATFORMS" >/dev/null || fail "a platform entry is missing a field or has a bad type/enum"
pass "all entries have valid fields, types, kind/group present"

# 4. Every igdbID exists in the dump.
missing=$(jq -n --slurpfile p "$PLATFORMS" --slurpfile g "$IGDB" '
  ($g[0] | map(.id)) as $known
  | [ $p[0][] | . as $plat | .igdbIDs[] | select(. as $x | ($known | index($x)) | not) ]
  | unique | .[]')
[ -z "$missing" ] || fail "igdbIDs not present in IGDB dump: $missing"
pass "every igdbID exists in the IGDB dump"

# 5. No igdbID used by two platforms.
shared=$(jq -r '[.[].igdbIDs[]] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$PLATFORMS")
[ -z "$shared" ] || fail "igdbID used by more than one platform: $shared"
pass "no igdbID shared across platforms"

echo "All platforms.json checks passed."

#!/usr/bin/env bash
#
# Export the window-only screenshot attachments from an .xcresult bundle and
# build an index.html gallery. Called by scripts/uitests.sh; can also be run by
# hand on any result bundle:
#
#   scripts/uitests-export.sh path/to/result.xcresult path/to/outdir

set -euo pipefail

RESULT="${1:?usage: uitests-export.sh <result.xcresult> <outdir>}"
OUTDIR="${2:?usage: uitests-export.sh <result.xcresult> <outdir>}"
ATT="$OUTDIR/attachments"
mkdir -p "$ATT"

if [[ ! -e "$RESULT" ]]; then
  echo "no result bundle at $RESULT" >&2
  exit 1
fi

# Xcode 15+/16+/26: the modern attachment exporter writes every attachment plus a
# manifest.json mapping exported files to their test + human-readable name.
xcrun xcresulttool export attachments \
  --path "$RESULT" \
  --output-path "$ATT" >/dev/null 2>&1 || {
    echo "xcresulttool export attachments failed; the bundle may have no attachments" >&2
  }

# Build index.html from the manifest (falling back to a plain image glob).
python3 - "$ATT" "$OUTDIR/index.html" <<'PY'
import json, os, sys, html, glob

att_dir, out_html = sys.argv[1], sys.argv[2]
items = []  # (test, name, relpath)

manifest = os.path.join(att_dir, "manifest.json")
if os.path.exists(manifest):
    try:
        data = json.load(open(manifest))
        # manifest is a list of test entries, each with "attachments".
        entries = data if isinstance(data, list) else data.get("attachments", [])
        for test_entry in entries:
            test = test_entry.get("testIdentifier") or test_entry.get("testIdentifierString") or ""
            for a in test_entry.get("attachments", []):
                fn = a.get("exportedFileName")
                name = a.get("suggestedHumanReadableName") or fn or ""
                if fn and os.path.exists(os.path.join(att_dir, fn)):
                    items.append((test, name, os.path.join("attachments", fn)))
    except Exception as e:
        print("manifest parse failed:", e, file=sys.stderr)

if not items:
    for p in sorted(glob.glob(os.path.join(att_dir, "*.png")) +
                    glob.glob(os.path.join(att_dir, "*.jpg")) +
                    glob.glob(os.path.join(att_dir, "*.jpeg"))):
        rel = os.path.join("attachments", os.path.basename(p))
        items.append(("", os.path.basename(p), rel))

def is_image(rel):
    return rel.lower().endswith((".png", ".jpg", ".jpeg"))

imgs = [it for it in items if is_image(it[2])]

rows = []
for test, name, rel in imgs:
    cap = html.escape(name)
    sub = html.escape(test)
    rows.append(
        f'<figure><img loading="lazy" src="{html.escape(rel)}">'
        f'<figcaption><b>{cap}</b><br><span>{sub}</span></figcaption></figure>')

doc = f"""<!doctype html><html><head><meta charset="utf-8">
<title>VGN UI smoke screenshots</title>
<style>
 body{{font:14px -apple-system,system-ui,sans-serif;margin:24px;background:#f6f6f7;color:#111}}
 h1{{font-size:18px}} .count{{color:#666}}
 .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:18px}}
 figure{{margin:0;background:#fff;border:1px solid #ddd;border-radius:10px;overflow:hidden}}
 img{{width:100%;display:block;background:#000}}
 figcaption{{padding:8px 10px;font-size:12px}} figcaption span{{color:#888}}
 @media (prefers-color-scheme:dark){{body{{background:#1c1c1e;color:#eee}}figure{{background:#2c2c2e;border-color:#3a3a3c}}figcaption span{{color:#9a9a9a}}}}
</style></head><body>
<h1>VGN UI smoke screenshots <span class="count">— {len(imgs)} window shots</span></h1>
<div class="grid">
{os.linesep.join(rows) if rows else "<p>No image attachments found.</p>"}
</div></body></html>"""

open(out_html, "w").write(doc)
print(f"wrote {out_html} ({len(imgs)} images)")
PY

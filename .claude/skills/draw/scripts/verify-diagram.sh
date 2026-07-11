#!/usr/bin/env bash
# Renders a draw-skill diagram in headless Chrome and reports real layout
# defects: text overflowing its box, text running off the viewBox, and
# arrows/curves physically crossing through text. See verify_layout.js for
# what each category means.
#
# Usage: verify-diagram.sh path/to/diagram.html
#
# Exits 0 with "OK — no layout issues found" if clean.
# Exits 1 and prints a JSON report if anything was found — fix the
# reported elements and re-run before treating the diagram as done.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 path/to/diagram.html" >&2
  exit 2
fi

DIAGRAM="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_JS="$SCRIPT_DIR/verify_layout.js"

if [ ! -f "$DIAGRAM" ]; then
  echo "error: $DIAGRAM not found" >&2
  exit 2
fi

CHROME=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "$(command -v google-chrome 2>/dev/null || true)" \
  "$(command -v chromium 2>/dev/null || true)"
do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    CHROME="$candidate"
    break
  fi
done

if [ -z "$CHROME" ]; then
  echo "error: no Chrome/Chromium found — cannot verify layout headlessly." >&2
  echo "Install Google Chrome, or verify by eye at 100% zoom in an actual browser instead." >&2
  exit 2
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

PROBE="$TMPDIR_LOCAL/probe.html"
{
  echo '<!doctype html><html><head><meta charset="utf-8"></head><body>'
  cat "$DIAGRAM"
  echo '<div id="verify-report" style="white-space:pre"></div>'
  echo "<script>$(cat "$VERIFY_JS")</script>"
  echo '</body></html>'
} > "$PROBE"

DOM_OUT="$TMPDIR_LOCAL/dom.html"
"$CHROME" --headless=new --disable-gpu --no-sandbox --dump-dom "file://$PROBE" > "$DOM_OUT" 2>/dev/null

REPORT_JSON="$TMPDIR_LOCAL/report.json"
python3 -c "
import re
content = open('$DOM_OUT').read()
m = re.search(r'<div id=\"verify-report\"[^>]*>(.*?)</div>', content, re.S)
out = m.group(1) if m else '{\"error\": \"report div not found - probe page failed to load or run\"}'
open('$REPORT_JSON', 'w').write(out)
"

python3 -c "
import json, sys
report = json.load(open('$REPORT_JSON'))
if 'error' in report:
    print('ERROR:', report['error'])
    sys.exit(2)
box = report.get('boxIssues', [])
glob = report.get('globalIssues', [])
path = report.get('pathIssues', [])
total = len(box) + len(glob) + len(path)
if total == 0:
    print('OK — no layout issues found (checked text-in-box overflow, viewBox-width overflow, arrow/text collisions)')
    sys.exit(0)
print('LAYOUT ISSUES FOUND: %d box overflow, %d viewBox overflow, %d arrow/text collisions' % (len(box), len(glob), len(path)))
print()
print(json.dumps(report, indent=2))
sys.exit(1)
"

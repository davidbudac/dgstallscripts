#!/bin/sh
# Render gate. Builds a report from bundles with the repo's make_report.sh, adds tests/hover.html (hovers every chart mark,
# logs the tooltips into the page), renders it in headless Chrome and writes
#   <prefix>.html  the report       <prefix>.dom  the rendered DOM      <prefix>.txt  the derived claims (extract.py)
#   <prefix>.js    JavaScript console errors, one per line; empty = none
# Usage: gate.sh <out prefix> bundle.jsonl [bundle.jsonl ...]      gate.sh --have-chrome   (exit 0 when a browser and python3 exist)
# GATE_HASH=#handover renders the page opened with that address (the pane that the hash selects).
# CHROME overrides the browser path. Exit status: 0 rendered, 1 build or render failed.
T=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$T")
find_chrome() {
  [ -n "$CHROME" ] && { [ -x "$CHROME" ] && echo "$CHROME"; return; }
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome google-chrome-stable chromium chromium-browser; do
    if [ -x "$c" ]; then echo "$c"; return; fi
    p=$(command -v "$c" 2>/dev/null) && { echo "$p"; return; }
  done
}
B=$(find_chrome)
if [ "$1" = --have-chrome ]; then [ -n "$B" ] && command -v python3 >/dev/null 2>&1; exit; fi
[ -n "$B" ] || { echo "no Chrome found (set CHROME)" >&2; exit 1; }
PFX=$1; shift
sh "$REPO/sh/make_report.sh" -o "$PFX.html" "$@" 2>/dev/null || { echo "make_report failed" >&2; exit 1; }
python3 - "$PFX.html" "$T/hover.html" <<'PY'
import sys
s = open(sys.argv[1], encoding='utf-8').read()
open(sys.argv[1], 'w', encoding='utf-8').write(s.replace('</body>', open(sys.argv[2], encoding='utf-8').read() + '</body>'))
PY
"$B" --headless=new --disable-gpu --enable-logging=stderr --virtual-time-budget=6000 --user-data-dir="$PFX.profile" \
  --dump-dom "file://$PFX.html$GATE_HASH" > "$PFX.dom" 2> "$PFX.err"
rm -rf "$PFX.profile"
[ -s "$PFX.dom" ] || { echo "Chrome produced no DOM" >&2; exit 1; }
python3 "$T/extract.py" "$PFX.dom" > "$PFX.txt"
grep -E 'CONSOLE|Uncaught|SyntaxError|TypeError|ReferenceError' "$PFX.err" > "$PFX.js"
exit 0

#!/bin/sh
# Build the self-contained HTML report from bundles written by collect.sh.
# Runs anywhere with a POSIX shell (AIX, Linux, macOS). Open the result in any browser; it works offline.
#
# Usage: sh/make_report.sh [-o report.html] [bundle.jsonl ...]
#        Without bundle arguments it takes every ./dgr_*.jsonl in the current directory and says which files it took.

DIR=$(cd "$(dirname "$0")/.." && pwd)
TPL=$DIR/report/template.html
OUT=
while getopts o:h opt; do case $opt in o) OUT=$OPTARG ;; *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;; esac; done
shift $((OPTIND - 1))
[ -r "$TPL" ] || { echo "Template not found: $TPL" >&2; exit 1; }
if [ $# -eq 0 ]; then
  for f in ./dgr_*.jsonl; do [ -f "$f" ] && set -- "$@" "$f"; done
  if [ $# -eq 0 ]; then
    echo "No bundle given and no ./dgr_*.jsonl in $(pwd)." >&2
    echo "Run sh/collect.sh on each database host first (standby, then primary), copy the bundles to one directory, then run this there" >&2
    echo "or name the bundles:  sh/make_report.sh -o report.html dgr_primary_*.jsonl dgr_standby_*.jsonl" >&2
    exit 1
  fi
  echo "No bundle given: using the $# file(s) matching ./dgr_*.jsonl in $(pwd):" >&2
  for f in "$@"; do echo "  $f" >&2; done
fi
for f in "$@"; do [ -r "$f" ] || { echo "Cannot read $f" >&2; exit 1; }; done
OUT=${OUT:-./dg_report_$(date +%Y%m%d_%H%M%S).html}

{
  sed -n '1,/<!--DATA-->/p' "$TPL" | sed '$d'
  for f in "$@"; do
    printf '<script type="text/plain" class="dgr-bundle" data-file="%s">\n' "$(basename "$f" | sed 's/[<>"&]/_/g')"
    sed 's#</#<\\/#g' "$f"
    printf '</script>\n'
  done
  sed -n '/<!--DATA-->/,$p' "$TPL" | sed '1d'
} > "$OUT"
echo "Report written: $OUT" >&2

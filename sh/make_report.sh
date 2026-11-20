#!/bin/sh
# Build the self-contained HTML report from bundles written by collect.sh.
# Runs anywhere with a POSIX shell (AIX, Linux, macOS). Open the result in any browser; it works offline.
#
# Usage: sh/make_report.sh [-o report.html] bundle.jsonl [bundle.jsonl ...]

DIR=$(cd "$(dirname "$0")/.." && pwd)
TPL=$DIR/report/template.html
OUT=
while getopts o:h opt; do case $opt in o) OUT=$OPTARG ;; *) sed -n '2,5p' "$0"; exit 1 ;; esac; done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { sed -n '2,5p' "$0"; exit 1; }
[ -r "$TPL" ] || { echo "Template not found: $TPL" >&2; exit 1; }
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

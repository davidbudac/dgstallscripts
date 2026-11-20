#!/bin/sh
# Steps 2/3: alert log for the window, read from the text file. Run on the STANDBY
# (v$diag_alert_ext raises ORA-01219 on a mounted standby); works on the primary too.
# Read-only, needs no database connection.
#
# Usage: alert_log_scan.sh <alert_SID.log> <YYYY-MM-DD> <HH:MI from> <HH:MI to>
#   e.g. alert_log_scan.sh $ORACLE_BASE/diag/rdbms/<db_unique_name>/<SID>/trace/alert_<SID>.log 2026-11-13 20:35 20:58
# Part 1 = every message in the window. Part 2 = Data Guard / network errors across the whole file,
# to see whether they recur at the same time of day.

[ $# -eq 4 ] || { sed -n '2,10p' "$0"; exit 1; }
LOG=$1; DAY=$2; FROM=$3; TO=$4

# 12.2+ alert timestamps sit on their own line: 2026-11-13T20:38:58.734367+01:00
echo "== 1. All messages $DAY $FROM-$TO"
awk -v d="$DAY" -v f="$FROM" -v t="$TO" '
  /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ {
      ts = substr($1,12,12); hm = substr($1,12,5); inwin = (substr($1,1,10) == d && hm >= f && hm <= t); next }
  inwin { print ts, $0 }' "$LOG"

echo
echo "== 2. Data Guard and network errors in the whole file (first line of each)"
awk '
  /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ { ts = substr($1,1,19); next }
  /UNSYNCHRONIZED|ORA-16198|ORA-03135|ORA-16055|ORA-16191|TNS-12535|TNS-12170|TNS-12609|Possible network disconnect/ {
      print ts, $0 }' "$LOG" | awk '{ k = $1 " " $2; if (k != last) print; last = k }'

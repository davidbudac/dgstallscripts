#!/bin/sh
# Step 2/3: errors in LGWR, NSS, TT, ARC, TMON, RFS and MRP traces inside the window.
# Run on each host. Read-only.
#
# Usage: trace_scan.sh <trace dir> <YYYY-MM-DD> <HH:MI from> <HH:MI to> [days back, default 7]
#   e.g. trace_scan.sh $ORACLE_BASE/diag/rdbms/<db_unique_name>/<SID>/trace 2026-11-13 20:35 20:58
# (trace dir = "Diag Trace" in v$diag_info; section 00 of the SQL output prints it)
#
# The nt/OS error codes are errno values: look them up in /usr/include/errno.h on that host
# (AIX and Linux numbers differ). 0 = no OS-level error reported with the failure.

[ $# -ge 4 ] || { sed -n '2,11p' "$0"; exit 1; }
DIR=$1; DAY=$2; FROM=$3; TO=$4; BACK=${5:-7}

FILES=$(find "$DIR" -type f \( -name '*_lgwr_*.trc' -o -name '*_nss*_*.trc' -o -name '*_tt0*_*.trc' \
          -o -name '*_arc*_*.trc' -o -name '*_tmon_*.trc' -o -name '*_rfs_*.trc' -o -name '*_mrp0_*.trc' \) \
          -mtime -"$BACK" 2>/dev/null)
[ -n "$FILES" ] || { echo "No matching trace files in $DIR from the last $BACK days"; exit 0; }

# 12.2+ trace timestamps look like: *** 2026-11-13T20:38:58.734367+01:00 (CDB$ROOT(1))
for f in $FILES; do
  awk -v d="$DAY" -v fr="$FROM" -v to="$TO" -v fn="$(basename "$f")" '
    $1 == "***" && $2 ~ /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T/ {
        ts = $2; inwin = (substr(ts,1,10) == d && substr(ts,12,5) >= fr && substr(ts,12,5) <= to); next }
    inwin && /ORA-|TNS-|nt main err|nt secondary err|ns secondary err|nt OS err|[Tt]ime[d ]*out|[Ee]rror/ {
        print substr(ts,12,12), fn ":", $0 }' "$f"
done | sort

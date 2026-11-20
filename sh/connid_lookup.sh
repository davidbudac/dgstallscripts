#!/bin/sh
# Step 3: did the clients refused at the standby reach the primary?
# Run on the PRIMARY host with the file written by listener_log_scan.sh on the standby.
#
# Usage: connid_lookup.sh <primary listener.log> <refused_connection_ids.txt>
# Prints every primary listener request carrying one of those CONNECTION_IDs (time, client, return code),
# then the IDs that never appear on the primary. Pure awk: listener logs may contain binary bytes.

[ $# -eq 2 ] || { sed -n '2,7p' "$0"; exit 1; }
LOG=$1; IDS=$2
[ -s "$IDS" ] || { echo "No CONNECTION_IDs in $IDS"; exit 0; }

awk -F' [*] ' '
  NR == FNR { if (NF) want[$0] = 1; next }
  match($0, /CONNECTION_ID=[^)]*/) {
      cid = substr($0, RSTART + 14, RLENGTH - 14)
      if (!(cid in want)) next
      seen[cid] = 1; ip = "?"
      if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)/)) {
        s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); ip = s }
      print $1, ip, "code=" $NF, cid }
  END {
      print ""; print "IDs not found on the primary:"
      for (c in want) if (!(c in seen)) print "  " c }' "$IDS" "$LOG"

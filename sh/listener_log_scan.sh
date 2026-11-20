#!/bin/sh
# Step 3: what reached a listener in the window, from where, and what was refused.
# Run on the standby (and the primary) host. Read-only. Works with AIX and Linux awk.
#
# Usage: listener_log_scan.sh <listener.log> <DD-MON-YYYY> <HH:MI from> <HH:MI to>
#   e.g. listener_log_scan.sh $ORACLE_BASE/diag/tnslsnr/$(hostname)/listener/trace/listener.log 13-NOV-2026 20:35 20:58
# Find the log with: lsnrctl status <listener>   ("Listener Log File" points at alert/log.xml;
#                    the text log is ../trace/<listener>.log)
# Writes refused CONNECTION_IDs to ./refused_connection_ids.txt for connid_lookup.sh.

[ $# -eq 4 ] || { sed -n '2,11p' "$0"; exit 1; }
LOG=$1; DAY=$2; FROM=$3; TO=$4
WIN=${TMPDIR:-/tmp}/lsnr_window.$$
trap 'rm -f "$WIN"' 0 1 2 15

awk -v d="$DAY" -v f="$FROM" -v t="$TO" \
    '$1 == d { hm = substr($2,1,5); if (hm >= f && hm <= t) print }' "$LOG" > "$WIN"

echo "== Window $DAY $FROM-$TO in $LOG: $(wc -l < "$WIN" | tr -d ' ') timestamped lines"

echo
echo "== 1. Connection requests per minute and return code (0 = accepted)"
awk -F' [*] ' '$0 ~ / [*] establish [*] / { split($1, a, " "); print substr(a[2],1,5), "code=" $NF }' "$WIN" |
  sort | uniq -c

echo
echo "== 2. Connection requests by client IP and return code"
awk -F' [*] ' '$0 ~ / [*] establish [*] / {
    ip = "?"
    if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)/)) {
      s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); ip = s }
    print ip, "code=" $NF }' "$WIN" | sort | uniq -c | sort -rn

echo
echo "== 3. Requested service by return code (12514 = service not registered here)"
awk -F' [*] ' '$0 ~ / [*] establish [*] / {
    svc = "?"
    if (match($0, /SERVICE_NAME=[^)]*/)) svc = substr($0, RSTART + 13, RLENGTH - 13)
    else if (match($0, /SID=[^)]*/))     svc = "SID:" substr($0, RSTART + 4, RLENGTH - 4)
    print svc, "code=" $NF }' "$WIN" | sort | uniq -c | sort -rn

echo
echo "== 4. Refused requests (non-zero code) with time, client and CONNECTION_ID"
awk -F' [*] ' '$0 ~ / [*] establish [*] / && $NF != "0" {
    ip = "?"; cid = "-"
    if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)/)) {
      s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); ip = s }
    if (match($0, /CONNECTION_ID=[^)]*/)) cid = substr($0, RSTART + 14, RLENGTH - 14)
    print $1, ip, "code=" $NF, cid }' "$WIN" | tee refused.$$
awk '$NF != "-" { print $NF }' refused.$$ | sort -u > refused_connection_ids.txt
rm -f refused.$$
echo "-> $(wc -l < refused_connection_ids.txt | tr -d ' ') distinct CONNECTION_IDs in ./refused_connection_ids.txt"

echo
echo "== 5. Other listener events per minute (service_update, service_died, ping, status ...)"
awk -F' [*] ' '$0 !~ / [*] establish [*] / && NF > 1 { split($1, a, " "); print substr(a[2],1,5), $2 }' "$WIN" |
  sort | uniq -c

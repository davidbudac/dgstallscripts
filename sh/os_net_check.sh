#!/bin/sh
# Step 4: network and OS checks between the redo endpoints. Run on BOTH hosts. Read-only.
# Run once on a normal day for a baseline, and again during or right after a stall.
#
# Usage: os_net_check.sh <peer redo IP> <standby listener port> [seconds, default 60]
#   on the primary: peer = standby redo IP;  on the standby: peer = primary redo IP
# Over <seconds> it samples the redo connection every 5 s and diffs TCP retransmit counters.
# Some adapter statistics need root; failures there are reported and skipped.

[ $# -ge 2 ] || { sed -n '2,9p' "$0"; exit 1; }
PEER=$1; PORT=$2; SECS=${3:-60}
OS=$(uname)
TMP=${TMPDIR:-/tmp}/osnet.$$
trap 'rm -f "$TMP".*' 0 1 2 15

echo "== $(hostname) $OS $(date '+%Y-%m-%d %H:%M:%S %Z') peer=$PEER port=$PORT"

echo
echo "== 1. Round trip and loss (20 pings)"
ping -c 20 "$PEER" 2>&1 | tail -4

echo
echo "== 2. Connections on port $PORT now (Send-Q growing on the sender = no TCP acks coming back)"
netstat -an | grep -E "[.:]$PORT[[:space:]]" | grep -v LISTEN

echo
echo "== 3. Sampling the connection every 5 s for $SECS s, and TCP retransmits before/after"
netstat -s > "$TMP".s1 2>&1
i=0
while [ $i -lt "$SECS" ]; do
  echo "-- $(date '+%H:%M:%S')"
  netstat -an | grep -E "[.:]$PORT[[:space:]]" | grep -E "$PEER" | grep -v LISTEN
  sleep 5; i=$((i + 5))
done
netstat -s > "$TMP".s2 2>&1
echo "-- retransmit counters, before:"
grep -i retrans "$TMP".s1
echo "-- after $SECS s:"
grep -i retrans "$TMP".s2

echo
echo "== 4. Adapters and OS log"
case "$OS" in
  AIX)
    for ent in $(lsdev -Cc adapter -F name 2>/dev/null | grep '^ent'); do
      echo "-- entstat -d $ent"
      entstat -d "$ent" 2>&1 | grep -iE 'link status|errors|collisions|timeout|dropped|no resource|lacp|operational' | head -25
    done
    echo "-- errpt (newest 40)"
    errpt 2>&1 | head -41
    echo "-- TCP keepalive / buffer tunables"
    no -a 2>/dev/null | grep -E 'tcp_keep|tcp_sendspace|tcp_recvspace|rfc1323|sb_max'
    ;;
  Linux)
    echo "-- ip -s link"
    ip -s link 2>&1
    echo "-- ss on port $PORT"
    ss -tin "( dport = :$PORT or sport = :$PORT )" 2>&1
    echo "-- kernel log (last 40 lines)"
    (journalctl -k -n 40 --no-pager 2>/dev/null || dmesg | tail -40) 2>&1
    echo "-- TCP keepalive tunables"
    sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes 2>&1
    ;;
  *)
    echo "No adapter checks for $OS"
    ;;
esac

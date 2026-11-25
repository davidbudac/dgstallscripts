#!/bin/sh
# Optional sampler for the NEXT occurrence: one line per interval with the time, one ping's round trip (or loss), the TCP retransmit counter
# and the largest Send-Q on connections to the peer. You start it (nohup or cron); collect.sh never does. Read-only: ping and netstat, the same
# commands as the network check of collect.sh. It writes only its log. Stop it with kill; it keeps nothing else running.
#
# Usage: net_sampler.sh <peer IP> [port] [interval s] [log file]
#        defaults: port 1521, interval 5, log ./net_sampler.log
#   e.g. nohup sh net_sampler.sh 198.51.100.12 1526 5 /var/tmp/net_sampler.log >/dev/null 2>&1 &
#   later: sh/collect.sh -n /var/tmp/net_sampler.log ... adds the samples inside the window to the bundle
# Line:  2026-11-21T09:00:01+0100 rtt=0.412 retr=12345 sendq=0     (rtt=loss when the ping got no reply; retr = cumulative counter, subtract two lines)
# Environment: MAXKB  size at which the log moves to <log>.1 (one older file is kept; default 5120)
#              COUNT  stop after this many samples (default 0 = run until killed)
#              PING_OPTS  options for the single ping (default "-W 2" on Linux: wait 2 s for the reply; none elsewhere)

[ $# -ge 1 ] || { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
PEER=$1; PORT=${2:-1521}; INT=${3:-5}; LOG=${4:-./net_sampler.log}
MAXKB=${MAXKB:-5120}; COUNT=${COUNT:-0}
for v in "$PORT" "$INT" "$MAXKB" "$COUNT"; do case $v in ''|*[!0-9]*) echo "net_sampler.sh: port, interval, MAXKB and COUNT must be whole numbers" >&2; exit 1 ;; esac; done
[ "$INT" -ge 1 ] || { echo "net_sampler.sh: interval must be at least 1 s" >&2; exit 1; }
[ "$(uname)" = Linux ] && PING_OPTS=${PING_OPTS--W 2}

retr() { netstat -s 2>/dev/null | awk '/retransmitted/ && !/SynRetrans/ { n += $1 } END { print n + 0 }'; }
sendq() { netstat -an 2>/dev/null | awk -v p="$PORT" -v peer="$PEER" '$0 ~ peer && ($4 ~ "[.:]" p "$" || $5 ~ "[.:]" p "$") { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }'; }
header() { echo "# net_sampler peer=$PEER port=$PORT interval=$INT started=$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
trap 'exit 0' 1 2 15
header
i=0
while :; do
  TS=$(date '+%Y-%m-%dT%H:%M:%S%z')
  RTT=$(ping -c 1 $PING_OPTS "$PEER" 2>&1 | awk -F'= ' '/min\/avg/ { split($2, a, "/"); print a[2]; exit }')
  echo "$TS rtt=${RTT:-loss} retr=$(retr) sendq=$(sendq)" >> "$LOG"
  i=$((i + 1))
  [ "$COUNT" -gt 0 ] && [ "$i" -ge "$COUNT" ] && break
  SZ=$(wc -c < "$LOG" | tr -d ' ')
  if [ "$SZ" -gt $((MAXKB * 1024)) ]; then mv "$LOG" "$LOG.1"; header; fi
  sleep "$INT"
done

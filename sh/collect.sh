#!/bin/sh
# Collect everything the HTML report needs from ONE host into one bundle file (JSON lines).
# Read-only: SELECTs on the database, reads of the alert log, traces and listener log.
#
# Usage: sh/collect.sh [options] primary|standby "YYYY-MM-DD HH:MI" "YYYY-MM-DD HH:MI"
#
#   -o file    bundle to write            (default ./dgr_<side>_<host>_<now>.jsonl)
#   -u conn    sqlplus connect string     (default "/ as sysdba")
#   -t dir     trace directory            (default: "Diag Trace" from v$diag_info)
#   -a file    text alert log             (default: <trace dir>/alert_$ORACLE_SID.log)
#   -l file    listener text log          (default: found with lsnrctl status)
#   -c file    standby bundle: look up its refused CONNECTION_IDs in this listener log
#   -p ip      peer redo IP: add a 10 s network check (-P port, default 1521)
#   -d days    how far back "earlier occurrences" looks (default 30)
#
# Run it on the standby first, then on the primary with -c <standby bundle>.
# Then: sh/make_report.sh dgr_*.jsonl   (on any machine)
# The window must lie within one day, in the hosts' local time.

usage() { sed -n '2,19p' "$0"; exit 1; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT= CONN="/ as sysdba" TRACE= ALERT= LSNR= CIDS= PEER= PORT=1521 DAYS=30
# options may come before, between or after the three positional arguments
N=0 A1= A2= A3=
while [ $# -gt 0 ]; do
  OPTIND=1
  while getopts o:u:t:a:l:c:p:P:d:h opt; do
    case $opt in
      o) OUT=$OPTARG ;; u) CONN=$OPTARG ;; t) TRACE=$OPTARG ;; a) ALERT=$OPTARG ;; l) LSNR=$OPTARG ;;
      c) CIDS=$OPTARG ;; p) PEER=$OPTARG ;; P) PORT=$OPTARG ;; d) DAYS=$OPTARG ;; *) usage ;;
    esac
  done
  shift $((OPTIND - 1))
  [ $# -gt 0 ] || break
  N=$((N + 1))
  case $N in 1) A1=$1 ;; 2) A2=$1 ;; 3) A3=$1 ;; *) usage ;; esac
  shift
done
[ $N -eq 3 ] || usage
set -- "$A1" "$A2" "$A3"
SIDE=$1
case $SIDE in primary|standby) ;; *) usage ;; esac

norm() { case "$1" in
  [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]) echo "$1:00" ;;
  [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) echo "$1" ;;
  *) echo "" ;; esac; }
F=$(norm "$2"); T=$(norm "$3")
[ -n "$F" ] && [ -n "$T" ] || { echo "Times must look like \"2026-11-13 20:35\"" >&2; exit 1; }
DAY=$(echo "$F" | cut -c1-10); FHM=$(echo "$F" | cut -c12-16); THM=$(echo "$T" | cut -c12-16)
[ "$DAY" = "$(echo "$T" | cut -c1-10)" ] || echo "Warning: the window crosses midnight; log scans only cover $DAY." >&2
LDAY=$(awk -v d="$DAY" 'BEGIN { split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC", m, " ");
                                print substr(d, 9, 2) "-" m[substr(d, 6, 2) + 0] "-" substr(d, 1, 4) }')
HOST=$(hostname | cut -d. -f1)
OUT=${OUT:-./dgr_${SIDE}_${HOST}_$(date +%Y%m%d_%H%M%S).jsonl}
TMP=${TMPDIR:-/tmp}/dgr.$$
trap 'rm -f "$TMP".*' 0 1 2 15
note() { echo "  $*" >&2; }

# portable JSON string escaping for awk (no gsub backslash tricks)
JFN='function j(s,   o, i, c) { o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1);
       if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else if (c == "\t") o = o "\\t";
       else if (c == "\n") o = o "\\n"; else if (c != "\r") o = o c } return o }'
clean() { tr -d '\000-\010\013\014\016-\037'; }   # drop control bytes except tab, newline, CR

echo "Collecting $SIDE data for $F -> $T into $OUT" >&2
printf '{"t":"bundle","side":"%s","host":"%s","from":"%s","to":"%s","collected":"%s","cidcheck":"%s","v":1}\n' \
  "$SIDE" "$HOST" "$F" "$T" "$(date '+%Y-%m-%d %H:%M:%S')" "$([ -n "$CIDS" ] && echo yes || echo no)" > "$OUT"

# ---- database
if command -v sqlplus >/dev/null 2>&1; then
  if [ -z "$TRACE" ]; then
    TRACE=$(sqlplus -S -L "$CONN" <<'EOF' 2>/dev/null | awk 'NF { print; exit }'
set heading off feedback off pagesize 0 verify off
select value from v$diag_info where name = 'Diag Trace';
exit
EOF
)
  fi
  sqlplus -S -L "$CONN" @"$DIR/sql/json_$SIDE.sql" "$F" "$T" "$DAYS" "$OUT" </dev/null >/dev/null 2>&1
  note "database: done"
else
  note "database: sqlplus not found, skipped"
fi

# ---- alert log text file (the standby cannot read it through SQL while mounted)
if [ "$SIDE" = standby ] || [ -n "$ALERT" ]; then
  ALERT=${ALERT:-$TRACE/alert_${ORACLE_SID:-unknown}.log}
  if [ -r "$ALERT" ]; then
    clean < "$ALERT" | awk -v d="$DAY" -v f="$FHM" -v t="$THM" -v side="$SIDE" "$JFN"'
      function flush() { if (inwin && msg != "") print "{\"t\":\"alert\",\"side\":\"" side "\",\"ts\":\"" ts "\",\"msg\":\"" j(substr(msg, 1, 2000)) "\"}"; msg = "" }
      /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ { flush(); ts = substr($1, 12, 12); hm = substr($1, 12, 5)
          inwin = (substr($1, 1, 10) == d && hm >= f && hm <= t); next }
      inwin { msg = (msg == "" ? $0 : msg "\n" $0) }
      END { flush() }' >> "$OUT"
    clean < "$ALERT" | awk -v side="$SIDE" "$JFN"'
      /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ { ts = substr($1, 1, 10) " " substr($1, 12, 8); next }
      /UNSYNCHRONIZED|ORA-16198|ORA-03135|ORA-16055|TNS-12535|TNS-12170|Possible network disconnect/ {
          if (ts != last) print "{\"t\":\"alhist\",\"side\":\"" side "\",\"ts\":\"" ts "\",\"msg\":\"" j(substr($0, 1, 300)) "\"}"; last = ts }' \
      | tail -300 >> "$OUT"
    note "alert log: $ALERT"
  else
    note "alert log: not readable ($ALERT), skipped; use -a"
  fi
fi

# ---- background traces
if [ -n "$TRACE" ] && [ -d "$TRACE" ]; then
  FILES=$(find "$TRACE" -type f \( -name '*_lgwr_*.trc' -o -name '*_nss*_*.trc' -o -name '*_tt0*_*.trc' \
            -o -name '*_arc*_*.trc' -o -name '*_tmon_*.trc' -o -name '*_rfs_*.trc' -o -name '*_mrp0_*.trc' \) -mtime -45 2>/dev/null)
  for fl in $FILES; do
    clean < "$fl" | awk -v d="$DAY" -v fr="$FHM" -v to="$THM" -v fn="$(basename "$fl")" -v side="$SIDE" "$JFN"'
      $1 == "***" && $2 ~ /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T/ {
          ts = substr($2, 12, 12); inwin = (substr($2, 1, 10) == d && substr($2, 12, 5) >= fr && substr($2, 12, 5) <= to); next }
      inwin && /ORA-|TNS-|nt main err|nt secondary err|ns secondary err|nt OS err|[Tt]ime[d ]*out|[Ee]rror/ {
          print ts "\t{\"t\":\"trace\",\"side\":\"" side "\",\"ts\":\"" ts "\",\"file\":\"" fn "\",\"msg\":\"" j(substr($0, 1, 400)) "\"}" }'
  done | sort | head -400 | cut -f2- >> "$OUT"
  note "traces: $TRACE"
else
  note "traces: directory not found, skipped; use -t"
fi

# ---- listener log
if [ -z "$LSNR" ] && command -v lsnrctl >/dev/null 2>&1; then
  LST=$(lsnrctl status 2>/dev/null)
  X=$(echo "$LST" | awk '/Listener Log File/ { print $NF; exit }')
  ALIAS=$(echo "$LST" | awk '/^Alias/ { print tolower($2); exit }')
  case $X in
    */alert/log.xml) D=${X%/alert/log.xml}/trace
                     if [ -r "$D/${ALIAS:-listener}.log" ]; then LSNR=$D/${ALIAS:-listener}.log
                     else LSNR=$(ls -t "$D"/*.log 2>/dev/null | head -1); fi ;;
    *.log) LSNR=$X ;;
  esac
fi
if [ -n "$LSNR" ] && [ -r "$LSNR" ]; then
  clean < "$LSNR" | awk -v d="$LDAY" -v f="$FHM" -v t="$THM" '$1 == d { hm = substr($2, 1, 5); if (hm >= f && hm <= t) print }' > "$TMP.win"
  LAWK="$JFN"'
    function code() { c = $NF; gsub(/[^0-9]/, "", c); return c }
    function ip() { if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)/)) { s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); return s } return "" }
    function cid() { if (match($0, /CONNECTION_ID=[^)]*/)) return substr($0, RSTART + 14, RLENGTH - 14); return "" }
    function svc() { if (match($0, /SERVICE_NAME=[^)]*/)) return substr($0, RSTART + 13, RLENGTH - 13); if (match($0, /SID=[^)]*/)) return "SID:" substr($0, RSTART + 4, RLENGTH - 4); return "" }'
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / { split($1, a, " "); n[substr(a[2], 1, 5) "|" code()]++ }
    END { for (k in n) { split(k, b, "|"); print "{\"t\":\"lsnr\",\"side\":\"" side "\",\"m\":\"" b[1] "\",\"code\":\"" b[2] "\",\"n\":" n[k] "}" } }' "$TMP.win" >> "$OUT"
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / { n[ip() "|" code()]++ }
    END { for (k in n) { split(k, b, "|"); print "{\"t\":\"lsnr_ip\",\"side\":\"" side "\",\"ip\":\"" j(b[1]) "\",\"code\":\"" b[2] "\",\"n\":" n[k] "}" } }' "$TMP.win" >> "$OUT"
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / && code() != "0" { split($1, a, " ");
      print "{\"t\":\"lsnr_ref\",\"side\":\"" side "\",\"ts\":\"" a[2] "\",\"ip\":\"" j(ip()) "\",\"code\":\"" code() "\",\"cid\":\"" j(cid()) "\",\"svc\":\"" j(svc()) "\"}" }' "$TMP.win" \
    | head -500 >> "$OUT"
  if [ -n "$CIDS" ] && [ -r "$CIDS" ]; then
    awk -F'"cid":"' '/"t":"lsnr_ref"/ { split($2, a, "\""); if (a[1] != "") print a[1] }' "$CIDS" | sort -u > "$TMP.cids"
    clean < "$LSNR" | awk -F' [*] ' -v side="$SIDE" "$LAWK"'
      NR == FNR { want[$0] = 1; next }
      $0 ~ / [*] establish [*] / { c = cid(); if (c != "" && (c in want)) print "{\"t\":\"cid_hit\",\"side\":\"" side "\",\"ts\":\"" $1 "\",\"ip\":\"" j(ip()) "\",\"code\":\"" code() "\",\"cid\":\"" j(c) "\"}" }' "$TMP.cids" - \
      | head -2000 >> "$OUT"
    note "CONNECTION_ID check: $(wc -l < "$TMP.cids" | tr -d ' ') IDs from $CIDS"
  fi
  note "listener log: $LSNR"
else
  note "listener log: not found, skipped; use -l"
fi

# ---- short network check
if [ -n "$PEER" ]; then
  retr() { netstat -s 2>/dev/null | awk '/retransmitted/ && !/SynRetrans/ { n += $1 } END { print n + 0 }'; }
  sendq() { netstat -an 2>/dev/null | awk -v p="$PORT" -v peer="$PEER" '$0 ~ peer && ($4 ~ "[.:]" p "$" || $5 ~ "[.:]" p "$") { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }'; }
  PING=$(ping -c 10 "$PEER" 2>&1)
  RTT=$(echo "$PING" | awk -F'= ' '/min\/avg/ { split($2, a, "/"); print a[2]; exit }')
  LOSS=$(echo "$PING" | awk '/packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%/) { print $i; exit } }')
  R1=$(retr); MQ=0; i=0
  while [ $i -lt 5 ]; do q=$(sendq); [ "$q" -gt "$MQ" ] && MQ=$q; sleep 2; i=$((i + 1)); done
  R2=$(retr)
  printf '{"t":"net","side":"%s","peer":"%s","port":"%s","os":"%s","rtt":"%s","loss":"%s","retr":%s,"secs":10,"sendq":%s,"at":"%s"}\n' \
    "$SIDE" "$PEER" "$PORT" "$(uname)" "${RTT:-?}" "${LOSS:-?}" "$((R2 - R1))" "$MQ" "$(date '+%H:%M:%S')" >> "$OUT"
  note "network check: $PEER"
fi

echo "Bundle written: $OUT" >&2
awk -F'"t":"' 'NF > 1 { split($2, a, "\""); c[a[1]]++ } END { for (k in c) printf "  %-9s %d lines\n", k, c[k] }' "$OUT" | sort >&2
BAD=$(grep -v '^{' "$OUT" | grep -E 'ORA-|SP2-|ERROR' | head -5)
[ -n "$BAD" ] && { echo "Some queries reported errors (they are listed in the report):" >&2; echo "$BAD" | sed 's/^/  /' >&2; }
exit 0

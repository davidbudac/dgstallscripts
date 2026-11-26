#!/bin/sh
# Collect everything the HTML report needs from ONE host into one bundle file (JSON lines, format v2:
# docs/bundle-format.md). Read-only: SELECTs on the database, reads of the alert log, traces, listener log, tnsnames.ora, sqlnet.ora and
# sysstat files, and display commands (ping, netstat, sysctl, sar, chronyc ...). Nothing is installed, configured or left running.
#
# Usage: sh/collect.sh [options] primary|standby "YYYY-MM-DD HH:MI" "YYYY-MM-DD HH:MI"
#        sh/collect.sh list [-s] [-d days] [-a alert log] [-u conn] [from [to]]     past incidents, which sources on this host still hold them, and the commands to collect them
#
#   -o file    bundle to write            (default ./dgr_<side>_<host>_<now>.jsonl)
#   -u conn    sqlplus connect string     (default "/ as sysdba")
#   -t dir     trace directory            (default: "Diag Trace" from v$diag_info)
#   -a file    text alert log             (default: <trace dir>/alert_$ORACLE_SID.log)
#   -l file    listener text log          (default: found with lsnrctl status)
#   -c file    standby bundle: look up its refused CONNECTION_IDs in this listener log
#   -p ip      peer redo IP for the 10 s network check (default: derived, see README); -P port (default: derived, else 1521)
#   -n file    log of sh/net_sampler.sh: add its samples inside the window
#   -N         passive: no live network check (no ping, no netstat sampling): only logs, files and the database are read
#   -d days    how far back "earlier occurrences" and `list` look (default 30; `list` with a from time does not use it)
#   -b days    baseline: the same clock interval on each of the previous days, primary (default 7, 0 = none, at most 31)
#   -s         list only: print nothing but the commands (every standby command, then every primary command, then the reports), to save as a script
#   from, to   list only: the period to look at, each "YYYY-MM-DD", "YYYY-MM-DD HH:MI" or "YYYY-MM-DD HH:MI:SS"; a date alone is the start of that day for from
#              and the end of that day for to; to left out = now. An episode is listed when its first line is inside the period.
#
# Run it on the standby first, then on the primary with -c <standby bundle>.
# Then: sh/make_report.sh   (on any machine, in the directory that holds the bundles)
# The window may cross midnight or span days, in the hosts' local time; both ends count to the second.
# Each source gets a "cov" record (what it holds, rows in the window, caps hit). Exit status 1 = the database part failed.
# Environment: SQLPLUS = the sqlplus binary (default sqlplus); SA_DIR = sysstat directory (default /var/log/sa, /var/log/sysstat);
#              DGR_NOW = "YYYY-MM-DDTHH:MI:SS" instead of the clock (for tests); TNS_ADMIN / ORACLE_HOME locate tnsnames.ora and sqlnet.ora

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -r "$DIR/sh/dglib.sh" ] || { echo "collect.sh: $DIR/sh/dglib.sh is missing: copy the whole directory to the host" >&2; exit 1; }
. "$DIR/sh/dglib.sh"
SQLPLUS=${SQLPLUS:-sqlplus}
OUT= CONN="/ as sysdba" TRACE= ALERT= LSNR= CIDS= PEER= PORT= PORTSET=0 DAYS=30 BASE=7 SAMPLES= NONET=0 ONLYCMD=0
# options may come before, between or after the positional arguments
N=0 A1= A2= A3=
while [ $# -gt 0 ]; do
  OPTIND=1
  while getopts o:u:t:a:l:c:p:P:n:Nd:b:sh opt; do
    case $opt in
      o) OUT=$OPTARG ;; u) CONN=$OPTARG ;; t) TRACE=$OPTARG ;; a) ALERT=$OPTARG ;; l) LSNR=$OPTARG ;;
      c) CIDS=$OPTARG ;; p) PEER=$OPTARG ;; P) PORT=$OPTARG PORTSET=1 ;; n) SAMPLES=$OPTARG ;; N) NONET=1 ;; d) DAYS=$OPTARG ;; b) BASE=$OPTARG ;; s) ONLYCMD=1 ;; *) usage ;;
    esac
  done
  shift $((OPTIND - 1))
  [ $# -gt 0 ] || break
  N=$((N + 1))
  case $N in 1) A1=$1 ;; 2) A2=$1 ;; 3) A3=$1 ;; *) usage ;; esac
  shift
done
case $DAYS in ''|*[!0-9]*) echo "-d needs a number of days" >&2; exit 1 ;; esac
case $BASE in ''|*[!0-9]*) echo "-b needs a number of days (0 = no baseline)" >&2; exit 1 ;; esac
[ "$BASE" -le 31 ] || { echo "-b: at most 31 days" >&2; exit 1; }
case $PORT in *[!0-9]*) echo "-P needs a port number" >&2; exit 1 ;; esac
MODE=collect
if [ "$A1" = list ] && [ $N -le 3 ]; then MODE=list   # list [from [to]]
elif [ $N -ne 3 ]; then usage; fi
[ $MODE = list ] || [ $ONLYCMD -eq 0 ] || { echo "-s only applies to list" >&2; exit 1; }

TMP=${TMPDIR:-/tmp}/dgr.$$
trap 'rm -f "$TMP".*' 0 1 2 15
now() { if [ -n "$DGR_NOW" ]; then echo "$DGR_NOW" | tr T ' '; else date '+%Y-%m-%d %H:%M:%S'; fi; }
clean() { tr -d '\000-\010\013\014\016-\037'; }   # drop control bytes except tab, newline, CR
cutoff() { awk -v now="$(now)" -v d="$DAYS" "$DATEAWK"'BEGIN { print fmt(ep(now) - d * 86400) }'; }   # DAYS days before now (host clock time)
# What sqlplus output (stdin) says went wrong: the first ORA- or SP2- line, else the first "ERROR ..." line. "ERROR at line N:" only says where, and the bare "ERROR:" header says nothing:
# neither is picked when an ORA- or SP2- line is there. errlines N prints up to N such lines (ORA-, SP2- and TNS- lines; "ERROR ..." lines only when there are none).
errline() { awk '/ORA-|SP2-/ { print; found = 1; exit } !e && /ERROR/ && !/^ERROR:$/ { e = $0 } END { if (!found && e != "") print e }'; }
errlines() { awk -v n="$1" '/ORA-|SP2-|TNS-/ { if (a < n) p[++a] = $0; next } /ERROR/ && !/^ERROR:$/ { if (b < n) q[++b] = $0 } END { if (a) for (i = 1; i <= a; i++) print p[i]; else for (i = 1; i <= b; i++) print q[i] }'; }

# ================================================================ list: past incidents and the commands to collect them
if [ $MODE = list ]; then
  # An optional period, list [from [to]]: "YYYY-MM-DD" (the start of that day for from, the end of it for to), "YYYY-MM-DD HH:MI" or "YYYY-MM-DD HH:MI:SS"; to left out = now.
  # With a period -d is not used for the cutoff (from is); sql/list_alerts.sql takes days, so it gets the whole days from from to now, rounded up, plus 1 (LDAYS).
  PFROM= PTO= LDAYS=$DAYS
  ptime() {   # TEXT TIME-OF-DAY-OF-A-DATE: sets PT to the time as YYYY-MM-DD HH:MI:SS; says so and exits when TEXT is no time (2026-02-31 and 24:00 are none)
    case $1 in
      [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]) PT="$1 $2" ;;
      [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]) PT="$1:00" ;;
      [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) PT=$1 ;;
      *) PT= ;; esac
    if [ -n "$PT" ] && awk -v t="$PT" "$DATEAWK"'BEGIN { exit !(fmt(ep(t)) == t) }'; then return 0; fi
    echo "list: \"$1\" is not a time: use YYYY-MM-DD, \"YYYY-MM-DD HH:MI\" or \"YYYY-MM-DD HH:MI:SS\"" >&2; exit 1; }
  if [ $N -ge 2 ]; then
    ptime "$A2" 00:00:00; PFROM=$PT
    if [ $N -ge 3 ]; then ptime "$A3" 23:59:59; PTO=$PT; else PTO=$(now); fi
    awk -v a="$PFROM" -v b="$PTO" 'BEGIN { exit !(b < a) }' && { echo "list: the end of the period ($PTO) is before its start ($PFROM)" >&2; exit 1; }
    LDAYS=$(awk -v f="$PFROM" -v n="$(now)" "$DATEAWK"'BEGIN { x = ep(n) - ep(f); if (x < 0) x = 0; print int((x + 86399) / 86400) + 1 }')
    CUT=$PFROM
  else CUT=$(cutoff); fi
  # -s: every collect command carries -d so each bundle's history reaches as far back as the list did. An explicit -d N is passed on as it is (N not 30);
  # with a period only when the derived days are more than 30: the default 30 already reaches its start, and a smaller -d would shorten the history of the bundle
  CDAYS=
  if [ $ONLYCMD -eq 1 ]; then
    if [ -n "$PFROM" ]; then [ "$LDAYS" -gt 30 ] && CDAYS=$LDAYS
    elif [ "$LDAYS" -ne 30 ]; then CDAYS=$LDAYS; fi
  fi
  : > "$TMP.lst"
  if [ -n "$ALERT" ]; then
    [ -r "$ALERT" ] || { echo "list: cannot read $ALERT" >&2; exit 1; }
    SRC="text alert log $ALERT"
    # I = a line of the one pattern list (dglib.sh), S = a line that ends an UNSYNCHRONIZED period; routine RT_PMODE lines are neither
    clean < "$ALERT" | awk -v cut="$CUT" "$HISTAWK"'
      /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ { k = substr($1, 1, 10) " " substr($1, 12, 8); next }
      k >= cut { if (dghist($0)) print k "\tI\t" substr($0, 1, 200); else if (dgsync($0)) print k "\tS\t" substr($0, 1, 200) }' > "$TMP.lst"
  elif command -v "$SQLPLUS" >/dev/null 2>&1; then
    SRC="v\$diag_alert_ext"
    "$SQLPLUS" -S -L "$CONN" @"$DIR/sql/list_alerts.sql" "$LDAYS" </dev/null > "$TMP.lsq" 2>&1
    awk -F'\t' 'NF >= 3 && $1 ~ /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]$/' "$TMP.lsq" > "$TMP.lst"
    if [ ! -s "$TMP.lst" ] && grep -qE 'ORA-|SP2-|ERROR' "$TMP.lsq"; then
      echo "list: could not read v\$diag_alert_ext: $(errline < "$TMP.lsq")" >&2
      echo "list: on a standby, or when the database is not open, give the text alert log with -a <file>" >&2
      exit 1
    fi
  else
    echo "list: sqlplus not found; give the text alert log with -a <file>" >&2; exit 1
  fi
  # Which sources of this host still hold an episode: the in-memory ASH and AWR (oldest row, read once here), the sysstat daily file of each day of the window
  # (the directories and file names of the collection itself) and the alert log the episodes were read from. Anything that cannot be read is "not checked" with the reason.
  # The ASH and AWR query runs with -a as well as without it (it needs sqlplus, not v$diag_alert_ext: on a mounted standby ASH answers and AWR gives ORA-01219);
  # two small SELECTs of their own, a failed one is "not checked" with its first ORA- or SP2- line.
  LSASH= LSAWR=
  if [ $ONLYCMD -eq 1 ]; then :   # -s prints no "still held" lines: nothing to read
  elif ! command -v "$SQLPLUS" >/dev/null 2>&1; then LSASH="!sqlplus not found"; LSAWR=$LSASH
  else
    "$SQLPLUS" -S -L "$CONN" @"$DIR/sql/list_sources.sql" </dev/null > "$TMP.lss" 2>&1
    for K in ASH AWR; do
      V=$(awk -F'\t' -v k="$K" '$0 == "SRC:" k { on = 1; next } /^SRC:/ { on = 0 } on && $1 == k && NF >= 2 { print $2; exit } on && /ORA-|SP2-/ { if (e == "") e = $0 } END { if (e != "") print "!" substr(e, 1, 100) }' "$TMP.lss" | head -1)
      if [ -z "$V" ]; then V="!$(errline < "$TMP.lss" | cut -c1-100)"; [ "$V" = "!" ] && V="!no answer from sqlplus"; fi
      if [ "$K" = ASH ]; then LSASH=$V; else LSAWR=$V; fi
    done
  fi
  ltl() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }                                     # string a before b (timestamps)
  heldtxt() {   # NAME OLDEST-ROW-NAME OLDEST WINDOW-START WINDOW-END
    case $3 in
      '!'*) echo "$1: not checked (${3#!})" ;;
      -) echo "$1: holds no $2" ;;
      *) if ! ltl "$4:00" "$3"; then echo "$1: holds the whole window (oldest $2 $3)"
         elif ! ltl "$5:00" "$3"; then echo "$1: holds only the end of the window (oldest $2 $3)"
         else echo "$1: holds none of the window (oldest $2 $3)"; fi ;;
    esac; }
  systxt() {   # WINDOW-START WINDOW-END: one entry per day of the window
    out=
    for DAY in $(awk -v f="$1:00" -v t="$2:00" "$DATEAWK"'BEGIN { for (d = int(ep(f) / 86400); d <= int(ep(t) / 86400); d++) print substr(fmt(d * 86400), 1, 10) }'); do
      YMD=$(echo "$DAY" | sed 's/-//g'); DD=$(echo "$DAY" | cut -c9-10); got=; why=
      for DR in ${SA_DIR:-/var/log/sa /var/log/sysstat}; do
        for SF in "$DR/sa$YMD" "$DR/sa$DD"; do
          [ -z "$got" ] && [ -r "$SF" ] || continue
          if [ "$SF" = "$DR/sa$YMD" ]; then got="$SF"
          elif command -v sar >/dev/null 2>&1; then   # saDD is reused every month: its banner date says which day it holds
            FD=$(LC_ALL=C S_TIME_FORMAT=ISO sar -f "$SF" 2>/dev/null | head -1 | awk 'match($0, /[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]/) { print substr($0, RSTART, RLENGTH); exit }')
            if [ "$FD" = "$DAY" ]; then got="$SF"; else why="$SF is dated ${FD:-unreadable}"; fi
          else got="$SF (its month was not checked: sar not found)"; fi
        done
      done
      out="$out${out:+, }$DAY ${got:-${why:-no file in ${SA_DIR:-/var/log/sa /var/log/sysstat}}}"
    done
    echo "sysstat: $out"; }
  # from/to are set with a period only: an episode starts at a first line inside it (lines after to still extend or close an episode that is open); onlycmd = -s
  awk -v src="$SRC" -v cut="$CUT" -v now="$(now)" -v days="$DAYS" -v me="$0" -v dir="$(dirname "$0")" -v from="$PFROM" -v to="$PTO" -v onlycmd="$ONLYCMD" -v dopt="$CDAYS" "$DATEAWK"'
    function label(m,   l, r) {
      if (match(m, /ORA-[0-9]+/)) return substr(m, RSTART, RLENGTH)
      if (match(m, /TNS-[0-9]+/)) return substr(m, RSTART, RLENGTH)
      if (m ~ /Possible network disconnect/) return "possible network disconnect (standby)"
      l = "UNSYNCHRONIZED"; if (match(m, /LAD:[0-9]+/)) l = substr(m, RSTART, RLENGTH) " " l
      if (match(m, /reason[ \t]+[A-Za-z][A-Za-z ]*/)) { r = substr(m, RSTART + 6, RLENGTH - 6); sub(/^[ \t]+/, "", r); sub(/[ \t]+$/, "", r); l = l " (" r ")" }
      return l }
    function addlab(l) { if (index(labs, "|" l "|") == 0) { labs = labs l "|"; nl++ } }   # labs = "|first|second|"; the order of the log
    function dur(x,   d, h, m) { d = int(x / 86400); h = int(x % 86400 / 3600); m = int(x % 3600 / 60)
      if (d > 0) return d " d " h " h"; if (x >= 3600) return h " h " m " min"; return int(x / 60) " min" }
    # window: 5 minutes before the first line to 5 minutes after the return; 15 minutes after the last line when there is no return. When that end is more than
    # 60 minutes after the first line (a return days later, or lines chained for hours) the window ends 30 minutes after the first line instead, and the note says so.
    function closeep(   a, b, e, wa, wb, tag, shown, p, i, ls, short, c) {
      ne++; short = 0
      a = int((firstt - 300) / 60) * 60
      e = (ret != "" ? rett + 300 : lastt + 900)
      if (e - firstt > 3600) { e = firstt + 1800; short = 1 }
      b = int((e + 59) / 60) * 60
      wa = substr(fmt(a), 1, 16); wb = substr(fmt(b), 1, 16)
      tag = substr(wa, 1, 4) substr(wa, 6, 2) substr(wa, 9, 2) "_" substr(wa, 12, 2) substr(wa, 15, 2)
      ls = substr(labs, 2); shown = ""; for (i = 1; i <= 4; i++) { p = index(ls, "|"); if (p == 0) break; shown = shown (shown == "" ? "" : "; ") substr(ls, 1, p - 1); ls = substr(ls, p + 1) }
      if (nl > 4) shown = shown "; ..."
      if (onlycmd) {   # -s: keep what the command blocks of END need; the notes go on one comment line
        c = sprintf("# Episode %d: %s to %s, %d line%s: %s; window %s to %s", ne, first, (ret != "" ? ret : last), n, (n == 1 ? "" : "s"), shown, wa, wb)
        if (ret == "") c = c "; no return to SYNCHRONIZED found in the log"
        if (short) c = c "; window shortened to end 30 minutes after the first line (" dur((ret != "" ? rett : lastt) - firstt) " after it " (ret != "" ? "the destination returned" : "the last line was logged") ")"
        cm[ne] = c; cwa[ne] = wa; cwb[ne] = wb; ctag[ne] = tag
      } else {
        printf "Episode %d: %s to %s, %d line%s: %s\n", ne, first, (ret != "" ? ret : last), n, (n == 1 ? "" : "s"), shown
        if (ret != "") printf "  back to SYNCHRONIZED at %s\n", ret
        else if (short) printf "  no return to SYNCHRONIZED found in the log\n"
        else printf "  no return to SYNCHRONIZED found in the log: the suggested window ends 15 minutes after the last line\n"
        if (short) printf "  note: %s after the first line; the suggested window was shortened to end 30 minutes after it. Widen its end by hand to cover the whole period.\n", dur((ret != "" ? rett : lastt) - firstt)
        printf "  suggested window: %s to %s\n", wa, wb
        printf "  @SOURCES\t%s\t%s\n", wa, wb
        printf "  standby host: sh %s -o dgr_standby_%s.jsonl standby \"%s\" \"%s\"\n", me, tag, wa, wb
        printf "  primary host: sh %s -c dgr_standby_%s.jsonl -o dgr_primary_%s.jsonl primary \"%s\" \"%s\"\n\n", me, tag, tag, wa, wb
      }
      open = 0 }
    BEGIN { FS = "\t"
            range = (from != "" ? from " to " to : "last " days " days (since " cut ")")
            if (!onlycmd) {
              if (from != "") printf "Incidents in the %s, %s (times are the clock time of the host that wrote that log).\n", src, range
              else printf "Incidents in the %s, last %s days (since %s; times are the clock time of the host that wrote that log).\n", src, days, cut
              printf "Routine lines are left out (RT_PMODE for PRIMARY and PHYSICAL, \"reason ASYNC configuration\").\n\n" } }
    from != "" && $1 < from { next }   # the rows of v$diag_alert_ext reach a little before the period
    { t = ep($1)
      if ($2 == "I") {
        if (open && t - lastt > 900) closeep()
        if (!open) { if (to != "" && $1 > to) next; open = 1; first = $1; firstt = t; n = 0; ret = ""; labs = "|"; nl = 0 }   # no episode starts after the period
        n++; last = $1; lastt = t; ret = ""; addlab(label($3))
      } else if ($2 == "S" && open && ret == "") { ret = $1; rett = t; if (t - lastt <= 900) lastt = t } }   # a late return does not stretch the episode: the next lines start a new one
    END { if (open) closeep()
          if (onlycmd) {   # three blocks to paste on the hosts they name, or to save and run: only commands, # lines and empty lines
            if (ne == 0) { printf "# No incidents found in the %s, %s.\n", src, range; exit }
            printf "# dgstallscripts: commands for the %d episode%s found in the %s, %s.\n", ne, (ne == 1 ? "" : "s"), src, range
            print "# Times are the clock time of the host that wrote that log. Routine lines are left out."
            for (i = 1; i <= ne; i++) print cm[i]
            print "#"
            print "# 1. On the STANDBY host, in the directory that will hold the bundles:"
            for (i = 1; i <= ne; i++) printf "sh %s%s -o dgr_standby_%s.jsonl standby \"%s\" \"%s\"\n", me, (dopt == "" ? "" : " -d " dopt), ctag[i], cwa[i], cwb[i]
            print ""
            print "# 2. Copy the dgr_standby_*.jsonl files to the PRIMARY host, into the directory you run this in. Then on the PRIMARY host:"
            for (i = 1; i <= ne; i++) printf "sh %s%s -c dgr_standby_%s.jsonl -o dgr_primary_%s.jsonl primary \"%s\" \"%s\"\n", me, (dopt == "" ? "" : " -d " dopt), ctag[i], ctag[i], cwa[i], cwb[i]
            print ""
            print "# 3. With all bundles in one directory (a database host or your laptop): one report per episode"
            for (i = 1; i <= ne; i++) printf "sh %s/make_report.sh -o dgr_report_%s.html dgr_primary_%s.jsonl dgr_standby_%s.jsonl\n", dir, ctag[i], ctag[i], ctag[i]
            if (ne >= 2) {
              print ""
              print "# ... or one report that holds every episode (a selector at the top switches between them):"
              all = ""; for (i = 1; i <= ne; i++) all = all " dgr_primary_" ctag[i] ".jsonl dgr_standby_" ctag[i] ".jsonl"
              printf "sh %s/make_report.sh -o dgr_report_all.html%s\n", dir, all }
          }
          else if (ne == 0) print "No incidents found."
          else print "Run the standby command on the standby host first, copy its bundle to the primary host, then run the primary command there.\nTimes in the commands are as logged by that host; add -a <alert log>, -t, -l or -u when the defaults do not fit." }' "$TMP.lst" |
  while IFS= read -r LINE; do
    case $LINE in
      "  @SOURCES"*) WA=$(printf '%s\n' "$LINE" | cut -f2); WB=$(printf '%s\n' "$LINE" | cut -f3)
        echo "  still held on this host: $(heldtxt 'ASH (in memory)' sample "$LSASH" "$WA" "$WB"); $(heldtxt AWR snapshot "$LSAWR" "$WA" "$WB"); $(systxt "$WA" "$WB"); alert log: holds the episode (read from $SRC)" ;;
      *) printf '%s\n' "$LINE" ;;
    esac
  done
  exit 0
fi

SIDE=$A1
case $SIDE in primary|standby) ;; *) usage ;; esac
set -- "$A1" "$A2" "$A3"
norm() { case "$1" in
  [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]) echo "$1:00" ;;
  [12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\ [0-2][0-9]:[0-5][0-9]:[0-5][0-9]) echo "$1" ;;
  *) echo "" ;; esac; }
F=$(norm "$2"); T=$(norm "$3")
[ -n "$F" ] && [ -n "$T" ] || { echo "Times must look like \"2026-11-13 20:35\"" >&2; exit 1; }
awk -v a="$F" -v b="$T" 'BEGIN { exit !(a < b) }' || { echo "The end of the window must be after its start" >&2; exit 1; }
HOST=$(hostname | cut -d. -f1)
COLLECTED=$(now)
OUT=${OUT:-./dgr_${SIDE}_${HOST}_$(date +%Y%m%d_%H%M%S).jsonl}
OS=$(uname 2>/dev/null)
note() { echo "  $*" >&2; }
FAIL=0

# portable JSON string escaping for awk (no gsub backslash tricks)
JFN='function j(s,   o, i, c) { o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1);
       if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else if (c == "\t") o = o "\\t";
       else if (c == "\n") o = o "\\n"; else if (c != "\r") o = o c } return o }'
kv() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$2" 2>/dev/null; }   # key=value stats files
okempty() { if [ "${1:-0}" -gt 0 ]; then echo ok; else echo empty; fi; }
over() { if [ "${1:-0}" -gt "$2" ]; then echo 1; else echo 0; fi; }                               # 1 when n exceeds the cap
have() { command -v "$1" >/dev/null 2>&1; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }                                       # string a before b (timestamps)
# cov SRC STATUS FIRST LAST N CAP CAPPED(0|1) NOTE [EXTRA]: one coverage record for this side. FIRST/LAST/CAP empty = null.
# st: ok (rows in the window) | empty (read fine, none in the window) | error (read failed) | skipped (not read)
# Sources read "as collected" (not tied to the window) have first = last = the collection time.
cov() {
  COVNOTE=$8 awk -v side="$SIDE" -v src="$1" -v st="$2" -v fi="$3" -v la="$4" -v n="$5" -v cap="$6" -v capped="$7" -v x="$9" "$JFN"'
    function q(s) { return s == "" ? "null" : "\"" j(s) "\"" }
    BEGIN { printf "{\"t\":\"cov\",\"side\":\"%s\",\"src\":\"%s\"%s,\"st\":\"%s\",\"first\":%s,\"last\":%s,\"n\":%d,\"cap\":%s,\"capped\":%s,\"note\":\"%s\"}\n",
            side, src, x, st, q(fi), q(la), n, (cap == "" ? "null" : cap), (capped == 1 ? "true" : "false"), j(ENVIRON["COVNOTE"]) }' >> "$OUT"
}

echo "Collecting $SIDE data for $F -> $T into $OUT" >&2
printf '{"t":"bundle","side":"%s","host":"%s","from":"%s","to":"%s","collected":"%s","cidcheck":"%s","v":2}\n' \
  "$SIDE" "$HOST" "$F" "$T" "$COLLECTED" "$([ -n "$CIDS" ] && echo yes || echo no)" > "$OUT"

# ---- database
DBWHY=
if have "$SQLPLUS"; then
  if [ -z "$TRACE" ]; then
    TQ=$("$SQLPLUS" -S -L "$CONN" <<'EOF' 2>/dev/null | awk 'NF { print; exit }'
set heading off feedback off pagesize 0 verify off
select value from v$diag_info where name = 'Diag Trace';
exit
EOF
)
    case $TQ in /*) TRACE=$TQ ;; esac   # a failed connect prints an error line here: never use that as the directory
  fi
  "$SQLPLUS" -S -L "$CONN" @"$DIR/sql/json_$SIDE.sql" "$F" "$T" "$DAYS" "$BASE" "$OUT" </dev/null > "$TMP.sql" 2>&1
  RC=$?
  if grep '"t":"meta"' "$OUT" | grep -q "\"side\":\"$SIDE\""; then
    note "database: done"
    cov database ok "" "" 1 "" 0 "sqlplus connected, meta written"
  else
    E=$({ cat "$TMP.sql"; grep -v '^{' "$OUT"; } | errlines 3 | tr '\n' '|' | sed 's/|$//; s/|/ | /g')
    [ -n "$E" ] || E=$(grep . "$TMP.sql" | head -3 | tr '\n' '|' | sed 's/|$//; s/|/ | /g')
    [ -n "$E" ] || E="sqlplus exit $RC, no output"
    echo "database: FAILED: $E" >&2
    cov database error "" "" 0 "" 0 "$E"
    DBWHY="database: FAILED"; FAIL=1
  fi
else
  note "database: sqlplus not found, skipped"
  cov database skipped "" "" 0 "" 0 "sqlplus not found"
  DBWHY="sqlplus not found"
fi
# Sources the SQL writes: a source without a record after sqlplus ran means its statement failed. Sources of the other side are skipped.
# src act is one source with a coverage record per kind (rman, job, logsw): ACTSQL = the kinds the SQL of this side writes, ACTOTHER = the kinds it does not
if [ "$SIDE" = primary ]; then
  SQLSRC="ash awr_snap sysmetric lfs lfs_by aas ashgap wl_hist tx alert_sql alhist alsync dgstatus dest_hist base_hist"; OTHERSRC="rfs_ev rfs_hist dgproc archgap"
  ACTSQL="rman job logsw"; ACTOTHER=
else
  SQLSRC="ash ashgap tx rfs_ev rfs_hist dgstatus dgproc archgap"; OTHERSRC="awr_snap sysmetric lfs lfs_by aas wl_hist alert_sql dest_hist base_hist"
  ACTSQL="rman"; ACTOTHER="job logsw"
fi
srccap() { case $SIDE:$1 in *:alhist|*:alsync) echo 300 ;; *:lfs) echo 200 ;; *:lfs_by) echo 15 ;; *:aas) echo 12 ;; *:wl_hist) echo 1500 ;; *:ashgap) echo 50 ;; *:dgstatus) echo 500 ;; standby:tx) echo 5000 ;; esac; }
srckind() { case $SIDE:$1 in primary:alhist|primary:alsync) echo ',"kind":"sql"' ;; standby:ash) echo ',"kind":"V"' ;; esac; }
actcap() { case $1 in rman) echo 500 ;; job) echo 2000 ;; logsw) echo 5000 ;; esac; }
ERR1=$(grep -v '^{' "$OUT" | errline | cut -c1-200)
for s in $SQLSRC; do
  [ "$SIDE" = standby ] && { [ "$s" = alhist ] || [ "$s" = alsync ]; } && continue
  CAP=$(srccap $s); X=$(srckind $s)
  if [ -n "$DBWHY" ]; then cov $s skipped "" "" 0 "$CAP" 0 "$DBWHY" "$X"
  elif ! grep -q "\"t\":\"cov\",\"side\":\"$SIDE\",\"src\":\"$s\"" "$OUT"; then cov $s error "" "" 0 "$CAP" 0 "no coverage record: ${ERR1:-statement not run}" "$X"; fi
done
for k in $ACTSQL; do   # the act kinds are looked up by (src, kind): the three of the primary have a statement and a coverage record each
  CAP=$(actcap $k); X=",\"kind\":\"$k\""
  if [ -n "$DBWHY" ]; then cov act skipped "" "" 0 "$CAP" 0 "$DBWHY" "$X"
  elif ! grep -q "\"t\":\"cov\",\"side\":\"$SIDE\",\"src\":\"act\",\"kind\":\"$k\"" "$OUT"; then cov act error "" "" 0 "$CAP" 0 "no coverage record: ${ERR1:-statement not run}" "$X"; fi
done
for s in $OTHERSRC; do cov $s skipped "" "" 0 "" 0 "not collected on the $SIDE"; done
for k in $ACTOTHER; do cov act skipped "" "" 0 "" 0 "not collected on the $SIDE" ",\"kind\":\"$k\""; done

# ---- alert log text file (the standby cannot read it through SQL while mounted)
ALOFF= ALCHG=0
if [ "$SIDE" = standby ] || [ -n "$ALERT" ]; then
  ALERT=${ALERT:-$TRACE/alert_${ORACLE_SID:-unknown}.log}
  if [ -r "$ALERT" ]; then
    : > "$TMP.alh"; : > "$TMP.als"
    CUT=$(cutoff)
    clean < "$ALERT" | awk -v f="$F" -v t="$T" -v side="$SIDE" -v cut="$CUT" -v st="$TMP.al" -v alh="$TMP.alh" -v als="$TMP.als" "$JFN$HISTAWK"'
      function flush() { if (inwin && msg != "") { n++; print "{\"t\":\"alert\",\"side\":\"" side "\",\"ts\":\"" ts "\",\"msg\":\"" j(substr(msg, 1, 2000)) "\"}" } msg = "" }
      /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:/ { flush(); k = substr($1, 1, 10) " " substr($1, 12, 8)
          ts = k; if (substr($1, 20, 1) == ".") ts = k substr($1, 20, 4)
          inwin = (k >= f && k <= t); if (fts == "" || k < fts) fts = k; if (k > lts) lts = k
          if (k >= cut && (hfts == "" || k < hfts)) hfts = k
          o = substr($1, length($1) - 5)
          if (inwin && o ~ /^[+-][0-9][0-9]:[0-9][0-9]$/) { if (off == "") off = o; else if (o != off) chg = 1 }
          next }
      k >= cut { if (dghist($0)) { if (k != lastk) { h++; print "{\"t\":\"alhist\",\"side\":\"" side "\",\"ts\":\"" k "\",\"msg\":\"" j(substr($0, 1, 300)) "\"}" > alh } lastk = k }
                 else if (dgsync($0)) { if (k != lasts) { sn++; print "{\"t\":\"alsync\",\"side\":\"" side "\",\"ts\":\"" k "\",\"msg\":\"" j(substr($0, 1, 200)) "\"}" > als } lasts = k } }
      inwin { msg = (msg == "" ? $0 : msg "\n" $0) }
      END { flush(); printf "first=%s\nlast=%s\nn=%d\nhist=%d\nsync=%d\noff=%s\nchg=%d\nhfirst=%s\n", fts, lts, n, h, sn, off, chg, hfts > st }' >> "$OUT"
    NA=$(kv n "$TMP.al"); NH=$(kv hist "$TMP.al"); NS=$(kv sync "$TMP.al"); AF=$(kv first "$TMP.al"); AL=$(kv last "$TMP.al"); HF=$(kv hfirst "$TMP.al")
    ALOFF=$(kv off "$TMP.al"); ALCHG=$(kv chg "$TMP.al")
    tail -300 "$TMP.alh" >> "$OUT"
    tail -300 "$TMP.als" >> "$OUT"
    cov alert_text "$(okempty "$NA")" "$AF" "$AL" "${NA:-0}" "" 0 "$ALERT"
    cov alhist "$(okempty "$NH")" "$HF" "$AL" "${NH:-0}" 300 "$(over "$NH" 300)" "text alert log, last $DAYS days (since $CUT), newest 300 kept; routine RT_PMODE lines (PRIMARY, PHYSICAL, reason ASYNC configuration) excluded" ',"kind":"text"'
    cov alsync "$(okempty "$NS")" "$HF" "$AL" "${NS:-0}" 300 "$(over "$NS" 300)" "text alert log, last $DAYS days (since $CUT), newest 300 kept; lines that end an UNSYNCHRONIZED period (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)" ',"kind":"text"'
    note "alert log: $ALERT"
  else
    note "alert log: not readable ($ALERT), skipped; use -a"
    cov alert_text skipped "" "" 0 "" 0 "not readable: $ALERT; use -a"
    cov alhist skipped "" "" 0 300 0 "alert log not readable: $ALERT" ',"kind":"text"'
    cov alsync skipped "" "" 0 300 0 "alert log not readable: $ALERT" ',"kind":"text"'
  fi
else
  cov alert_text skipped "" "" 0 "" 0 "not requested; pass -a to read the text alert log"
fi

# ---- background traces
if [ -n "$TRACE" ] && [ -d "$TRACE" ]; then
  tfiles() { find "$TRACE" -type f \( -name '*_lgwr_*.trc' -o -name '*_nss*_*.trc' -o -name '*_tt0*_*.trc' \
               -o -name '*_arc*_*.trc' -o -name '*_tmon_*.trc' -o -name '*_rfs_*.trc' -o -name '*_mrp0_*.trc' \) "$@" 2>/dev/null; }
  FILES=$(tfiles -mtime -45)
  NFILES=$(printf '%s\n' "$FILES" | grep -c .)
  : > "$TMP.trs"
  for fl in $FILES; do
    clean < "$fl" | awk -v f="$F" -v t="$T" -v fn="$(basename "$fl")" -v side="$SIDE" -v st="$TMP.trs" "$JFN"'
      $1 == "***" && $2 ~ /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T/ {
          k = substr($2, 1, 10) " " substr($2, 12, 8); ts = k; if (substr($2, 20, 1) == ".") ts = k substr($2, 20, 4)
          inwin = (k >= f && k <= t); if (fts == "" || k < fts) fts = k; if (k > lts) lts = k; next }
      inwin && /ORA-|TNS-|nt main err|nt secondary err|ns secondary err|nt OS err|[Tt]ime[d ]*out|[Ee]rror/ {
          print ts "\t{\"t\":\"trace\",\"side\":\"" side "\",\"ts\":\"" ts "\",\"file\":\"" fn "\",\"msg\":\"" j(substr($0, 1, 400)) "\"}" }
      END { if (fts != "") print fts "\t" lts >> st }'
  done | LC_ALL=C sort > "$TMP.tr"
  NT=$(wc -l < "$TMP.tr" | tr -d ' ')
  head -400 "$TMP.tr" | cut -f2- >> "$OUT"
  TNOTE="files modified in the last 45 days" CAPPED=0
  [ "$NT" -gt 400 ] && { TNOTE="$TNOTE; first 400 lines by time kept"; CAPPED=1; }
  # a file older than that can still hold the window when the window starts before the limit
  if touch -t "$(echo "$F" | cut -c1-4,6-7,9-10,12-13,15-16)" "$TMP.from" 2>/dev/null \
     && [ -n "$(tfiles -newer "$TMP.from" ! -mtime -45 | head -1)" ]; then
    TNOTE="$TNOTE; the window starts before that limit, older files were not scanned"; CAPPED=1
  fi
  cov trace "$(okempty "$NT")" "$(cut -f1 "$TMP.trs" | LC_ALL=C sort | head -1)" "$(cut -f2 "$TMP.trs" | LC_ALL=C sort | tail -1)" "$NT" 400 "$CAPPED" "$TNOTE" ",\"files\":$NFILES"
  note "traces: $TRACE"
else
  note "traces: directory not found, skipped; use -t"
  cov trace skipped "" "" 0 400 0 "directory not found: ${TRACE:-none}; use -t" ',"files":0'
fi

# ---- listener log
LST=   # lsnrctl status: the listener log when -l is not given, the standby's listener port when -P is not given
if have lsnrctl && { [ -z "$LSNR" ] || { [ "$SIDE" = standby ] && [ "$PORTSET" = 0 ]; }; }; then LST=$(lsnrctl status 2>/dev/null); fi
if [ -z "$LSNR" ] && [ -n "$LST" ]; then
  X=$(echo "$LST" | awk '/Listener Log File/ { print $NF; exit }')
  ALIAS=$(echo "$LST" | awk '/^Alias/ { print tolower($2); exit }')
  case $X in
    */alert/log.xml) D=${X%/alert/log.xml}/trace
                     if [ -r "$D/${ALIAS:-listener}.log" ]; then LSNR=$D/${ALIAS:-listener}.log
                     else LSNR=$(ls -t "$D"/*.log 2>/dev/null | head -1); fi ;;
    *.log) LSNR=$X ;;
  esac
fi
LSOFF= LSCHG=0 SRVIP= SRVHOW=
if [ -n "$LSNR" ] && [ -r "$LSNR" ]; then
  # lines look like "13-NOV-2026 20:38:19 * ..."; lkey turns the date into 'YYYY-MM-DD HH:MI:SS' so windows can cross days
  LAWK="$JFN"'
    function code(   c) { c = $NF; gsub(/[^0-9]/, "", c); return c }
    function ip() { if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)/)) { s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); return s } return "" }
    function port() { if (match($0, /\(ADDRESS=\(PROTOCOL=[A-Za-z]*\)\(HOST=[^)]*\)\(PORT=[0-9]+\)/)) { s = substr($0, RSTART, RLENGTH); sub(/.*PORT=/, "", s); sub(/\)$/, "", s); return s } return "" }
    function chost() { if (match($0, /\(CID=\(PROGRAM=[^)]*\)\(HOST=[^)]*\)/)) { s = substr($0, RSTART, RLENGTH); sub(/.*HOST=/, "", s); sub(/\)$/, "", s); return s } return "" }
    function cid() { if (match($0, /CONNECTION_ID=[^)]*/)) return substr($0, RSTART + 14, RLENGTH - 14); return "" }
    function svc() { if (match($0, /SERVICE_NAME=[^)]*/)) return substr($0, RSTART + 13, RLENGTH - 13); if (match($0, /SID=[^)]*/)) return "SID:" substr($0, RSTART + 4, RLENGTH - 4); return "" }
    function lkey(s,   p, m) { split(s, p, " "); if (p[1] !~ /^[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]$/ || p[2] !~ /^[0-2][0-9]:[0-5][0-9]:[0-5][0-9]/) return ""
        m = mon[substr(p[1], 4, 3)]; if (m == "") return ""; return substr(p[1], 8, 4) "-" m "-" substr(p[1], 1, 2) " " substr(p[2], 1, 8) }
    BEGIN { nm = split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC", mo, " "); for (i = 1; i <= nm; i++) mon[mo[i]] = sprintf("%02d", i) }'
  # a classic line has no offset; the ISO line before it does ("2026-11-21T09:01:46.464031+00:00")
  # a server-to-server connection (redo transport, FAL, broker; also a database link) carries PROGRAM=oracle; the newest one anywhere in the log is kept for the peer address
  clean < "$LSNR" | awk -v f="$F" -v t="$T" -v st="$TMP.ls" "$LAWK"'
    /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]/ {
        k = substr($1, 1, 10) " " substr($1, 12, 8); o = substr($1, length($1) - 5)
        if (k >= f && k <= t && o ~ /^[+-][0-9][0-9]:[0-9][0-9]$/) { if (off == "") off = o; else if (o != off) chg = 1 }
        next }
    { k = lkey($0); if (k == "") next; if (fts == "" || k < fts) fts = k; if (k > lts) lts = k
      if ($0 ~ / [*] establish [*] / && $0 ~ /\(PROGRAM=oracle\)/) { oip = ip(); ots = k }
      if (k >= f && k <= t) { n++; print } }
    END { printf "first=%s\nlast=%s\nn=%d\noff=%s\nchg=%d\norip=%s\norts=%s\n", fts, lts, n, off, chg, oip, ots > st }' > "$TMP.win"
  LN=$(kv n "$TMP.ls"); LF=$(kv first "$TMP.ls"); LL=$(kv last "$TMP.ls"); LSOFF=$(kv off "$TMP.ls"); LSCHG=$(kv chg "$TMP.ls")
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / { n[substr(lkey($1), 1, 16) "|" code()]++ }
    END { for (k in n) { split(k, b, "|"); print "{\"t\":\"lsnr\",\"side\":\"" side "\",\"m\":\"" b[1] "\",\"code\":\"" b[2] "\",\"n\":" n[k] "}" } }' "$TMP.win" | LC_ALL=C sort >> "$OUT"
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / { n[ip() "|" code()]++ }
    END { for (k in n) { split(k, b, "|"); print "{\"t\":\"lsnr_ip\",\"side\":\"" side "\",\"ip\":\"" j(b[1]) "\",\"code\":\"" b[2] "\",\"n\":" n[k] "}" } }' "$TMP.win" | LC_ALL=C sort >> "$OUT"
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / && code() != "0" {
      print "{\"t\":\"lsnr_ref\",\"side\":\"" side "\",\"ts\":\"" lkey($1) "\",\"ip\":\"" j(ip()) "\",\"code\":\"" code() "\",\"cid\":\"" j(cid()) "\",\"svc\":\"" j(svc()) "\"}" }' "$TMP.win" > "$TMP.ref"
  NREF=$(wc -l < "$TMP.ref" | tr -d ' ')
  head -500 "$TMP.ref" >> "$OUT"
  cov listener "$(okempty "$LN")" "$LF" "$LL" "${LN:-0}" "" 0 "$LSNR"
  cov lsnr_ref "$(okempty "$NREF")" "$LF" "$LL" "$NREF" 500 "$(over "$NREF" 500)" "refused establish lines in the window"
  # server-to-server connections in the window: who connected from the other database host, from which address and port, and with which result
  awk -F' [*] ' -v side="$SIDE" "$LAWK"'
    $0 ~ / [*] establish [*] / && $0 ~ /\(PROGRAM=oracle\)/ {
      p = port(); print "{\"t\":\"lsnr_srv\",\"side\":\"" side "\",\"ts\":\"" lkey($1) "\",\"host\":\"" j(chost()) "\",\"ip\":\"" j(ip()) "\",\"port\":" (p == "" ? "null" : p) ",\"svc\":\"" j(svc()) "\",\"code\":\"" code() "\"}" }' "$TMP.win" > "$TMP.srv"
  NSRV=$(wc -l < "$TMP.srv" | tr -d ' ')
  head -500 "$TMP.srv" >> "$OUT"
  cov lsnr_srv "$(okempty "$NSRV")" "$LF" "$LL" "$NSRV" 500 "$(over "$NSRV" 500)" "establish lines with PROGRAM=oracle (an Oracle server process as the client: normally the other database host for redo transport, FAL or the broker, but database links match too) in the window"
  # the address that connected most often in the window (ties: the lowest); else the newest one anywhere in the log
  if [ "$NSRV" -gt 0 ]; then
    SRVIP=$(awk -F'"ip":"' '{ split($2, a, "\""); c[a[1]]++ } END { for (k in c) if (k != "" && (c[k] > m || (c[k] == m && k < b))) { m = c[k]; b = k } print b }' "$TMP.srv")
    SRVHOW="listener log $LSNR: the address of the PROGRAM=oracle connections in the window ($(grep -c "\"ip\":\"$SRVIP\"" "$TMP.srv") of $NSRV)"
  else
    SRVIP=$(kv orip "$TMP.ls")
    [ -n "$SRVIP" ] && SRVHOW="listener log $LSNR: the newest PROGRAM=oracle connection in the log ($(kv orts "$TMP.ls")); none in the window"
  fi
  if [ -n "$CIDS" ] && [ -r "$CIDS" ]; then
    awk -F'"cid":"' '/"t":"lsnr_ref"/ { split($2, a, "\""); if (a[1] != "") print a[1] }' "$CIDS" | sort -u > "$TMP.cids"
    NCID=$(wc -l < "$TMP.cids" | tr -d ' ')
    NHIT=0
    if [ "$NCID" -gt 0 ]; then
      clean < "$LSNR" | awk -F' [*] ' -v side="$SIDE" "$LAWK"'
        NR == FNR { want[$0] = 1; next }
        $0 ~ / [*] establish [*] / { c = cid(); if (c != "" && (c in want)) print "{\"t\":\"cid_hit\",\"side\":\"" side "\",\"ts\":\"" lkey($1) "\",\"ip\":\"" j(ip()) "\",\"code\":\"" code() "\",\"cid\":\"" j(c) "\"}" }' "$TMP.cids" - > "$TMP.hit"
      NHIT=$(wc -l < "$TMP.hit" | tr -d ' ')
      head -2000 "$TMP.hit" >> "$OUT"
    fi
    note "CONNECTION_ID check: $NCID IDs from $CIDS"
    cov cid "$(okempty "$NHIT")" "$LF" "$LL" "$NHIT" 2000 "$(over "$NHIT" 2000)" "$NCID CONNECTION_IDs looked up in the whole log"
  elif [ -n "$CIDS" ]; then
    cov cid skipped "" "" 0 2000 0 "cannot read $CIDS"
  else
    cov cid skipped "" "" 0 2000 0 "option -c not given"
  fi
  note "listener log: $LSNR"
else
  note "listener log: not found, skipped; use -l"
  cov listener skipped "" "" 0 "" 0 "listener log not found; use -l"
  cov lsnr_ref skipped "" "" 0 500 0 "listener log not found; use -l"
  cov lsnr_srv skipped "" "" 0 500 0 "listener log not found; use -l"
  cov cid skipped "" "" 0 2000 0 "listener log not found; use -l"
fi

# ---- endpoints: the address redo travels on, as configured (the destination alias resolved through tnsnames.ora; on the standby the fal_server aliases)
TNSF= SQLNF= NETDIRS=
for d in "$TNS_ADMIN" "${ORACLE_HOME:+$ORACLE_HOME/network/admin}"; do
  [ -n "$d" ] || continue
  NETDIRS="$NETDIRS${NETDIRS:+, }$d"
  [ -z "$TNSF" ] && [ -r "$d/tnsnames.ora" ] && TNSF=$d/tnsnames.ora
  [ -z "$SQLNF" ] && [ -r "$d/sqlnet.ora" ] && SQLNF=$d/sqlnet.ora
done
{ sed -n 's/.*"t":"dest".*"id":\([0-9]*\),"dest":"\([^"]*\)".*/\1|\2|v$archive_dest/p' "$OUT"
  sed -n 's/.*"name":"fal_server","value":"\([^"]*\)".*/\1/p' "$OUT" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . | sed 's/^/|/; s/$/|fal_server/'; } > "$TMP.alias"
: > "$TMP.ep"
if [ -s "$TMP.alias" ]; then
  # RESOLVE: alias, easy connect string or descriptor -> host, port, number of ADDRESS entries, how (tab separated; empty when unknown)
  RESOLVE='
    function base(s,   i) { i = index(s, "."); return i ? substr(s, 1, i - 1) : s }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function parse(txt, how,   t, n, h, p) {
      t = txt; n = 0; while (match(t, /[Aa][Dd][Dd][Rr][Ee][Ss][Ss][ \t]*=/)) { n++; t = substr(t, RSTART + RLENGTH) }
      h = ""; if (match(txt, /[Hh][Oo][Ss][Tt][ \t]*=[ \t]*[^) \t]+/)) { h = substr(txt, RSTART, RLENGTH); sub(/^[^=]*=[ \t]*/, "", h) }
      p = ""; if (match(txt, /[Pp][Oo][Rr][Tt][ \t]*=[ \t]*[0-9]+/)) { p = substr(txt, RSTART, RLENGTH); sub(/^[^=]*=[ \t]*/, "", p) }
      printf "%s\t%s\t%d\t%s\n", h, p, n, how }
    BEGIN {
      if (want ~ /\(/) { parse(want, "descriptor given as the destination"); exit }
      if (want ~ /[:\/]/) { s = want; sub(/^\/\//, "", s); h = s; sub(/[:\/].*/, "", h); p = ""
        if (match(s, /:[0-9]+/)) p = substr(s, RSTART + 1, RLENGTH - 1); if (p == "") p = 1521
        printf "%s\t%s\t1\teasy connect string given as the destination\n", h, p; exit }
      if (file == "") exit
      w = tolower(want); hit = 0; txt = ""
      while ((getline line < file) > 0) {
        sub(/#.*/, "", line)
        if (line ~ /^[A-Za-z0-9_.$-]/ && line ~ /[=]/) {
          if (hit) break
          nm = line; sub(/[=].*/, "", nm); k = split(nm, al, ","); for (i = 1; i <= k; i++) { a = tolower(trim(al[i])); if (a == w || base(a) == base(w)) hit = 1 }
          if (hit) { txt = line; sub(/^[^=]*=/, "", txt) }
        } else if (hit) txt = txt " " line }
      close(file)
      if (hit) parse(txt, "alias " want " in " file) }'
  while IFS='|' read -r EID EAL EFROM; do
    R=$(awk -v want="$EAL" -v file="$TNSF" "$RESOLVE" </dev/null)
    EH=$(echo "$R" | cut -f1); EP=$(echo "$R" | cut -f2); EN=$(echo "$R" | cut -f3); EHOW=$(echo "$R" | cut -f4)
    EIP= EIPHOW= ENOTE=
    if [ -z "$EH" ]; then
      if [ -z "$TNSF" ]; then ENOTE="no tnsnames.ora under TNS_ADMIN or ORACLE_HOME/network/admin (${NETDIRS:-neither is set}): the alias was not resolved"
      else ENOTE="alias not found in $TNSF"; fi
    else
      case $EH in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) EIP=$EH EIPHOW="address given in the descriptor" ;;
        *) if have getent; then EIP=$(getent hosts "$EH" 2>/dev/null | awk 'NR == 1 { print $1 }'); [ -n "$EIP" ] && EIPHOW="getent hosts $EH" || ENOTE="getent hosts did not resolve $EH"
           else ENOTE="getent not found: host name not resolved"; fi ;;
      esac
    fi
    ENOTE="${EHOW:+$EHOW}${EHOW:+${ENOTE:+; }}$ENOTE"
    ENOTE=$ENOTE awk -v side="$SIDE" -v from="$EFROM" -v dest="$EID" -v alias="$EAL" -v file="$TNSF" -v host="$EH" -v port="$EP" -v addrs="$EN" -v ip="$EIP" -v iphow="$EIPHOW" "$JFN"'
      function q(s) { return s == "" ? "null" : "\"" j(s) "\"" }
      BEGIN { printf "{\"t\":\"ep\",\"side\":\"%s\",\"from\":%s,\"dest\":%s,\"alias\":%s,\"file\":%s,\"host\":%s,\"port\":%s,\"addrs\":%s,\"ip\":%s,\"ip_how\":%s,\"note\":%s}\n",
              side, q(from), (dest == "" ? "null" : dest), q(alias), q(file), q(host), (port == "" ? "null" : port), (addrs == "" ? "null" : addrs), q(ip), q(iphow), q(ENVIRON["ENOTE"]) }' >> "$OUT"
    [ -n "$EIP" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$EFROM" "$EAL" "$EH" "$EP" "$EIP" "$EIPHOW" >> "$TMP.ep"
  done < "$TMP.alias"
  NEP=$(wc -l < "$TMP.alias" | tr -d ' ')
  cov ep ok "$COLLECTED" "$COLLECTED" "$NEP" "" 0 "destination and fal_server aliases as configured, resolved through ${TNSF:-no tnsnames.ora}; as collected, first = last = collection time"
else
  cov ep skipped "" "" 0 "" 0 "no destination or fal_server alias known${DBWHY:+ ($DBWHY)}"
fi

# ---- timeout settings: sqlnet.ora and the OS TCP tunables, as collected
if [ -z "$NETDIRS" ]; then
  cov sqlnet skipped "" "" 0 "" 0 "neither TNS_ADMIN nor ORACLE_HOME is set: sqlnet.ora not located"
else
  awk -v side="$SIDE" -v file="$SQLNF" "$JFN"'
    function q(s) { return s == "" ? "null" : "\"" j(s) "\"" }
    BEGIN { np = split("SQLNET.EXPIRE_TIME SQLNET.OUTBOUND_CONNECT_TIMEOUT SQLNET.INBOUND_CONNECT_TIMEOUT SQLNET.RECV_TIMEOUT SQLNET.SEND_TIMEOUT TCP.CONNECT_TIMEOUT", P, " ")
      if (file != "") while ((getline line < file) > 0) { sub(/#.*/, "", line)
        if (match(line, /^[ \t]*[A-Za-z_.]+[ \t]*=/)) { nm = substr(line, RSTART, RLENGTH); v = substr(line, RSTART + RLENGTH); sub(/[ \t]*=$/, "", nm); sub(/^[ \t]+/, "", nm)
          sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); V[toupper(nm)] = v } }
      for (i = 1; i <= np; i++) printf "{\"t\":\"sqlnet\",\"side\":\"%s\",\"name\":\"%s\",\"set\":%s,\"value\":%s,\"file\":%s}\n", side, P[i], ((P[i] in V) ? "true" : "false"), ((P[i] in V) ? q(V[P[i]]) : "null"), q(file) }' </dev/null >> "$OUT"
  cov sqlnet ok "$COLLECTED" "$COLLECTED" 6 "" 0 "${SQLNF:+$SQLNF; }${SQLNF:-no sqlnet.ora under $NETDIRS: every parameter is at its default}"
fi
case $OS in
  Linux)
    : > "$TMP.os"
    if have sysctl; then
      for tn in net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.tcp_retries2; do
        printf '%s\t%s\tsysctl -n\n' "$tn" "$(sysctl -n "$tn" 2>/dev/null | head -1)" >> "$TMP.os"
      done
    fi ;;
  AIX)
    # the same tunables sh/os_net_check.sh reads; AIX reports tcp_keepidle and tcp_keepintvl in half seconds
    no -a 2>/dev/null | grep -E 'tcp_keep|tcp_sendspace|tcp_recvspace|rfc1323|sb_max' | awk '{ v = $0; sub(/^[^=]*=[ \t]*/, "", v); printf "%s\t%s\tno -a\n", $1, v }' > "$TMP.os" ;;
  *) : > "$TMP.os" ;;
esac
if [ -s "$TMP.os" ]; then
  awk -F'\t' -v side="$SIDE" "$JFN"'{ printf "{\"t\":\"ostcp\",\"side\":\"%s\",\"name\":\"%s\",\"value\":%s,\"tool\":%s}\n", side, j($1), ($2 == "" ? "null" : "\"" j($2) "\""), ($3 == "" ? "null" : "\"" j($3) "\"") }' "$TMP.os" >> "$OUT"
  cov ostcp ok "$COLLECTED" "$COLLECTED" "$(wc -l < "$TMP.os" | tr -d ' ')" "" 0 "$OS TCP tunables as collected; value null = not readable here"
else
  case $OS in Linux) OSWHY="sysctl not found" ;; AIX) OSWHY="no -a gave nothing (no, the AIX tuning command, not found or not allowed)" ;; *) OSWHY="no TCP tunables are read on ${OS:-this OS} (Linux: sysctl, AIX: no -a)" ;; esac
  cov ostcp skipped "" "" 0 "" 0 "$OSWHY"
fi

# ---- clock synchronisation state as collected (chronyc, else ntpq, else timedatectl; AIX: ntpq, else lssrc)
NTPREC= NTPWHY=
ntp_chrony() { have chronyc || { NTPWHY="chronyc not found"; return 1; }
  chronyc tracking 2>&1 | awk -v side="$SIDE" "$JFN"'
    function v(s) { sub(/^[^:]*:[ \t]*/, "", s); return s }
    /^Reference ID/ { ref = v($0); if (match(ref, /\(.*\)/)) src = substr(ref, RSTART + 1, RLENGTH - 2); else src = ref; if (ref ~ /^0+ /) src = "" }
    /^Stratum/ { st = v($0) + 0 }
    /^System time/ { o = v($0); split(o, a, " "); off = a[1] + 0; if (o ~ /slow/) off = -off; hasoff = 1 }
    /^Leap status/ { leap = v($0); gsub(/[ \t]+$/, "", leap) }
    END { if (leap == "" && st == "") exit 1
          sy = (leap != "Not synchronised" && st >= 1 && st <= 15) ? "yes" : "no"
          printf "{\"t\":\"ntp\",\"side\":\"%s\",\"tool\":\"chronyc tracking\",\"ref\":%s,\"stratum\":%d,\"off\":%s,\"synced\":\"%s\",\"note\":\"leap status: %s; off = system clock minus NTP time, seconds, positive = ahead; null when not synchronised\"}\n",
                 side, (src == "" ? "null" : "\"" j(src) "\""), st, (hasoff && sy == "yes" ? sprintf("%.9f", off) : "null"), sy, j(leap) }' > "$TMP.ntp" || { NTPWHY="chronyc gave no tracking data"; return 1; }
  [ -s "$TMP.ntp" ]; }
ntp_ntpq() { have ntpq || { NTPWHY="${NTPWHY:+$NTPWHY; }ntpq not found"; return 1; }
  ntpq -p 2>&1 | awk -v side="$SIDE" "$JFN"'
    /^[ \t]*remote[ \t]+refid/ { seen = 1 }
    /^[*]/ { l = substr($0, 2); n = split(l, f, " "); if (n >= 10) { src = f[1]; st = f[3]; off = -f[n - 1] / 1000; ok = 1 } }
    END { if (!seen) exit 1
          printf "{\"t\":\"ntp\",\"side\":\"%s\",\"tool\":\"ntpq -p\",\"ref\":%s,\"stratum\":%s,\"off\":%s,\"synced\":\"%s\",\"note\":\"system peer = the line marked *; off = system clock minus the peer, seconds, positive = ahead (ntpq reports the opposite sign, in ms)\"}\n",
                 side, (ok ? "\"" j(src) "\"" : "null"), (ok ? st : "null"), (ok ? sprintf("%.9f", off) : "null"), (ok ? "yes" : "no") }' > "$TMP.ntp" || { NTPWHY="${NTPWHY:+$NTPWHY; }ntpq -p gave no peer table"; return 1; }
  [ -s "$TMP.ntp" ]; }
ntp_timedatectl() { have timedatectl || { NTPWHY="${NTPWHY:+$NTPWHY; }timedatectl not found"; return 1; }
  timedatectl 2>&1 | awk -v side="$SIDE" '
    /(System clock|NTP) synchronized:/ { sy = $NF }
    END { if (sy == "") exit 1
          printf "{\"t\":\"ntp\",\"side\":\"%s\",\"tool\":\"timedatectl\",\"ref\":null,\"stratum\":null,\"off\":null,\"synced\":\"%s\",\"note\":\"synchronized flag only: no source, stratum or offset\"}\n", side, sy }' > "$TMP.ntp" || { NTPWHY="${NTPWHY:+$NTPWHY; }timedatectl has no synchronized line"; return 1; }
  [ -s "$TMP.ntp" ]; }
ntp_lssrc() { have lssrc || { NTPWHY="${NTPWHY:+$NTPWHY; }lssrc not found"; return 1; }
  lssrc -s xntpd 2>&1 | awk -v side="$SIDE" '
    $1 == "xntpd" { sy = $NF }
    END { if (sy == "") exit 1
          printf "{\"t\":\"ntp\",\"side\":\"%s\",\"tool\":\"lssrc -s xntpd\",\"ref\":null,\"stratum\":null,\"off\":null,\"synced\":null,\"note\":\"xntpd subsystem status: %s; whether it is synchronized and its offset were not read\"}\n", side, sy }' > "$TMP.ntp" || { NTPWHY="${NTPWHY:+$NTPWHY; }xntpd not listed by lssrc"; return 1; }
  [ -s "$TMP.ntp" ]; }
case $OS in
  AIX) ntp_ntpq || ntp_lssrc ;;
  *) ntp_chrony || ntp_ntpq || ntp_timedatectl ;;
esac && NTPREC=1
if [ -n "$NTPREC" ]; then
  awk -v at="$COLLECTED" '{ sub(/}$/, ",\"at\":\"" at "\"}"); print }' "$TMP.ntp" >> "$OUT"
  cov ntp ok "$COLLECTED" "$COLLECTED" 1 "" 0 "$(sed -n 's/.*"tool":"\([^"]*\)".*/\1/p' "$TMP.ntp"), as collected: the clock state now, not at the incident"
else
  cov ntp skipped "" "" 0 "" 0 "no clock synchronisation state could be read: $NTPWHY"
fi

# ---- OS network counters of the window from sysstat (Linux): sar -n ETCP / TCP / DEV / EDEV, read from the daily files
# Relies on: sar printing "HH:MM:SS" 24-hour times and an ISO date in its banner with LC_ALL=C S_TIME_FORMAT=ISO; the first field of a data row is the
# time, DEV/EDEV rows have the interface second; each row is the average over the interval that ENDS at its time. Per report one cov record (src sar, kind).
sar_cov() { cov sar "$1" "$2" "$3" "$4" 2000 "$5" "$6" ",\"kind\":\"$7\""; }
if [ "$OS" = AIX ]; then
  for R in ETCP TCP DEV EDEV; do sar_cov skipped "" "" 0 0 "AIX has no network history by default (sar on AIX does not keep these reports)" $R; done
elif [ "$OS" != Linux ]; then
  for R in ETCP TCP DEV EDEV; do sar_cov skipped "" "" 0 0 "no sysstat network history read on ${OS:-this OS}" $R; done
elif ! have sar; then
  for R in ETCP TCP DEV EDEV; do sar_cov skipped "" "" 0 0 "sar not found (sysstat is not installed)" $R; done
else
  SADAYS=$(awk -v f="$F" -v t="$T" "$DATEAWK"'BEGIN { for (d = int(ep(f) / 86400); d <= int(ep(t) / 86400); d++) print substr(fmt(d * 86400), 1, 10) }')
  for R in ETCP TCP DEV EDEV; do
    : > "$TMP.sarrows"; SNOTE= SFIRST= SLAST= SNROWS=0 SGOT=0 SEMPTY=0 SERR=0 SNOFILE=0
    for DAY in $SADAYS; do
      YMD=$(echo "$DAY" | sed 's/-//g'); DD=$(echo "$DAY" | cut -c9-10); DONE=0; WHY=
      for DR in ${SA_DIR:-/var/log/sa /var/log/sysstat}; do
        for SF in "$DR/sa$YMD" "$DR/sa$DD"; do
          [ "$DONE" = 0 ] && [ -r "$SF" ] || continue
          LC_ALL=C S_TIME_FORMAT=ISO sar -n $R -f "$SF" > "$TMP.sar" 2>&1
          awk -v day="$DAY" -v f="$F" -v t="$T" -v side="$SIDE" -v rpt="$R" -v st="$TMP.sars" "$JFN"'
            function num(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) ? s : "null" }
            /^Linux|^[A-Za-z]+ [0-9]/ && match($0, /[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]/) { fdate = substr($0, RSTART, RLENGTH); next }
            /^[ \t]*$/ || /^Average/ { next }
            $1 !~ /^[0-2][0-9]:[0-5][0-9]:[0-5][0-9]$/ { if (msg == "") msg = $0; next }
            /RESTART/ { if (day " " $1 >= f && day " " $1 <= t) rs++; next }
            $2 !~ /^-?[0-9.]+$/ && $3 !~ /^-?[0-9.]+$/ { nh = 0; for (i = 2; i <= NF; i++) h[i] = $i; nh = NF; next }
            { tt = day " " $1; if (fts == "" || tt < fts) fts = tt; if (tt > lts) lts = tt
              key = (rpt == "DEV" || rpt == "EDEV") ? $2 : ""
              if (tt >= f && tt <= t) keep = 1; else if (tt > t && !(key in after)) { after[key] = 1; keep = 1 } else keep = 0
              if (!keep) next
              s = 3; if (key == "") s = 2
              m = ""; for (i = s; i <= NF; i++) m = m (m == "" ? "" : ",") "\"" j(h[i]) "\":" num($i)
              n++; print "{\"t\":\"sar\",\"side\":\"" side "\",\"rpt\":\"" rpt "\",\"ts\":\"" tt "\",\"if\":" (key == "" ? "null" : "\"" j(key) "\"") ",\"m\":{" m "}}" }
            END { printf "fdate=%s\nfirst=%s\nlast=%s\nn=%d\nrestarts=%d\nmsg=%s\n", fdate, fts, lts, n, rs, msg > st }' "$TMP.sar" > "$TMP.sarr"
          FD=$(kv fdate "$TMP.sars")
          if [ -n "$FD" ] && [ "$FD" != "$DAY" ]; then WHY="$SF is dated $FD, not $DAY"; continue; fi
          DONE=1
          SM=$(kv msg "$TMP.sars"); SN=$(kv n "$TMP.sars"); SFI=$(kv first "$TMP.sars"); SLA=$(kv last "$TMP.sars"); SRS=$(kv restarts "$TMP.sars")
          if [ -n "$SFI" ]; then
            cat "$TMP.sarr" >> "$TMP.sarrows"; SNROWS=$((SNROWS + SN))
            if [ -z "$SFIRST" ] || lt "$SFI" "$SFIRST"; then SFIRST=$SFI; fi
            if [ -z "$SLAST" ] || lt "$SLAST" "$SLA"; then SLAST=$SLA; fi
            if [ "$SN" -gt 0 ]; then SGOT=1; else SEMPTY=1; fi
            [ "${SRS:-0}" -gt 0 ] && SNOTE="$SNOTE${SNOTE:+; }$DAY: $SRS LINUX RESTART line(s) in the window: the host was restarted"
          else SERR=1; SNOTE="$SNOTE${SNOTE:+; }$DAY: ${SM:-no data} ($SF)"; fi
        done
      done
      [ "$DONE" = 1 ] || { SNOFILE=1; SNOTE="$SNOTE${SNOTE:+; }$DAY: ${WHY:-no sysstat file sa$YMD or sa$DD in ${SA_DIR:-/var/log/sa, /var/log/sysstat}}"; }
    done
    CAPPED=0; [ "$SNROWS" -gt 2000 ] && CAPPED=1
    head -2000 "$TMP.sarrows" >> "$OUT"
    if [ "$SGOT" = 1 ]; then ST=ok; elif [ "$SEMPTY" = 1 ]; then ST=empty; elif [ "$SERR" = 1 ]; then ST=error; else ST=skipped; fi
    sar_cov $ST "$SFIRST" "$SLAST" "$SNROWS" "$CAPPED" "sar -n $R, each row is the average over the interval that ends at its time${SNOTE:+; }$SNOTE" $R
  done
  note "sysstat: sar -n ETCP/TCP/DEV/EDEV read"
fi

# ---- samples of sh/net_sampler.sh (-n): the lines inside the window, from the log and its rotated .1 file
if [ -n "$SAMPLES" ]; then
  if [ -r "$SAMPLES" ] || [ -r "$SAMPLES.1" ]; then
    { [ -r "$SAMPLES.1" ] && clean < "$SAMPLES.1"; [ -r "$SAMPLES" ] && clean < "$SAMPLES"; } | awk -v f="$F" -v t="$T" -v side="$SIDE" -v st="$TMP.nss" "$JFN"'
      /^# net_sampler/ { hdr = $0; next }
      $1 ~ /^[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]/ {
        k = substr($1, 1, 10) " " substr($1, 12, 8); o = substr($1, 20); if (o ~ /^[+-][0-9][0-9][0-9][0-9]$/) o = substr(o, 1, 3) ":" substr(o, 4); else o = ""
        if (fts == "" || k < fts) fts = k; if (k > lts) lts = k
        if (k < f || k > t) next
        rtt = "null"; loss = "false"; retr = "null"; sq = "null"
        for (i = 2; i <= NF; i++) { split($i, a, "=")
          if (a[1] == "rtt") { if (a[2] ~ /^[0-9.]+$/) rtt = a[2]; else loss = "true" }
          else if (a[1] == "retr" && a[2] ~ /^[0-9]+$/) retr = a[2]
          else if (a[1] == "sendq" && a[2] ~ /^[0-9]+$/) sq = a[2] }
        n++; if (n <= 5000) print "{\"t\":\"netsamp\",\"side\":\"" side "\",\"ts\":\"" k "\",\"off\":" (o == "" ? "null" : "\"" o "\"") ",\"rtt\":" rtt ",\"loss\":" loss ",\"retr\":" retr ",\"sendq\":" sq "}" }
      END { gsub(/^# net_sampler /, "", hdr); printf "first=%s\nlast=%s\nn=%d\nhdr=%s\n", fts, lts, n, hdr > st }' >> "$OUT"
    NSN=$(kv n "$TMP.nss"); NSH=$(kv hdr "$TMP.nss")
    cov netsamp "$(okempty "$NSN")" "$(kv first "$TMP.nss")" "$(kv last "$TMP.nss")" "${NSN:-0}" 5000 "$(over "$NSN" 5000)" "samples of net_sampler.sh from $SAMPLES${NSH:+ ($NSH)}"
    note "sampler log: $SAMPLES"
  else
    cov netsamp skipped "" "" 0 5000 0 "cannot read $SAMPLES"
  fi
else
  cov netsamp skipped "" "" 0 5000 0 "option -n not given"
fi

# ---- peer address: -p wins; else the primary's destination descriptor, the standby's PROGRAM=oracle listener connections (then fal_server)
PEERHOW=
P1=$(grep '^v\$archive_dest' "$TMP.ep" 2>/dev/null | head -1)   # the first destination alias that resolved to an address: from, alias, host, port, ip, how
if [ -n "$PEER" ]; then PEERHOW="option -p"
elif [ "$SIDE" = primary ] && [ -n "$P1" ]; then
  PEER=$(echo "$P1" | cut -f5)
  PEERHOW="destination $(echo "$P1" | cut -f2) of v\$archive_dest = $(echo "$P1" | cut -f3):$(echo "$P1" | cut -f4) in tnsnames.ora or the descriptor; address from $(echo "$P1" | cut -f6)"
elif [ "$SIDE" = standby ] && [ -n "$SRVIP" ]; then
  PEER=$SRVIP PEERHOW=$SRVHOW
elif [ -s "$TMP.ep" ]; then
  P2=$(head -1 "$TMP.ep")
  PEER=$(echo "$P2" | cut -f5)
  PEERHOW="$(echo "$P2" | cut -f1) alias $(echo "$P2" | cut -f2) = $(echo "$P2" | cut -f3), address from $(echo "$P2" | cut -f6) (no listener evidence of the peer)"
fi
# the port: -P wins; else the descriptor's port (primary) or the standby's own listener port (the redo connections arrive there); else 1521
if [ "$PORTSET" = 0 ]; then
  if [ "$SIDE" = primary ] && [ -n "$P1" ]; then PORT=$(echo "$P1" | cut -f4)
  elif [ "$SIDE" = standby ] && [ -n "$LST" ]; then
    PORT=$(echo "$LST" | awk '/Listening Endpoints Summary/ { on = 1; next } on && /PROTOCOL=[Tt][Cc][Pp]\)/ && match($0, /PORT=[0-9]+/) { print substr($0, RSTART + 5, RLENGTH - 5); exit }')
  fi
fi
PORT=${PORT:-1521}

# ---- TCP connections to the peer on that port, and the short network check (as collected: it runs now, not during the window)
if [ "$NONET" = 1 ]; then
  cov conn skipped "" "" 0 200 0 "not requested: -N (passive collection, no live network check)"
  cov net skipped "" "" 0 "" 0 "not requested: -N (passive collection: no ping or netstat towards ${PEER:-the peer}${PEER:+:$PORT})"
elif [ -n "$PEER" ]; then
  if have netstat; then
    netstat -an 2>/dev/null | awk -v side="$SIDE" -v peer="$PEER" -v p="$PORT" -v st="$TMP.connn" "$JFN"'
      function ipof(a) { if (match(a, /[.:][0-9*]+$/)) a = substr(a, 1, RSTART - 1); sub(/^::ffff:/, "", a); return a }
      function pof(a) { if (match(a, /[.:][0-9*]+$/)) return substr(a, RSTART + 1); return "" }
      $1 ~ /^tcp/ && $NF != "LISTEN" && NF >= 6 && (ipof($4) == peer || ipof($5) == peer) && (pof($4) == p || pof($5) == p) {
        n++; if (n <= 200) printf "{\"t\":\"conn\",\"side\":\"%s\",\"lip\":\"%s\",\"lport\":%s,\"pip\":\"%s\",\"pport\":%s,\"state\":\"%s\",\"sendq\":%d,\"recvq\":%d}\n", side, j(ipof($4)), pof($4) + 0, j(ipof($5)), pof($5) + 0, $6, $3, $2 }
      END { printf "n=%d\n", n > st }' > "$TMP.conn"
    NCONN=$(kv n "$TMP.connn")
    cat "$TMP.conn" >> "$OUT"
    cov conn "$(okempty "${NCONN:-0}")" "$COLLECTED" "$COLLECTED" "${NCONN:-0}" 200 "$(over "${NCONN:-0}" 200)" "netstat -an: TCP connections between this host and $PEER on port $PORT, as collected (not during the window); first = last = collection time"
  else
    cov conn skipped "" "" 0 200 0 "netstat not found"
  fi
  if ! have ping && ! have netstat; then
    cov net skipped "" "" 0 "" 0 "neither ping nor netstat found: no network check towards $PEER:$PORT (peer from: $PEERHOW)"
  else
  retr() { netstat -s 2>/dev/null | awk '/retransmitted/ && !/SynRetrans/ { n += $1 } END { print n + 0 }'; }
  sendq() { netstat -an 2>/dev/null | awk -v p="$PORT" -v peer="$PEER" '$0 ~ peer && ($4 ~ "[.:]" p "$" || $5 ~ "[.:]" p "$") { if ($3 + 0 > m) m = $3 + 0 } END { print m + 0 }'; }
  PING=$(ping -c 10 "$PEER" 2>&1)
  RTT=$(echo "$PING" | awk -F'= ' '/min\/avg/ { split($2, a, "/"); print a[2]; exit }')
  LOSS=$(echo "$PING" | awk '/packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%/) { print $i; exit } }')
  R1=$(retr); MQ=0; i=0
  while [ $i -lt 5 ]; do q=$(sendq); [ "$q" -gt "$MQ" ] && MQ=$q; sleep 2; i=$((i + 1)); done
  R2=$(retr)
  NETAT=$(now)
  NETVIA=$PEERHOW awk -v side="$SIDE" -v peer="$PEER" -v port="$PORT" -v os="$OS" -v rtt="${RTT:-?}" -v loss="${LOSS:-?}" -v retr="$((R2 - R1))" -v mq="$MQ" -v at="$NETAT" "$JFN"'
    BEGIN { printf "{\"t\":\"net\",\"side\":\"%s\",\"peer\":\"%s\",\"port\":\"%s\",\"os\":\"%s\",\"rtt\":\"%s\",\"loss\":\"%s\",\"retr\":%s,\"secs\":10,\"sendq\":%s,\"at\":\"%s\",\"via\":\"%s\"}\n",
            side, j(peer), port, j(os), j(rtt), j(loss), retr, mq, at, j(ENVIRON["NETVIA"]) }' >> "$OUT"
  NETNOTE="ping and netstat towards $PEER:$PORT, measured at collection time, not during the window"
  have netstat || NETNOTE="$NETNOTE; netstat not found: retr and sendq are 0 placeholders, not measurements"
  have ping || NETNOTE="$NETNOTE; ping not found: rtt and loss are ?"
  cov net ok "$NETAT" "$NETAT" 1 "" 0 "$NETNOTE; peer from: $PEERHOW"
  note "network check: $PEER:$PORT ($PEERHOW)"
  fi
else
  cov conn skipped "" "" 0 200 0 "no peer address: -p not given and none could be derived"
  cov net skipped "" "" 0 "" 0 "no peer address: option -p not given and none could be derived (destination descriptor, listener PROGRAM=oracle connections, fal_server)"
fi

# ---- UTC offset of this host inside the window: alert log, else listener log, else collection time (DST may have changed since)
if ! grep '"t":"clock"' "$OUT" | grep -q "\"side\":\"$SIDE\""; then
  if [ -n "$ALOFF" ]; then COFF=$ALOFF CSRC="alert log"; [ "$ALCHG" = 1 ] && CSRC="alert log, offset changes inside the window"
  elif [ -n "$LSOFF" ]; then COFF=$LSOFF CSRC="listener log"; [ "$LSCHG" = 1 ] && CSRC="listener log, offset changes inside the window"
  else
    COFF=$(grep '"t":"meta"' "$OUT" | sed -n 's/.*"tz":"\([^"]*\)".*/\1/p' | head -1); CSRC="systimestamp at collection time"
    if [ -z "$COFF" ]; then
      Z=$(date +%z); CSRC="date at collection time"
      case $Z in [+-][0-9][0-9][0-9][0-9]) COFF=$(echo "$Z" | sed 's/..$/:&/') ;; *) CSRC="unknown: no offset in the logs and none from the system" ;; esac
    fi
  fi
  printf '{"t":"clock","side":"%s","utc_off":%s,"src":"%s"}\n' "$SIDE" "$([ -n "$COFF" ] && echo "\"$COFF\"" || echo null)" "$CSRC" >> "$OUT"
fi

echo "Bundle written: $OUT" >&2
awk -F'"t":"' 'NF > 1 { split($2, a, "\""); c[a[1]]++ } END { for (k in c) printf "  %-9s %d lines\n", k, c[k] }' "$OUT" | sort >&2
echo "Coverage (what each source held in the window):" >&2
# one line per cov record: src, or src/kind when the record has a kind (act/job, sar/ETCP), so that the records of one source can be told apart
grep '"t":"cov"' "$OUT" | awk '
  { s = $0
    if (!match(s, /"src":"[^"]*"/)) next
    src = substr(s, RSTART + 7, RLENGTH - 8); rest = substr(s, RSTART + RLENGTH)
    if (match(rest, /^,"kind":"[^"]*"/)) src = src "/" substr(rest, 10, RLENGTH - 10)
    if (!match(s, /"st":"[^"]*"/)) next
    st = substr(s, RSTART + 6, RLENGTH - 7)
    if (!match(s, /"n":[0-9]+/)) next
    n = substr(s, RSTART + 4, RLENGTH - 4) + 0
    printf "  %-13s %-8s %d%s\n", src, st, n, (s ~ /"capped":true/ ? "  CAPPED, see the note in the cov record" : "") }' >&2
BAD=$(grep -v '^{' "$OUT" | errlines 5)
[ -n "$BAD" ] && { echo "Some queries reported errors (they are listed in the report):" >&2; echo "$BAD" | sed 's/^/  /' >&2; }

# ---- what to run next
BN=$(basename "$OUT")
if [ "$SIDE" = standby ]; then
  echo >&2
  echo "Next, on the PRIMARY host:" >&2
  echo "  1. Copy the standby bundle there:   $BN   (scp or any other way; it is a small text file)" >&2
  echo "  2. Run:   sh $0 -c $BN primary \"$2\" \"$3\"" >&2
else
  echo >&2
  echo "Next, build the report (on any host that has the bundles in one directory):" >&2
  if [ -n "$CIDS" ]; then echo "  sh $(dirname "$0")/make_report.sh -o report.html $OUT $CIDS" >&2
  else echo "  sh $(dirname "$0")/make_report.sh -o report.html $OUT <the standby bundle>   (the primary bundle alone also works)" >&2; fi
fi
exit $FAIL

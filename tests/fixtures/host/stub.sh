#!/bin/sh
# Stand-in for the host tools collect.sh and net_sampler.sh call (sar, chronyc, ntpq, timedatectl, getent, netstat, ping, sysctl, lsnrctl, lssrc, no, uname, sleep).
# Called through tiny wrappers made by tests/run.sh:  stub.sh <tool> args...   Canned output lives next to this file. Variants via environment:
#   STUB_OS (uname, default Linux)   STUB_CHRONY ok|unsync|down   STUB_NTPQ ok|none   STUB_PING ok|loss   STUB_STATE (a directory: counters)
#   STUB_SIDE primary|standby (which host's netstat -an to show)   STUB_LSNR_LOG (path printed as the listener log file)   STUB_SAR_ENV_CHECK=1 (default): without LC_ALL=C and S_TIME_FORMAT=ISO sar answers in 12-hour locale format
#   STUB_CALLS (a file: each call is appended as "<tool> args")
H=$(cd "$(dirname "$0")" && pwd); T=$1; shift
[ -n "$STUB_CALLS" ] && echo "$T $*" >> "$STUB_CALLS"   # optional log of the tools called
case $T in
  uname) echo "${STUB_OS:-Linux}" ;;
  sleep) ;;
  ping) case ${STUB_PING:-ok} in loss) cat "$H/ping.loss" ;; *) if [ "${STUB_OS:-Linux}" = AIX ]; then cat "$H/ping.aix"; else cat "$H/ping.ok"; fi ;; esac ;;
  netstat)
    OSX=linux; [ "${STUB_OS:-Linux}" = AIX ] && OSX=aix
    case $1 in
      -s) n=$(cat "$STUB_STATE/ns" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_STATE/ns"; sed "s/@RETR@/$((1000 + n * 5))/" "$H/netstat_s.$OSX" ;;
      *) cat "$H/netstat_an.$OSX.${STUB_SIDE:-primary}" ;;
    esac ;;
  sar)
    RPT= FILE=; while [ $# -gt 0 ]; do case $1 in -n) RPT=$2; shift ;; -f) FILE=$2; shift ;; esac; shift; done
    [ -n "$RPT" ] || RPT=DEV   # sar -f FILE without -n (collect.sh list reads the banner date): any report's file carries it; DEV's sa14 is the file of another month
    if [ "$LC_ALL" != C ] || [ "$S_TIME_FORMAT" != ISO ]; then printf 'Linux 5.14.0 (stby-host.example) \t11/13/26 \t_x86_64_\t(2 CPU)\n\n11:50:01 PM     atmptf/s\n11:50:01 PM         0.00\n'; exit 0; fi
    F=$H/sar/$(basename "$FILE").$RPT
    if [ -r "$F" ]; then cat "$F"; else echo "Cannot open $FILE: No such file or directory"; exit 2; fi ;;
  chronyc) case ${STUB_CHRONY:-ok} in down) echo "506 Cannot talk to daemon"; exit 1 ;; *) cat "$H/chronyc.${STUB_CHRONY:-ok}" ;; esac ;;
  ntpq) cat "$H/ntpq.${STUB_NTPQ:-ok}" ;;
  timedatectl) cat "$H/timedatectl.ok" ;;
  lssrc) cat "$H/lssrc.ok" ;;
  getent) grep "[[:space:]]$2\$" "$H/getent.txt" || exit 2 ;;
  sysctl) [ "$1" = -n ] && grep "^$2 = " "$H/sysctl.txt" | sed 's/^[^=]*= //' ;;
  no) cat "$H/no.txt" ;;
  lsnrctl) sed "s#@LOG@#$STUB_LSNR_LOG#" "$H/lsnrctl.txt" ;;
esac

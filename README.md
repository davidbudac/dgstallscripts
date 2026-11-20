# Data Guard SYNC stall analysis scripts

Scripts for the troubleshooting guide "Data Guard SYNC transport stalls" (LGWR on
`SYNC Remote Write`, `log file sync` pile-ups, ORA-16198, LAD UNSYNCHRONIZED).
Everything is read-only. Tested on Oracle 19c (primary open, standby mounted), Linux; the shell
scripts use only POSIX sh and awk features available on AIX.

Licensing: sections 10–13, 17 and 18 read ASH/AWR (`DBA_HIST_*`, `V$ACTIVE_SESSION_HISTORY`),
which needs the Diagnostics Pack.

## What to run, in order

Pick a window that starts a few minutes before the first symptom and ends after the destination
is SYNCHRONIZED again. Copy the whole directory to each host and run from inside it.

| # | Where | Command | Answers |
|---|---|---|---|
| 1 | Primary | `sqlplus -S / as sysdba @run_primary.sql "2026-11-13 20:35:00" "2026-11-13 20:58:00" [history_days]` | When commits waited and on what; LGWR/NSS/TT/ARC samples; latency histograms; redo rate; alert log; earlier occurrences; transport config; when each sequence reached the standby |
| 2 | Standby | `sqlplus -S / as sysdba @run_standby.sql "2026-11-13 20:35:00" "2026-11-13 20:58:00"` | Data Guard messages; sequences received and which came by FAL; RFS processes, standby redo logs, lag |
| 3 | Standby (and primary) | `sh/alert_log_scan.sh <alert_SID.log> 2026-11-13 20:35 20:58` | Standby alert log for the window (SQL cannot read it in MOUNT) and DG/network errors across the whole file |
| 4 | Both | `sh/trace_scan.sh <Diag Trace dir> 2026-11-13 20:35 20:58 [days back]` | ORA-/TNS-/nt errors in LGWR, NSS, TT, ARC, TMON, RFS and MRP traces inside the window |
| 5 | Standby | `sh/listener_log_scan.sh <listener.log> 13-NOV-2026 20:35 20:58` | What reached the standby listener, from which IP, which were refused; writes `refused_connection_ids.txt` |
| 6 | Primary | `sh/connid_lookup.sh <primary listener.log> refused_connection_ids.txt` | Whether the clients refused at the standby reached the primary, and when |
| 7 | Both | `sh/os_net_check.sh <peer redo IP> <listener port> [seconds]` | RTT and loss, the redo connection's queues, TCP retransmits over the interval, adapter errors, OS log |
| 8 | Primary | `[DG_CONNECT=sys@<alias>] sh/dgmgrl_checks.sh <primary> <standby>` | Broker LogXptMode, NetTimeout, ReopenSecs, LogXptStatus; validate database and network |

The SQL drivers spool to `dg_primary_<db>_<timestamp>.txt` / `dg_standby_<db>_<timestamp>.txt`
in the current directory. `history_days` (default 30) sets how far back section 21 looks.

## Finding the inputs

- **Trace dir and alert log:** section 00 of the SQL output prints `Diag Trace`; the text alert log is
  `<Diag Trace>/alert_<SID>.log`.
- **Listener log:** `lsnrctl status <listener>` shows "Listener Log File" (`.../alert/log.xml`);
  the text log is `.../trace/<listener>.log`.
- **Date formats:** SQL and trace/alert scans take `YYYY-MM-DD`; the listener log uses `DD-MON-YYYY`
  in upper case (`13-NOV-2026`). Times are the host's local time as written in each log.
- **Peer redo IP:** the address the redo actually travels on (from `v$archive_dest.destination` →
  tnsnames → IP), not necessarily the host's first interface.

## Reading the output (short version)

- `log file sync` rows whose `blocking_session` is LGWR's SID = commits waiting on LGWR (section 10).
- LGWR on `log file parallel write` instead of `SYNC Remote Write` = local redo I/O, not Data Guard.
- One LGWR `SYNC Remote Write` wait (same `seq#`) running until ORA-16198 = no acknowledgement until
  `NET_TIMEOUT`; the LGWR trace says so explicitly ("exceeds begin time … by <30> seconds").
- `nt secondary err code` / `nt OS err code` are errno values: look them up in `/usr/include/errno.h`
  on that host (AIX and Linux differ). 0 = no OS-level error reported with the failure.
- Section 18 redo and transactions at or near zero while the destination is out of sync = the
  application sent little work, so a slow application in that period is not explained by Data Guard.
  Logons per second shows whether application logins kept reaching the primary.
- `FAL = YES` in section 40 = the sequence was resolved as a gap, with its arrival time.
- Refused application logins at the standby listener (code 12514) = clients failing over from the
  primary; step 6 shows whether the same clients reached the primary.

## Files

```
run_primary.sql          driver, primary (open)
run_standby.sql          driver, standby (works in MOUNT)
sql/_settings.sql        formatting
sql/00_context.sql       database, instance, diag paths
sql/10_ash_foreground.sql   foreground waits per minute (DBA_HIST and V$ ASH)
sql/12_ash_lgwr_transport.sql  LGWR / NSS / TT / ARC / TMON samples
sql/14_sync_latency.sql  averages, histograms, AWR histogram per snapshot, redo and commit rate
sql/20_alert_log.sql     alert log window + earlier occurrences (primary only)
sql/22_dataguard_status.sql  V$DATAGUARD_STATUS
sql/30_dest_config.sql   destination mode, timers, sync and gap state, parameters
sql/40_redo_shipping.sql archived/received sequences in the window, FAL flag
sql/50_standby_state.sql RFS processes, standby redo logs, lag, gaps
sh/alert_log_scan.sh     text alert log scan
sh/trace_scan.sh         background trace scan
sh/listener_log_scan.sh  listener log scan
sh/connid_lookup.sh      CONNECTION_ID cross-check on the primary
sh/os_net_check.sh       network and OS checks (AIX and Linux)
sh/dgmgrl_checks.sh      broker checks
```

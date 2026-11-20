# dgstallscripts

Read-only scripts that work out why commits stalled on an Oracle Data Guard primary with a SYNC or
FASTSYNC standby: LGWR waiting on `SYNC Remote Write`, sessions piling up on `log file sync`,
ORA-16198, and the destination going `UNSYNCHRONIZED`. They collect the evidence from both hosts and
turn it into one HTML report.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/report-dark.png">
  <img src="docs/report-light.png" alt="The HTML report: summary cards, matched signals and the incident timeline">
</picture>

**[Open the sample report](https://raw.githack.com/davidbudac/dgstallscripts/main/examples/sample-report.html)**
(or download [`examples/sample-report.html`](examples/sample-report.html) and open it). It is built
from the synthetic bundles in [`examples/`](examples): fictional names and documentation IP addresses,
shaped like a real incident.

## Quick start

Copy this directory to both database hosts. Run the collector as the `oracle` user with the
environment of the database set (`ORACLE_SID`, `ORACLE_HOME`, `PATH`). Pick a window that starts a few
minutes before the first symptom and ends after the destination is `SYNCHRONIZED` again.

```sh
# 1. On the standby
sh/collect.sh standby "2026-11-13 20:35" "2026-11-13 20:58"

# 2. On the primary, after copying the standby bundle over
sh/collect.sh -c dgr_standby_<host>_<ts>.jsonl -p <standby redo IP> primary "2026-11-13 20:35" "2026-11-13 20:58"

# 3. Anywhere with both bundles: a database host or your laptop
sh/make_report.sh -o report.html dgr_primary_*.jsonl dgr_standby_*.jsonl
```

Open `report.html` in any browser. It is a single file with no external resources, so it works offline
and can be attached to a ticket.

- Each `collect.sh` run writes one bundle, `dgr_<side>_<host>_<timestamp>.jsonl`, and prints what it
  found. A full run takes about half a minute.
- `-c` and `-p` are optional. Without `-c`, the clients refused at the standby are listed but not
  looked up on the primary. Without `-p`, there is no network card.
- One bundle is enough for a report. The sections that need the other side say what is missing.

## What the report shows

| Section | What it answers | Source |
|---|---|---|
| Summary | How long commits were blocked, the longest SYNC write, how long the standby was out of sync | ASH, alert log |
| Signals | Which readings from the troubleshooting guide match, with clickable evidence; what is ruled out or not checked | All of the below |
| Incident timeline | Alert messages, commit waits, LGWR, NSS/TT and archiver waits, destination state, standby logins and redo rate on one clock, with zoom | Everything |
| Commit waits per minute | Average sessions on `log file sync` behind LGWR, other waits, CPU | ASH or AWR ASH |
| Longest waits, SYNC Remote Write | Merged LGWR/transport/archiver waits; histogram for the window (AWR) and since startup | ASH, AWR, `v$event_histogram_micro` |
| Alert logs | Primary and standby merged, filterable, incident rows highlighted | `v$diag_alert_ext`, alert log file |
| Earlier occurrences, traces | The same errors on other days; errors in background traces in the window | Alert logs, trace files |
| Redo shipping | When each sequence reached the standby, and whether it came as a gap (FAL) | `v$archived_log` |
| Listener logins | Logins per minute on each side; refused clients and whether they reached the primary | Listener logs |
| Configuration | Transport mode, `NET_TIMEOUT`, `REOPEN`, protection level, standby redo logs, lag | `v$archive_dest`, `v$database`, `v$standby_log`, `v$dataguard_stats` |
| Network and OS | Round trip, loss, TCP retransmits and Send-Q to the peer | `ping`, `netstat` |

## Requirements and safety

- Oracle 19c (tested on 19.27). The primary must be open; the standby can be mounted.
- A POSIX shell and awk. Tested on Linux; the scripts avoid GNU-only options so they run on AIX.
- `sqlplus` connecting as SYSDBA (`/ as sysdba` by default).
- The ASH and AWR parts need the **Diagnostics Pack** license.
- **Read-only.** The SQL is `SELECT` only, plus `ALTER SESSION` for date formats. The shell scripts
  only read logs and run display commands. Files are written to the current directory and `/tmp`.
- The heaviest step is reading the alert log through `v$diag_alert_ext` for the "earlier
  occurrences" history. Use `-d 7` to shorten it on a large alert log.
- Bundles and reports contain host names, IP addresses, connection IDs and log text. Handle them like
  the logs themselves.

## `collect.sh` options

```
sh/collect.sh [options] primary|standby "YYYY-MM-DD HH:MI" "YYYY-MM-DD HH:MI"
```

| Option | Default | Meaning |
|---|---|---|
| `-o file` | `./dgr_<side>_<host>_<now>.jsonl` | Bundle to write |
| `-u conn` | `/ as sysdba` | sqlplus connect string |
| `-t dir` | `Diag Trace` from `v$diag_info` | Trace directory |
| `-a file` | `<trace dir>/alert_$ORACLE_SID.log` | Text alert log (read on the standby) |
| `-l file` | from `lsnrctl status` | Listener text log |
| `-c file` | none | Standby bundle whose refused CONNECTION_IDs are looked up in this listener log |
| `-p ip` | none | Peer redo IP for a 10 s network check (`-P port`, default 1521) |
| `-d days` | 30 | How far back "earlier occurrences" looks |

Limitations: the window must lie within one day, in the hosts' local time. Only the listener whose log
`lsnrctl status` reports is scanned; pass `-l` for another one.

## Individual scripts

The same evidence as plain text, for when you want to read it directly or run one check on its own.

### What to run, in order

Copy the whole directory to each host and run from inside it.

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

### Finding the inputs

- **Trace dir and alert log:** section 00 of the SQL output prints `Diag Trace`; the text alert log is
  `<Diag Trace>/alert_<SID>.log`.
- **Listener log:** `lsnrctl status <listener>` shows "Listener Log File" (`.../alert/log.xml`);
  the text log is `.../trace/<listener>.log`.
- **Date formats:** SQL and trace/alert scans take `YYYY-MM-DD`; the listener log uses `DD-MON-YYYY`
  in upper case (`13-NOV-2026`). Times are the host's local time as written in each log.
- **Peer redo IP:** the address the redo actually travels on (from `v$archive_dest.destination` →
  tnsnames → IP), not necessarily the host's first interface.

### Reading the output (short version)

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
sh/collect.sh            collect one host's data into a bundle for the report
sh/make_report.sh        build the HTML report from bundles
report/template.html     the report page (make_report.sh inserts the data)
sql/json_primary.sql     report data, primary (called by collect.sh)
sql/json_standby.sql     report data, standby (called by collect.sh)
examples/                synthetic sample bundles and the report built from them
docs/                    README screenshots

run_primary.sql          text report driver, primary (open)
run_standby.sql          text report driver, standby (works in MOUNT)
sql/_settings.sql        formatting
sql/00_context.sql       database, instance, diag paths
sql/10_ash_foreground.sql      foreground waits per minute (DBA_HIST and V$ ASH)
sql/12_ash_lgwr_transport.sql  LGWR / NSS / TT / ARC / TMON samples
sql/14_sync_latency.sql  averages, histograms, AWR histogram per snapshot, workload per minute
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

To rebuild the sample report after changing the template:
`sh/make_report.sh -o examples/sample-report.html examples/sample_primary.jsonl examples/sample_standby.jsonl`

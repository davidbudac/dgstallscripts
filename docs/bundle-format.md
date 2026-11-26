# Bundle format

`sh/collect.sh` writes one bundle per host: UTF-8 text, one JSON object per line, the record type in `"t"`.
`sh/make_report.sh` embeds bundles into the report page, whose JavaScript reads them. This is format **v2**
(`"v":2` in the first line). The report still reads v1 bundles; the differences are at the end.

A line that does not start with `{` is sqlplus error text (`ORA-`, `SP2-`) that landed in the spool. The report
lists such lines as failed queries. Unknown record types are ignored, so new ones can be added: the records of collector
phase 3 ([below](#records-added-by-the-collector-in-phase-3)) and the five of the step after it (`lfs_by`, `aas`, `wl_hist`, `alsync`, `act`, [below](#who-waited-active-sessions-workload-history-ended-unsynchronized-periods-and-scheduled-activity)) are all optional, an older bundle without them is still a valid v2 bundle.

## Times

Every timestamp is the **local time of the collecting host**, written `YYYY-MM-DD HH:MI:SS`, with `.FFF` where the
source has milliseconds (`tx.ts`, `alert.ts`, `trace.ts`). Buckets keep the same shape, cut short:
minute buckets `YYYY-MM-DD HH:MI`, 10 s buckets `YYYY-MM-DD HH:MI:SS`. No zone is written on the record; the `clock`
record (below) says which UTC offset applied. A reader must treat them as naive values and not let its own zone or
DST move them (the report parses them with `Date.UTC`).

The window may cross midnight or span days. Both ends count to the second (`from <= t <= to`). A timestamp can
fall outside the window by design: `alhist` (history), `arch.first/next` (a log that started earlier), `net.at` and `ntp.at`
(when the check ran), `dgproc.since` (when a process started), `base_day.from/to/b/e` (the same clock interval on earlier days), `alsync.ts`, `wl_hist.b/e` and `act.a/z` (the lookback, like `alhist`), `cov.first/last` (what a source holds).

## Records

`side` is `primary` or `standby` on every record. Fields marked * exist on the primary only, ** on the standby only.

| t | Fields | Notes |
|---|---|---|
| `bundle` | `host from to collected cidcheck v` | first line; `cidcheck` = yes when `-c` was given; `from`, `to` are the window |
| `meta` | `db uniq role open pmode plevel inst host ver plat from to gen tz startup cluster_database* inst_count* ash`* | written by sqlplus. `tz` = `systimestamp` offset at collection (kept for compatibility). `ash` = `V` (v$active_session_history) or `H` (AWR copy). `startup`, `cluster_database`, `inst_count`: see below. **No meta line means the database part failed.** |
| `clock` | `utc_off src` | one per side, see below |
| `cov` | `src st first last n cap capped note` (+ `kind`, `files`, `samples`) | one per data source and side, see below |
| `dest`* | `id dest uniq status mode affirm net_timeout reopen max_failure failures error sync synced gap` | standby destinations, as when collected |
| `param` | `name value` | `data_guard_sync_latency`, `log_archive_config`, `fal_server`, `log_archive_dest_n` (primary); `fal_server`, `log_archive_config` (standby) |
| `fg`* | `m lgwr other cpu` | per minute: sample counts of foreground sessions (blocked by LGWR on `log file sync`, other waits, on CPU) |
| `fg10`* | `b n` | per 10 s bucket: samples of `log file sync` behind LGWR (sample counts: they do not say how long one commit waited) |
| `lfs`* | `sid ser seq a z n tw lg` | one record per `log file sync` wait seen in ASH, see below |
| `lfs_sum`* | `waits lgwr_waits pk_n pk_at pk_lg pk_lg_at` | totals over all those waits and the most sessions waiting in one sample, see below |
| `ashgap`* | `ia a iz z` | a gap in the ASH sampler: two consecutive samples, see below |
| `lfs_by`* | `dim name n lg sess a z` | foreground samples on `log file sync` grouped by service, module and machine, in the window, see below |
| `aas`* | `m ev wc fg bg` | ASH samples per minute and wait event, foreground (`fg`) and other session types (`bg`) counted apart; no `side`, as in `fg`; the events beyond the 12 with the most samples are one record per minute with `ev` and `wc` null, see below |
| `tx` | `ts p ev seq tw` (`sid`**) | LGWR/LGnn/NSSn/TTnn/ARCn/TMON wait samples; `p` process, `ev` event, `tw` microseconds. The standby has them too, see below |
| `hist_su` | `ev b us n` | `v$event_histogram_micro` since startup (primary: SYNC Remote Write, log file sync; standby: the RFS events) |
| `hist_awr`* | `ev ms n b e` | AWR histogram summed over the snapshots overlapping the window; `b`, `e` = first begin, last end (minute) |
| `wl`* | `m redo txn logons aas` | per minute from `dba_hist_sysmetric_history` (redo in MB/s) |
| `alert` | `ts msg` | alert log messages in the window (SQL on the primary, text file on the standby or with `-a`) |
| `alhist` | `ts msg` | earlier Data Guard / network errors, newest 300 |
| `alsync` | `ts msg` | the alert-log lines that end an UNSYNCHRONIZED period of a destination, same lookback as `alhist`, newest 300, see below |
| `wl_hist`* | `b e redo redo_max txn` | workload per AWR snapshot interval over the lookback, newest 1500, see below |
| `act` | `kind` + fields of the kind | scheduled activity in the lookback: RMAN commands (`rman`, both sides), scheduler job runs (`job`*), log switches (`logsw`*), see below |
| `arch` | `dest thr seq first next done creator reg fal mb` | sequences completed in the window; `fal` = YES for a gap |
| `srl`** `dgstat`** | `thr grp seq st mb` / `name value unit` | standby redo logs and `v$dataguard_stats`, as when collected |
| `trace` | `ts file msg` | error lines of background traces in the window, earliest 400 |
| `lsnr` | `m code n` | listener `establish` lines per minute and return code |
| `lsnr_ip` | `ip code n` | the same per client address |
| `lsnr_ref` | `ts ip code cid svc` | refused logins (code not 0), first 500 |
| `cid_hit` | `ts ip code cid` | where a standby-refused CONNECTION_ID showed up in this listener log (`-c`), first 2000 |
| `net` | `peer port os rtt loss retr secs sendq at via` | 10 s ping and netstat check, **as collected, not during the window**; `via` = how the peer address was found (`option -p` or the derivation, see below). `via` is absent in older bundles |
| `dgstatus` `dest_hist`* `base_day`* `base_hist`* `rfs_ev`** `dgproc`** `archgap`** | | collector phase 3, see below |
| `lsnr_srv` `ep` `conn` `sqlnet` `ostcp` `ntp` `sar` `netsamp` | | collector phase 3, see below |

## Records added by the collector in phase 3

Every one of these is optional and has a `cov` record. "In the window" means the rows were selected by their own timestamp
(`from <= ts <= to`); "as collected" means the record describes the host or the view **when `collect.sh` ran**, which may be
hours or days after the incident (`first` = `last` = the collection time in its `cov` record); "cumulative" means counters
since the instance started (`meta.startup`).

### `meta`: three fields

- `startup`: `v$instance.startup_time`, `YYYY-MM-DD HH:MI:SS`, both sides. The counters of `hist_su`, `rfs_ev` and `dest_hist` do not reach back
  before it.
- `cluster_database`* : `TRUE` or `FALSE` from `v$parameter`; `null` when it could not be read.
- `inst_count`* : the number of rows of `gv$instance` (open instances), `null` when `gv$instance` could not be read. Both are read by statements of
  their own, so a failure leaves `null` and does not cost the meta line. The tool collects **one instance only**: with `cluster_database` TRUE or
  `inst_count` above 1 the report says that blockers and LGWR on the other instances are not resolved.

### Standby, from the database (works when the standby is only MOUNTED)

- `tx` (standby, in the window): wait samples (`session_state = WAITING`) of the redo-related processes from `v$active_session_history`, the same
  fields as the primary `tx` (`ts` with milliseconds, `p`, `ev`, `seq`, `tw` in microseconds, set on the last sample of a wait only) plus `sid` (session_id; several
  RFS processes share one program text). `p` is the text in parentheses of `v$active_session_history.program`: `PRnn`, `MRP0`, `ARCn`, `TTnn`, `TMON`, `LGWR`, `LGnn`, `NSSn`, `DBWn`, `CKPT`,
  or `TNS V1-V3`. **The RFS processes that receive redo have no tag of their own: their `program` is the client program on the PRIMARY, `oracle@<primary host> (TNS V1-V3)`**; the filter takes programs of exactly that form (`oracle@...`), so a `sqlplus@` or `rman@` session
  with the same tag is not taken for RFS, but an Oracle database link from another database looks the same and is. The view is in memory and reaches back minutes to hours: `cov ash` (kind `V`) has what it holds
  in `first`/`last`, `n` = ASH rows in the window. `cov tx`: `n` = qualifying samples found, `cap` 5000 (transport processes are kept first, then recovery, DBWR and CKPT).
- `ashgap` (standby): as on the primary (below), over `v$active_session_history` only. `cov ashgap`.
- `rfs_ev` (cumulative): one record per `RFS%` event of `v$system_event` with waits: `ev`, `n` total waits, `tmo` total timeouts, `us` total microseconds waited,
  `avg_us` = `us / n`. `cov rfs_ev`: `first` = `meta.startup`, `last` = the collection time.
- `hist_su` with `side` standby (cumulative): the `v$event_histogram_micro` buckets of the same events, rows with `n > 0`: `ev`, `b` (the view's own label), `us` bucket in
  microseconds, `n` waits. `cov rfs_hist`.
- `dgstatus` (both sides, in the window): `v$dataguard_status` rows: `ts` (`timestamp`, a DATE: whole seconds), `facility`, `severity`, `dest` (`dest_id`, 0 = no destination), `err` (`error_code`),
  `msg` (`message`, at most 300). The view is **in memory and lost at restart**: `cov dgstatus` `first`/`last` = the oldest and newest row it holds, so an empty window can be told from a
  view that no longer reaches it. Newest 500 rows of the window kept (`cap`), `n` counts all.
- `dgproc` (standby, as collected): `v$dataguard_process`: `name pid role action client_pid client_role thr seq block blocks dest since` (`since` = `proc_time`). `cov dgproc`.
- `archgap` (standby, as collected): `v$archive_gap`: `thr low high`. Empty = no gap when collected. `cov archgap`.

### Primary, from the database

- `dest_hist` (cumulative, as collected): `v$redo_dest_resp_histogram` rows with `frequency > 0`: `dest` (`dest_id`), `dur` (bucket in whole seconds: 1, 2, 3 ... 300, then 600, 1200, 2400, 4800, 9600), `freq` (times that
  bucket was hit), `hit` (`time`: **text**, `VARCHAR2(20)`, the last wall-clock time the bucket was hit, exactly as the view gives it; not parsed). Not limited to the window. `cov dest_hist`.
- `base_day` and `base_hist`, the baseline (`collect.sh -b days`, default 7, 0 = none): the wait-time histograms of `SYNC Remote Write` and `log file sync` for **the same clock interval on each of the previous days**,
  from the deltas of `dba_hist_event_histogram` between AWR snapshots (Diagnostics Pack). `base_day`: `d` (1 = the day before the window), `from`/`to` (the interval on that day: the window's clock times, `d` days earlier, wall-clock arithmetic),
  `snaps` (AWR snapshots overlapping it), `used` (those that gave a delta), `b`/`e` (begin of the first and end of the last snapshot used, `null` when none). `base_hist`: `d`, `ev`, `ms` (`wait_time_milli`, the bucket
  in milliseconds), `n` (waits in that bucket over the snapshots used, zero buckets omitted). **The deltas cover whole snapshot intervals, so `b`..`e` is usually wider than `from`..`to`** (with 30 or 60 minute snapshots): compare
  the shape of the histogram (shares per bucket), or scale by the covered length, not raw counts. A snapshot whose predecessor has another `startup_time` (the instance restarted, the counters began at 0) is left out, so there
  is no negative or inflated delta; `snaps - used` says how many. A day outside AWR retention has a `base_day` with `snaps` 0. `cov base_hist`: `n` = days with at least one usable histogram delta, `first`/`last` = the AWR span held.

### From the hosts

- `lsnr_srv` (in the window): listener `establish` lines whose `CID` has `PROGRAM=oracle`, i.e. an Oracle server process acting as the client: normally the other database host (redo transport, FAL, broker), but a database link from any other Oracle database matches too: `ts`, `host` (the client host in the `CID`), `ip` and `port` (the source address
  of the connection, what a firewall session log shows), `svc` (`SERVICE_NAME`, or `SID:<sid>`), `code` (return code, 0 = accepted). First 500 (`cap`); `cov lsnr_srv` has the count found. Of the listener the collector found (`-l`).
- `ep` (as configured, collected): the address redo travels on. One record per alias: `from` (`v$archive_dest` for a destination of the primary, `fal_server` for the aliases in `fal_server`, both sides), `dest` (`dest_id` or null), `alias` (the destination
  string), `file` (the `tnsnames.ora` it was found in: `$TNS_ADMIN`, else `$ORACLE_HOME/network/admin`), `host`, `port` (the first `HOST` and `PORT` of the descriptor), `addrs` (number of `ADDRESS` entries: more than 1 = a list), `ip` and `ip_how` (what `getent hosts <host>`
  returned, or `address given in the descriptor`; null when `getent` is missing or fails), `note` (how it was resolved, or why not). An alias that is a descriptor or an easy connect string is read directly. `IFILE` is not followed.
- `conn` (as collected, not the window): the TCP connections between this host and the peer on the listener port, from `netstat -an`: `lip lport pip pport state sendq recvq` (`sendq`/`recvq` in bytes as netstat prints them). First 200.
- `sqlnet` (as collected): one record per parameter, always the same six: `SQLNET.EXPIRE_TIME`, `SQLNET.OUTBOUND_CONNECT_TIMEOUT`, `SQLNET.INBOUND_CONNECT_TIMEOUT`, `SQLNET.RECV_TIMEOUT`, `SQLNET.SEND_TIMEOUT`, `TCP.CONNECT_TIMEOUT`:
  `name`, `set` (true/false), `value` (text as written, null when not set: **not set means the default applies**), `file` (the `sqlnet.ora` read, null when none was found under `$TNS_ADMIN` / `$ORACLE_HOME/network/admin`). A listener
  started with another `TNS_ADMIN` reads another file.
- `ostcp` (as collected): OS tunables: `name`, `value` (text, null when not readable), `tool`. Linux: `sysctl -n` of `net.ipv4.tcp_keepalive_time` (seconds), `_intvl` (seconds), `_probes`, `net.ipv4.tcp_retries2`. AIX: the lines of `no -a` that `sh/os_net_check.sh`
  reads (`tcp_keep*`, `tcp_sendspace`, `tcp_recvspace`, `rfc1323`, `sb_max`; AIX gives `tcp_keepidle` and `tcp_keepintvl` in half seconds: unverified here).
- `ntp` (as collected, **the clock state now, not at the incident**): `tool` (`chronyc tracking`, `ntpq -p`, `timedatectl`, or `lssrc -s xntpd` on AIX), `ref` (the time source: chrony's reference name, ntpq's system peer; null if none), `stratum`, `off` (seconds, **system clock minus the source, positive = this
  host is ahead**; null when unknown or not synchronised), `synced` (`yes`, `no`, or null when the tool cannot say, e.g. `lssrc`), `note`, `at` (collection time). Order: Linux `chronyc`, `ntpq -p`, `timedatectl`; AIX `ntpq -p`, `lssrc -s xntpd`; the first that gives data wins.
  chrony: `System time ... seconds fast|slow of NTP time`, `synced` = `Leap status` is not `Not synchronised` and `Stratum` 1..15. ntpq: the line marked `*` is the system peer; its offset column is in ms with the opposite sign (peer minus local), so `off` = minus that / 1000; no `*` line = `no`.
- `sar` (Linux with sysstat; in the window): rows of the daily sysstat files for `sar -n ETCP` (TCP errors and retransmissions), `TCP`, `DEV` (interfaces) and `EDEV` (interface errors), read separately. `rpt` (ETCP, TCP, DEV or EDEV), `ts` (the time printed in the row, on the file's date),
  `if` (the interface for DEV and EDEV, else null), `m` (an object: sar's own column header -> value, e.g. `"retrans/s":12.50`). **Each row is the average over the interval that ENDS at `ts`**; the interval length is not written (sysstat's default is 10 minutes). Rows from `from` to `to` are kept, plus the first row after `to`
  (the interval that overlaps the end of the window). Per `(src sar, kind)` one `cov`: `first`/`last` = the first and last time the file(s) hold (a day file starts at 00:00 and ends at the last sample), `n` = rows kept, `cap` 2000. A report the file does not have gives `st error` with
  sar's message in `note`, e.g. `Requested activities not available in file /var/log/sa/sa21`; no sysstat file for a day, or one dated another month (`saDD` is reused every month), is named in the note; `LINUX RESTART` lines inside the window are counted in the note. AIX: `skipped`.
  *Relied on:* `LC_ALL=C S_TIME_FORMAT=ISO sar -n <report> -f <file>` prints times as `HH:MM:SS` (24-hour, no AM/PM) and the banner date as `YYYY-MM-DD`, a header line (time first, then the column names) and data rows (time first); `Average:` lines are skipped; files are `saYYYYMMDD` or `saDD` in `$SA_DIR`, `/var/log/sa` or `/var/log/sysstat`.
- `netsamp` (in the window): samples of `sh/net_sampler.sh` (`collect.sh -n <its log>`; the rotated `<log>.1` is read too): `ts` (local time of the host), `off` (the UTC offset the sampler wrote, `+01:00`), `rtt` (round trip of one ping in ms, null when it got no reply), `loss` (true when
  it got none), `retr` (the cumulative TCP retransmit counter: subtract two samples), `sendq` (the largest Send-Q in bytes on a connection to the peer and port). First 5000; `cov netsamp` `first`/`last` = the first and last sample in the files, the sampler's header line is quoted in `note`.

### How the peer address is found (`net.via`, `cov net`)

`-p` wins. Without it: on the **primary** the first destination of `v$archive_dest` whose alias resolved (the `ep` record), with its port unless `-P` was given; on the **standby** the source address of the `PROGRAM=oracle` listener connections (the most frequent one in the window; else the newest in the whole log),
with the standby's own listener port from `lsnrctl status` (`Listening Endpoints Summary`) unless `-P` was given; else the address of a `fal_server` alias. `via` says which. Without any, `cov net` and `cov conn` are `skipped`. The 10 s check itself is unchanged and **ran at collection time**; when `netstat` or `ping` is missing the `cov net` note says that `retr`/`sendq` are 0 placeholders or that `rtt`/`loss` are `?`. Note that this sends ICMP to an address you did not type: `net.via` shows where it came from; `-p` overrides it.

### Where the report shows the records of phase 3 and later

| Record | Shown in |
|---|---|
| standby `tx` | Timeline (lanes "Standby RFS" and "Standby apply, other"), "Standby: wait samples in the window"; the samples inside the SYNC wait that timed out are an Observed row of the incident |
| `ashgap` (standby) | host indicators (a standby sampler gap counts like the primary's), the "Standby host stopped for the whole wait" entry |
| `rfs_ev`, standby `hist_su` | "Standby: RFS write latency" (with `meta.startup`) |
| `dgstatus` | Alert logs table (tagged rows, own tab) |
| `dgproc`, `archgap` | "Standby: Data Guard processes and gaps, as collected" |
| `dest_hist` | the "Destination" tab of the SYNC Remote Write histogram |
| `base_day`, `base_hist` | "Baseline: the same clock interval on previous days" |
| `lsnr_srv` | an Observed row per incident and listener (connections of the other host's address), "Facts to hand over" |
| `sar`, `netsamp` | "Network and OS", in the window: sysstat table, sampler chart; an Observed row per incident; "Facts to hand over" |
| `ep`, `conn`, `sqlnet`, `ostcp` | Configuration, "Network and OS", "Facts to hand over" (all as collected) |
| `ntp`, `net` (incl. `via`) | notice about the clocks (as collected), "Network and OS" (as collected), "Facts to hand over" |
| `lfs_by`, `lfs_sum` | "Who waited" (per incident tab, but `lfs_by` is for the whole window) |
| `aas` | "Active sessions by wait event" (a stacked area over the window, zoomable with the other charts). Supporting evidence: Signals, Explanations and the hand-over texts do not use it |
| `wl` (per minute) | "Who waited": the minutes before the first event against the minutes of the incident |
| `alsync` | "Episodes side by side": the first line after the start of an episode that ends the UNSYNCHRONIZED period |
| `wl_hist` | "Episodes side by side": the redo rate of the AWR interval that contains the start |
| `act` | "Episodes side by side": what was running at the start or began within 10 minutes before it, log switches within 60 s; "Other episodes by day and hour": RMAN commands as bars, the job runs that overlap a start |
| all `cov` records | the coverage table (a skipped source of the other side is not listed) |

## Who waited, active sessions, workload history, ended UNSYNCHRONIZED periods and scheduled activity

Five record types, all optional, each with its own `cov` record (also when its statement failed, `st` `error`, or does not apply to that side, `skipped`). The statements are in `sql/json_primary.sql` and `sql/json_standby.sql`; each stands alone, so a failure costs that record
type and its `cov`, never the `meta` line or another record. On 2026-11-25 the statements of the other four were run against Oracle 19.27.0.0.0 (a CDB root, primary READ WRITE, physical standby MOUNTED) and returned rows; the count statement of the job source failed with ORA-00937 and was corrected. Not exercised there: a host whose UTC offset is not zero, a PDB-level connection, the in-memory path of `lfs_by` with rows, RAC. On 2026-11-26 `collect.sh primary` was run against Oracle 19.27.0.0.0 (a CDB root, primary READ WRITE) over two windows, one served by `v$active_session_history` (`meta.ash` V) and one by the AWR copy (`meta.ash` H). In both, the `aas` statements returned rows (15 records and 21 events found, and 101 records and 26 events found, both capped at 12, with the folded record written with `ev` and `wc` null) and the cov record was written; `check_bundle.py <bundle> collector` passed, and for every minute the sum of `aas.fg` equalled `fg.lgwr + fg.other + fg.cpu`. No statement needed a correction. The standby side was not run.

- `lfs_by`* (in the window, the ASH source in use, `meta.ash`): the `FOREGROUND` samples on `log file sync`, counted three ways. `dim` is `service`, `module` or `machine`; `name` is the value (at most 64 characters, `null` when the column is null; for `service` the name from
  `v$active_services` found by `service_hash` = `name_hash`, else `hash <number>`); `n` samples; `lg` of those, the samples whose blocking session was LGWR (the test of `lfs`); `sess` distinct `session_id, session_serial#`; `a`, `z` first and last sample time. **They are sample counts**: one per session per
  sampling interval (1 s in memory, 10 s in the AWR copy), not durations and not numbers of commits. The 15 groups with the most samples are kept per `dim`. `cov lfs_by`: `first`/`last` = what the ASH source holds (as `lfs`), `n` = groups found over the three dims before the cut, `cap` 15, `capped` true when a dim had more than 15.
  The record cannot be split by incident: it is for the whole window.
- `aas`* (in the window, the ASH source in use, `meta.ash`): ASH samples per minute and wait event, one record for each minute and event that has a sample. `m` (the minute, `YYYY-MM-DD HH:MI`, as `fg.m`), `ev` (`event`, or `ON CPU` when `session_state` is `ON CPU`),
  `wc` (`wait_class`; `CPU` for `ON CPU`, `Other` when the class is null; a sample that is waiting with no event name is written as the event `unknown`), `fg` (samples of `FOREGROUND` sessions), `bg` (samples of every other session type). **Raw sample counts, as in `fg`** (one per session per sampling interval: 1 s in memory, 10 s in the AWR copy): the report divides them by
  the samples per minute of the source (60 or 6) for average active sessions. The ASH source and the window predicate are those of `fg`, and no session type is left out (the background sessions are the `bg` samples), so for every minute the `fg` values of its records add up to `fg.lgwr + fg.other + fg.cpu`.
  The 12 events with the most samples (`fg + bg`) over the whole window are kept by name (`ON CPU` counts as one event); all the others are added up into one record per minute with `ev` and `wc` null, so that the sums per minute still hold. No record has `fg` and `bg` both 0. Like `fg`, the record carries no `side`:
  it belongs to the side of the bundle. `cov aas`: `first`/`last` = what the ASH source holds (as `lfs`), `n` = distinct events found in the window before the fold, `cap` 12, `capped` true when more than 12 were found.
- `wl_hist`* (the last `-d` days, AWR): one record per AWR snapshot interval from `dba_hist_sysmetric_summary` (`group_id` 2, this database and instance): `b`, `e` (`begin_time`, `end_time`, `YYYY-MM-DD HH:MI`), `redo` (average of `Redo Generated Per Sec` over the interval, MB/s, rounded as `wl.redo`), `redo_max` (its `maxval`, the largest 1 minute value in the interval, MB/s),
  `txn` (average of `User Transaction Per Sec`). An average over an interval of the snapshot length, not a rate at one instant. Newest 1500 kept. `cov wl_hist`: `first`/`last` = the oldest begin and newest end the view holds, `n` = intervals (snapshots) in the lookback, `cap` 1500.
- `alsync` (both sides, the same lookback and the same pass over the alert log as `alhist`): the lines that end an UNSYNCHRONIZED period of a destination: `LAD:n is SYNCHRONIZED` and `LAD:n ... level SYNCHRONIZED` (`dgsync()` in `sh/dglib.sh`; the same condition between `sync-pattern` markers in the SQL), never a line that is also in the history list. `ts` (to the second), `msg` (at most 200). Newest 300 kept.
  `cov alsync` has `kind` `sql` (primary, `v$diag_alert_ext`) or `text` (the text alert log) like `alhist`; `first`/`last` and `n`, `cap` 300 as there. They lie in the window as well as outside it.
- `act`: scheduled activity in the lookback. Three kinds, each its own statement and its own `cov` (`src` `act`, `kind` `rman`, `job` or `logsw`; `first`/`last` = the oldest and newest row the view holds, `n` = rows in the lookback before the cut, `cap`, `capped`). Times are `YYYY-MM-DD HH:MI:SS`, local time of the host that collected.
  - `kind` `rman` (both sides, works on a mounted standby): `v$rman_status` rows of type `COMMAND`: `name` (`operation || ' ' || object_type`, trimmed), `a` (`start_time`), `z` (`end_time`, `null` while the command has no end time), `st` (`status`). Newest 500; `cap` 500.
  - `kind` `job` (primary): `cdb_scheduler_job_run_details`: `name` (`owner.job_name`), `con` (`con_id`), `a` (`actual_start_date`, converted to the UTC offset the database host has when the statement runs and cut to whole seconds), `z` (`a` + `run_duration`), `st` (`status`), `freq` (false) and `n` (1). **A job with more than 24 runs a day on average over the lookback
    is written as one summary record instead of its runs**: `freq` true, `n` its runs, `a` its first start, `z` its last start, `st` null. Newest 2000 run records kept (the summaries are not cut); `cap` 2000, `capped` true when more run records than that were found, `n` = all rows in the lookback (the runs of the summarised jobs included).
    The offset is the one at collection time: a run from before a daylight-saving change inside the lookback is off by that change.
  - `kind` `logsw` (primary): `v$log_history` rows: `a` (`first_time`: the time the log sequence was opened, i.e. the switch into it), `thr` (`thread#`), `seq` (`sequence#`). Newest 5000; `cap` 5000.
  - On the standby `job` and `logsw` are `skipped` ("not collected on the standby"). `lfs_by`, `aas` and `wl_hist` are `skipped` there as well.
  A list of events is not a sample: the newest row of a view says nothing about where the view ends, so the report treats a bundle collected after an interval as holding its end (as for a text log) and uses only `first` (and, when `capped`, the oldest record that was kept) for how far back the view reaches.

## `clock`

`{"t":"clock","side":"standby","utc_off":"+01:00","src":"alert log"}`: the UTC offset the host used inside the
window. `src`, in order of preference:

1. `alert log`: the offset of an alert log row in the window (text lines carry it; through SQL it is
   `to_char(originating_timestamp,'TZH:TZM')`). When the offset changes inside the window, `src` says
   `alert log, offset changes inside the window` and `utc_off` is one of them (the first row of the text file; the
   lowest offset string through SQL).
2. `listener log`: the ISO timestamp line (`2026-11-21T09:01:46.464031+00:00`) of a listener log entry in the window.
3. `systimestamp at collection time` (or `date at collection time` without a database): the offset when the bundle
   was collected, **which DST may have changed since the incident**. `utc_off` is null when nothing is available.

## `lfs`, `lfs_sum`, `ashgap`: commit waits and sampler gaps (v2, primary)

These come from the ASH source in use (`meta.ash` V = 1 s samples in memory, H = the 10 s AWR copy). Both views keep `sample_id`, which advances once per
second of sampling, and `time_waited`, which ASH writes on the **last sample of a wait only** (earlier samples of the same wait carry 0).

- `lfs`: one record per `log file sync` wait, keyed by session (`sid`), serial# (`ser`) and the wait sequence `seq`. `seq` wraps, so samples of one key
  more than 3 s apart (V) or 25 s apart (H) are different waits. `a`, `z` = first and last sample time, `n` = samples, `tw` = the largest `time_waited`
  in microseconds (**null** when no sample had a value, **0** kept as 0), `lg` = 1 when the blocking session was LGWR. The longest 200 waits are kept (by
  `time_waited`, else by the time from first to last sample); `cov lfs` has the number found in `n` and `capped`. A wait is exactly `tw` long when `tw > 0`
  (it ended within one second after its last sample); without it the wait lasted at least `z - a` and less than `z - a` plus two sampling intervals.
- `lfs_sum`: one record with `waits` (all waits found, also those cut by the cap), `lgwr_waits`, and the peak: `pk_n` sessions in `log file sync` in one
  sample (at `pk_at`), `pk_lg` the same with LGWR as the blocker (at `pk_lg_at`).
- `ashgap`: `ia`/`a` and `iz`/`z` are sample_id and sample_time of two consecutive samples where the clock advanced more than 2 s beyond one second per
  `sample_id` step: the instance was not sampling normally for about that long (a paused host or VM, a starved instance, a clock step). The largest 50 are kept.
  **The 1 s per `sample_id` rule is unverified for the AWR copy** (the report treats the check as unusable when gaps are more than a fifth of the samples).
  `cov ashgap`: `first`/`last` = the samples read (one minute around the window, so a sample on each side of an interval can be found), `samples` = how
  many, `n` = gaps found. No gap rows plus `first <= start` and `last >= end` is the evidence that the sampler ran through an interval.

Bundles without these records (v1, and v2 made before them) still work: the report then shows the per-10 s `fg10` counts, says that no commit wait length is
known, and cannot check the sampler.

## `cov`: coverage

One record per source and side, so a reader can tell "nothing happened" from "nothing was collected".

`{"t":"cov","side":"primary","src":"ash","kind":"H","st":"ok","first":"2026-11-06 09:00:03","last":"2026-11-14 08:59:53","n":2284,"cap":null,"capped":false,"note":"..."}`

- `st`: `ok` rows in the window, `empty` read fine and nothing in the window, `error` the read failed (`note` has the
  error), `skipped` not read (`note` says why: sqlplus not found, file not readable, option not given, not collected on a standby).
- `first`, `last`: the earliest and latest data **the source holds** (full timestamp or null). Compare with the window
  to know whether the source reached back far enough.
- `n`: rows or lines inside the window. Where a cap applies, `n` is the number found **before** the cut.
- `cap`: the row limit applied (null = none). `capped`: true when `n` exceeds it, or when another limit cut the
  source (see `trace`). `note`: short reason, path or error text.
- Within a side, `(src, kind)` is unique.

| src | What it is | first / last | n | cap |
|---|---|---|---|---|
| `database` | did sqlplus connect and write the meta line | null | 1 or 0 | |
| `ash` (`kind` V or H) | the ASH source in use (the standby: `V` only, in memory) | min / max `sample_time` it holds | samples in the window | |
| `awr_snap` | AWR snapshots | oldest begin / newest end held | snapshots overlapping the window | |
| `sysmetric` | 1 min metrics (`wl`) | min / max `begin_time` held | minutes in the window | |
| `lfs` | the `lfs` and `lfs_sum` records | min / max `sample_time` the ASH source holds | waits found | 200 |
| `lfs_by`* | the `lfs_by` records | as `lfs` | groups found over the three lists | 15 per list |
| `aas`* | the `aas` records | as `lfs` | distinct events found in the window, before the fold | 12 |
| `ashgap` | the `ashgap` records | first / last sample read (a minute around the window) | gaps found (`samples` = samples read) | 50 |
| `alert_sql` | `v$diag_alert_ext` (the `alert` records) | min / max row inside the `-d` lookback | rows in the window | |
| `alert_text` | text alert log (`alert` records) | first / last timestamp in the file | messages in the window | |
| `tx` | the `tx` records | what ASH holds | primary: transport wait samples found; standby: redo-related samples found (before the cap) | standby 5000 |
| `alhist` (`kind` sql or text) | the history list (routine `RT_PMODE` lines left out, see below) | first / last timestamp inside the `-d` lookback (text: last timestamp of the file) | matches found | 300 |
| `alsync` (`kind` sql or text) | the lines that end an UNSYNCHRONIZED period | as `alhist` | matches found | 300 |
| `wl_hist`* | workload per AWR snapshot interval | oldest begin / newest end the view holds | intervals in the lookback | 1500 |
| `act` (`kind` rman, job, logsw) | scheduled activity: RMAN commands (both sides), job runs\*, log switches\* | oldest / newest row the view holds | rows in the lookback before the cut | 500 / 2000 / 5000 |
| `dgstatus` | `v$dataguard_status` | oldest / newest row the view holds | rows in the window | 500 |
| `dest_hist` | `v$redo_dest_resp_histogram` | as collected | rows | |
| `base_hist` | the baseline (`base_day`, `base_hist`) | the AWR span held | days with a usable histogram delta | |
| `rfs_ev`, `rfs_hist` (standby) | RFS events since startup | `meta.startup` / collection time | events / buckets | |
| `dgproc`, `archgap` (standby) | processes and gaps now | as collected | rows | |
| `trace` (+ `files`) | background traces, `files` = files scanned | first / last `***` timestamp in them | error lines in the window | 400 |
| `listener` | listener log | first / last timestamp in the file | timestamped lines in the window | |
| `lsnr_ref` | refused logins | as `listener` | refusals in the window | 500 |
| `lsnr_srv` | server-to-server connections (`PROGRAM=oracle`) | as `listener` | connections in the window | 500 |
| `cid` | CONNECTION_ID lookup (`-c`) | as `listener` | hits | 2000 |
| `ep` | endpoints | as collected | aliases | |
| `conn` | TCP connections to the peer | as collected | connections | 200 |
| `sqlnet` | the six `sqlnet.ora` timeouts | as collected | 6 | |
| `ostcp` | OS TCP tunables | as collected | tunables | |
| `ntp` | clock synchronisation state | as collected | 1 or 0 | |
| `sar` (`kind` ETCP, TCP, DEV, EDEV) | sysstat history | first / last sample time of the file(s) | rows kept | 2000 |
| `netsamp` | `net_sampler.sh` samples (`-n`) | first / last sample in the files | samples in the window | 5000 |
| `net` | network check | `at` | 1 or 0 | |

**The history list (`alhist`) leaves out routine lines.** One list of patterns is used by the SQL (`json_primary.sql`, `20_alert_log.sql`), `collect.sh` and `alert_log_scan.sh` (`sh/dglib.sh`): a line with `UNSYNCHRONIZED` counts unless it is an `RT_PMODE: PRIMARY` or `RT_PMODE: PHYSICAL` line or ends `level UNSYNCHRONIZED reason ASYNC configuration`;
the other lines are `ORA-16198`, `ORA-03135`, `ORA-03113`, `ORA-16055`, `ORA-16191`, `TNS-12535`, `TNS-12170`, `TNS-12609` and `Possible network disconnect`. The lookback is the last `-d` days for the SQL and for the text file alike.
The `alsync` records come from the same pass: a second condition, `sync-pattern` in the SQL (`json_primary.sql` twice, `list_alerts.sql`) and `dgsync()` in `sh/dglib.sh` (`LAD:n ... level SYNCHRONIZED`, `LAD:n is SYNCHRONIZED`), applied to the lines that are not in the history list.

Limits besides the row caps are recorded in `note` and set `capped`: `trace` only looks at files modified in the last
45 days, so `capped` is true when the window starts before that limit and a file newer than the window start was
skipped. `alert_sql` is read through the `-d` lookback (default 30 days); when the window starts before that, `note`
says so, and with no row seen `st` is `error`, not `empty`.

`collect.sh` writes a `cov` record for every source, also when the statement failed (`st:"error"`), so a side's bundle always has the same set: `database ash awr_snap sysmetric lfs ashgap tx alert_sql alert_text alhist dgstatus dest_hist
base_hist rfs_ev rfs_hist dgproc archgap trace listener lsnr_ref lsnr_srv cid ep conn sqlnet ostcp ntp sar` (four records, `kind` ETCP TCP DEV EDEV) `netsamp net` and, from the collector that writes the records of the last section, `lfs_by aas wl_hist alsync` (`kind` sql on the primary, text where a text alert log is read) and `act` (three records: `kind` rman job logsw). A source that belongs to the other side is `skipped` ("not collected on the standby" / "on the primary"):
on the standby `awr_snap sysmetric lfs lfs_by aas wl_hist alert_sql dest_hist base_hist` and `act` of `kind` job and logsw, on the primary `rfs_ev rfs_hist dgproc archgap`. `ash` and `ashgap` are collected on the standby now (they were `skipped` there in bundles from before phase 3).

**How the report uses `cov`.** A source supports "none" or "ruled out" for an interval only when its record exists, `st` is `ok` or `empty`, `first` is at or
before the start of the interval, `last` is at or after its end (a text log may end earlier when the bundle was collected after the interval: nothing was logged since),
and `capped` is false. Anything else is shown as "Not checked" with the reason. Bundles with no `cov` records (v1) give coverage unknown, so nothing is ruled out on absence.
For `lfs_by`, `aas` and the lookback sources `wl_hist`, `alsync` and `act` an `error` record means the statement failed: the report reads it as "not checked" with the note of the record, never as "none" or "not covered", also when records of that source arrived (the row statement of the job source can run when its count statement fails; the records are still drawn, nothing is said about what they cover).
A capped lookback source (`capped` true; the newest records are kept) holds from its oldest kept record on, which the report takes from the records themselves, not from `first`; the Coverage table shows it as "kept from" beside `first`/`last`.
Exit status of `collect.sh` is 1 when sqlplus connected nowhere (no meta line); the log scans still run.

## v1 bundles (`"v":1`)

- Times were times of day: `HH:MI:SS.FFF`, `HH:MI`, `HH:MI:SS`; the day is the window's day (`from` in the header).
  Exceptions: `net.at` was a time of day on the **collection** day, `cid_hit.ts` was in the listener's format
  `13-NOV-2026 20:40:07`, `alhist.ts` was already a full date-time.
- The window had to lie within one day; log scans compared `HH:MI` (the last minute counted in full).
- No `clock` and no `cov` records. `cid_hit.cid` held the return code instead of the CONNECTION_ID (a collector bug),
  so v1 lookups never matched.
- sqlplus errors were hidden: `database: done` was printed whatever happened.

-- HTML report data, STANDBY side: one JSON object per line, appended to a bundle file (format v2, see docs/bundle-format.md).
-- Called by sh/collect.sh. Read-only; works with the standby only MOUNTED (no DBA_HIST_*, no v$diag_alert_ext). Times are full local date-times: 'YYYY-MM-DD HH:MI:SS'.
-- Args: 1 = from 'YYYY-MM-DD HH24:MI:SS'  2 = to  3 = history days (the lookback of the act records)  4 = baseline days (unused)  5 = bundle file (appended; keep it last)
set termout off echo off feedback off verify off heading off pagesize 0 linesize 32767
set trimspool on trimout on tab off
whenever sqlerror continue
define t_from   = "&1"
define t_to     = "&2"
define hist_days = "&3"
define out_file = "&5"

-- Variables filled by the queries below, each with a default (an undefined one would make sqlplus prompt; stdin is /dev/null). -1 = the statement failed.
define ash_first = "-"
define ash_last  = "-"
define ash_n     = -1
define tx_n      = -1
define ag_n      = -1
define ag_s      = -1
define ag_a      = "-"
define ag_z      = "-"
define rfs_n     = -1
define rh_n      = -1
define dgs_n     = -1
define dgs_first = "-"
define dgs_last  = "-"
define dgp_n     = -1
define gap_n     = -1
define su_time   = "-"
define ar_n      = -1
define ar_first  = "-"
define ar_last   = "-"
column ash_first new_value ash_first noprint
column ash_last  new_value ash_last  noprint
column ash_n     new_value ash_n     noprint
column tx_n      new_value tx_n      noprint
column ag_n      new_value ag_n      noprint
column ag_s      new_value ag_s      noprint
column ag_a      new_value ag_a      noprint
column ag_z      new_value ag_z      noprint
column rfs_n     new_value rfs_n     noprint
column rh_n      new_value rh_n      noprint
column dgs_n     new_value dgs_n     noprint
column dgs_first new_value dgs_first noprint
column dgs_last  new_value dgs_last  noprint
column dgp_n     new_value dgp_n     noprint
column gap_n     new_value gap_n     noprint
column su_time   new_value su_time   noprint
column ar_n      new_value ar_n      noprint
column ar_first  new_value ar_first  noprint
column ar_last   new_value ar_last   noprint

spool &out_file append

-- startup is when the counters of v$system_event and v$event_histogram_micro (the rfs_ev and hist_su records below) started
select json_object('t' value 'meta', 'side' value 'standby', 'db' value d.name, 'uniq' value d.db_unique_name,
         'role' value d.database_role, 'open' value d.open_mode, 'pmode' value d.protection_mode,
         'plevel' value d.protection_level, 'inst' value i.instance_name, 'host' value i.host_name,
         'ver' value i.version_full, 'plat' value d.platform_name, 'from' value '&t_from', 'to' value '&t_to',
         'gen' value to_char(sysdate,'YYYY-MM-DD HH24:MI:SS'), 'tz' value to_char(systimestamp,'TZH:TZM'),
         'startup' value to_char(i.startup_time,'YYYY-MM-DD HH24:MI:SS')
         returning varchar2(4000))
from   v$database d, v$instance i;

select to_char(startup_time, 'YYYY-MM-DD HH24:MI:SS') su_time from v$instance;

-- parameters that name the peer (fal_server) and the transport configuration, as on the primary
select json_object('t' value 'param', 'side' value 'standby', 'name' value name, 'value' value substr(value, 1, 1000) returning varchar2(4000))
from   v$parameter
where  name in ('fal_server', 'log_archive_config');

-- sequences received in the window (FAL = YES: fetched as a gap)
select json_object('t' value 'arch', 'side' value 'standby', 'dest' value l.dest_id, 'thr' value l.thread#, 'seq' value l.sequence#,
         'first' value to_char(l.first_time,'YYYY-MM-DD HH24:MI:SS'), 'next' value to_char(l.next_time,'YYYY-MM-DD HH24:MI:SS'),
         'done' value to_char(l.completion_time,'YYYY-MM-DD HH24:MI:SS'), 'creator' value l.creator, 'reg' value l.registrar,
         'fal' value l.fal, 'mb' value round(l.blocks * l.block_size / 1048576, 1))
from   v$archived_log l
where  l.completion_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by l.completion_time;

select json_object('t' value 'srl', 'thr' value thread#, 'grp' value group#, 'seq' value sequence#, 'st' value status,
         'mb' value round(bytes / 1048576))
from   v$standby_log
order  by thread#, group#;

select json_object('t' value 'dgstat', 'name' value name, 'value' value value, 'unit' value unit)
from   v$dataguard_stats;

-- ASH on the standby: v$active_session_history only (in memory, so it reaches back minutes to hours: ash_first says how far). One row: what it holds, samples
-- in the window, and how many of them are waits of the redo-related processes (tx_n). The RFS processes that receive redo carry no tag of their own: their
-- program is the client program on the PRIMARY, "oracle@<primary host> (TNS V1-V3)" (anchored to "oracle@": sqlplus@ or rman@ sessions are not taken for RFS; an Oracle database link
-- from another database also looks like this).
select nvl(to_char(min(sample_time), 'YYYY-MM-DD HH24:MI:SS'), '-') ash_first, nvl(to_char(max(sample_time), 'YYYY-MM-DD HH24:MI:SS'), '-') ash_last,
       count(case when sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') then 1 end) ash_n,
       count(case when sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
                       and session_state = 'WAITING'
                       and regexp_like(program, '\((PR[0-9A-Za-z]+|MRP0|ARC[0-9A-Za-z]|TT[0-9A-Za-z]+|TMON|LGWR|LG[0-9]+|NSS[0-9A-Za-z]|DBW[0-9A-Za-z]|CKPT)\)|^oracle@[^ ]+ \(TNS V1-V3\)') then 1 end) tx_n
from  (select sample_time, session_id, session_state, program, event, seq#, time_waited from v$active_session_history);

-- redo-related wait samples, same shape as the primary tx records plus sid (several RFS processes share the program text). The 5000 kept are the transport
-- processes first (RFS, TT, ARC, TMON, LGWR, NSS), then recovery / DBWR / CKPT; tx_n has the number found.
select json_object('t' value 'tx', 'side' value 'standby', 'ts' value to_char(sample_time, 'YYYY-MM-DD HH24:MI:SS.FF3'),
         'p' value regexp_substr(program, '\(([^)]+)\)', 1, 1, null, 1), 'ev' value event, 'seq' value seq#, 'tw' value time_waited, 'sid' value session_id
         returning varchar2(4000))
from  (select sample_time, session_id, program, event, seq#, time_waited,
              row_number() over (order by case when regexp_like(program, '\((TT[0-9A-Za-z]+|ARC[0-9A-Za-z]|TMON|LGWR|LG[0-9]+|NSS[0-9A-Za-z])\)|^oracle@[^ ]+ \(TNS V1-V3\)') then 0 else 1 end,
                                          sample_time, session_id) rn
       from   v$active_session_history
       where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
       and    session_state = 'WAITING'
       and    regexp_like(program, '\((PR[0-9A-Za-z]+|MRP0|ARC[0-9A-Za-z]|TT[0-9A-Za-z]+|TMON|LGWR|LG[0-9]+|NSS[0-9A-Za-z]|DBW[0-9A-Za-z]|CKPT)\)|^oracle@[^ ]+ \(TNS V1-V3\)'))
where  rn <= 5000
order  by sample_time, session_id;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'ash', 'kind' value 'V',
         'st' value case when &ash_n < 0 then 'error' when &ash_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ash_first' = '-' then null else '&ash_first' end, 'last' value case when '&ash_last' = '-' then null else '&ash_last' end,
         'n' value greatest(&ash_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &ash_n < 0 then 'the statement over v$active_session_history failed' else 'v$active_session_history on the standby, in memory only; first/last = what it holds' end
         returning varchar2(4000))
from   dual;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'tx',
         'st' value case when &tx_n < 0 then 'error' when &tx_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ash_first' = '-' then null else '&ash_first' end, 'last' value case when '&ash_last' = '-' then null else '&ash_last' end,
         'n' value greatest(&tx_n, 0), 'cap' value 5000, 'capped' value case when &tx_n > 5000 then 'true' else 'false' end format json,
         'note' value case when &tx_n < 0 then 'the statement over v$active_session_history failed' else 'wait samples of PRnn, MRP0, ARCn, TTnn, TMON, LGWR, LGnn, NSSn, DBWn, CKPT and of programs "oracle@<host> (TNS V1-V3)" (the RFS processes; database links also look like that); transport processes kept first when capped' end
         returning varchar2(4000))
from   dual;

-- sampler gaps on the standby (same check as the primary: consecutive samples whose clock difference exceeds the sample_id difference x 1 s by more than 2 s).
-- No WITH clause on purpose: a subquery factoring clause that is used more than once is materialised in a temporary table, which a MOUNTED database cannot create
-- (ORA-01219). Nested inline views are never materialised.
select json_object('t' value 'ashgap', 'side' value 'standby', 'ia' value id1, 'a' value to_char(t1, 'YYYY-MM-DD HH24:MI:SS.FF3'),
         'iz' value id2, 'z' value to_char(t2, 'YYYY-MM-DD HH24:MI:SS.FF3') returning varchar2(4000))
from  (select id1, id2, t1, t2, row_number() over (order by secs - (id2 - id1) desc, t1) rn
       from  (select id1, id2, t1, t2,
                     extract(day from (t2 - t1)) * 86400 + extract(hour from (t2 - t1)) * 3600 + extract(minute from (t2 - t1)) * 60 + extract(second from (t2 - t1)) secs
              from  (select sample_id id2, t t2, lag(sample_id) over (order by t) id1, lag(t) over (order by t) t1
                     from  (select sample_id, min(sample_time) t
                            from   v$active_session_history
                            where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
                            group  by sample_id))
              where  id1 is not null and id2 > id1)
       where  secs - (id2 - id1) > 2)
where  rn <= 50
order  by t1;

-- the gap count, the samples read and their first and last time, in one pass over the same inline views (the count of gaps = rows with a clock difference above the sample_id difference + 2 s)
select count(case when id1 is not null and id2 > id1
                   and extract(day from (t2 - t1)) * 86400 + extract(hour from (t2 - t1)) * 3600 + extract(minute from (t2 - t1)) * 60 + extract(second from (t2 - t1)) - (id2 - id1) > 2 then 1 end) ag_n,
       count(*) ag_s,
       nvl(to_char(min(t2), 'YYYY-MM-DD HH24:MI:SS'), '-') ag_a, nvl(to_char(max(t2), 'YYYY-MM-DD HH24:MI:SS'), '-') ag_z
from  (select sample_id id2, t t2, lag(sample_id) over (order by t) id1, lag(t) over (order by t) t1
       from  (select sample_id, min(sample_time) t
              from   v$active_session_history
              where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
              group  by sample_id));

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'ashgap',
         'st' value case when &ag_n < 0 then 'error' when &ag_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ag_a' = '-' then null else '&ag_a' end, 'last' value case when '&ag_z' = '-' then null else '&ag_z' end,
         'n' value greatest(&ag_n, 0), 'cap' value 50, 'capped' value case when &ag_n > 50 then 'true' else 'false' end format json,
         'note' value case when &ag_n < 0 then 'the statement over v$active_session_history failed' else 'gaps over 2 s between consecutive ASH samples (V), 1 s per sample_id; first/last = samples read, one minute around the window' end,
         'samples' value greatest(&ag_s, 0) returning varchar2(4000))
from   dual;

-- RFS (redo receive) events since instance startup, from v$system_event: waits, timeouts, total and average time in microseconds. NOT limited to the window.
select count(*) rfs_n from (select event, total_waits, total_timeouts, time_waited_micro from v$system_event) where event like 'RFS%' and total_waits > 0;

select json_object('t' value 'rfs_ev', 'side' value 'standby', 'ev' value event, 'n' value total_waits, 'tmo' value total_timeouts, 'us' value time_waited_micro,
         'avg_us' value round(time_waited_micro / nullif(total_waits, 0), 1) returning varchar2(4000))
from   v$system_event
where  event like 'RFS%' and total_waits > 0
order  by event;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'rfs_ev',
         'st' value case when &rfs_n < 0 then 'error' when &rfs_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&su_time' = '-' then null else '&su_time' end, 'last' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value greatest(&rfs_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &rfs_n < 0 then 'the v$system_event statement failed' else 'v$system_event, RFS events, cumulative since instance startup (first = startup, last = collection time), not limited to the window' end
         returning varchar2(4000))
from   dual;

-- the same events as latency buckets from v$event_histogram_micro, cumulative since startup (same fields as the primary hist_su records)
select count(*) rh_n from (select event, wait_time_format, wait_time_micro, wait_count from v$event_histogram_micro) where event like 'RFS%' and wait_count > 0;

select json_object('t' value 'hist_su', 'side' value 'standby', 'ev' value event, 'b' value wait_time_format, 'us' value wait_time_micro, 'n' value wait_count)
from   v$event_histogram_micro
where  event like 'RFS%' and wait_count > 0
order  by event, wait_time_micro;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'rfs_hist',
         'st' value case when &rh_n < 0 then 'error' when &rh_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&su_time' = '-' then null else '&su_time' end, 'last' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value greatest(&rh_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &rh_n < 0 then 'the v$event_histogram_micro statement failed' else 'v$event_histogram_micro, RFS events, cumulative since instance startup (first = startup, last = collection time), not limited to the window' end
         returning varchar2(4000))
from   dual;

-- v$dataguard_status rows in the window (in memory, lost at restart: first/last = the oldest and newest row the view holds). Newest 500 of the window kept.
select count(case when timestamp between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS') then 1 end) dgs_n,
       nvl(to_char(min(timestamp), 'YYYY-MM-DD HH24:MI:SS'), '-') dgs_first, nvl(to_char(max(timestamp), 'YYYY-MM-DD HH24:MI:SS'), '-') dgs_last
from  (select timestamp, facility, severity, dest_id, error_code, message_num, message from v$dataguard_status);

select json_object('t' value 'dgstatus', 'side' value 'standby', 'ts' value to_char(timestamp, 'YYYY-MM-DD HH24:MI:SS'), 'facility' value facility,
         'severity' value severity, 'dest' value dest_id, 'err' value error_code, 'msg' value substr(message, 1, 300) returning varchar2(4000))
from  (select timestamp, facility, severity, dest_id, error_code, message,
              row_number() over (order by timestamp desc, message_num desc) rn
       from   v$dataguard_status
       where  timestamp between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS'))
where  rn <= 500
order  by rn desc;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'dgstatus',
         'st' value case when &dgs_n < 0 then 'error' when &dgs_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&dgs_first' = '-' then null else '&dgs_first' end, 'last' value case when '&dgs_last' = '-' then null else '&dgs_last' end,
         'n' value greatest(&dgs_n, 0), 'cap' value 500, 'capped' value case when &dgs_n > 500 then 'true' else 'false' end format json,
         'note' value case when &dgs_n < 0 then 'the v$dataguard_status statement failed' else 'v$dataguard_status, in memory (lost at restart); first/last = oldest and newest row it holds, newest 500 of the window kept' end
         returning varchar2(4000))
from   dual;

-- Data Guard processes and archive gaps as collected now
select count(*) dgp_n from (select name, pid, role, action, client_pid, client_role, thread#, sequence#, block#, block_count, dest_id, proc_time from v$dataguard_process);

select json_object('t' value 'dgproc', 'side' value 'standby', 'name' value name, 'pid' value pid, 'role' value role, 'action' value action,
         'client_pid' value client_pid, 'client_role' value client_role, 'thr' value thread#, 'seq' value sequence#, 'block' value block#,
         'blocks' value block_count, 'dest' value dest_id, 'since' value to_char(proc_time, 'YYYY-MM-DD HH24:MI:SS') returning varchar2(4000))
from   v$dataguard_process
order  by role, name;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'dgproc',
         'st' value case when &dgp_n < 0 then 'error' when &dgp_n > 0 then 'ok' else 'empty' end,
         'first' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value greatest(&dgp_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &dgp_n < 0 then 'the v$dataguard_process statement failed' else 'v$dataguard_process as collected; first = last = collection time' end
         returning varchar2(4000))
from   dual;

select count(*) gap_n from (select thread#, low_sequence#, high_sequence# from v$archive_gap);

select json_object('t' value 'archgap', 'side' value 'standby', 'thr' value thread#, 'low' value low_sequence#, 'high' value high_sequence# returning varchar2(4000))
from   v$archive_gap
order  by thread#;

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'archgap',
         'st' value case when &gap_n < 0 then 'error' when &gap_n > 0 then 'ok' else 'empty' end,
         'first' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value greatest(&gap_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &gap_n < 0 then 'the v$archive_gap statement failed' else 'v$archive_gap as collected (empty = no gap at collection time); first = last = collection time' end
         returning varchar2(4000))
from   dual;

-- RMAN commands in the lookback (act, kind rman): v$rman_status is read from the control file, so it works on a MOUNTED standby. Same record and coverage as the primary: name = operation and object type,
-- a/z = start and end time (z is null while the command has no end time), st = status; newest 500 kept; first/last = the oldest and newest start time the view holds, n = rows in the lookback before the cut.
-- No WITH clause (see above).
select json_object('t' value 'act', 'side' value 'standby', 'kind' value 'rman', 'name' value substr(trim(operation || ' ' || object_type), 1, 100),
         'a' value to_char(start_time, 'YYYY-MM-DD HH24:MI:SS'), 'z' value to_char(end_time, 'YYYY-MM-DD HH24:MI:SS'), 'st' value status returning varchar2(4000))
from  (select operation, object_type, start_time, end_time, status, row_number() over (order by start_time desc, operation desc) rn
       from   v$rman_status
       where  row_type = 'COMMAND'
       and    start_time > sysdate - &hist_days)
where  rn <= 500
order  by start_time, operation;

select count(case when start_time > sysdate - &hist_days then 1 end) ar_n,
       nvl(to_char(min(start_time), 'YYYY-MM-DD HH24:MI:SS'), '-') ar_first, nvl(to_char(max(start_time), 'YYYY-MM-DD HH24:MI:SS'), '-') ar_last
from  (select start_time from v$rman_status where row_type = 'COMMAND');

select json_object('t' value 'cov', 'side' value 'standby', 'src' value 'act', 'kind' value 'rman',
         'st' value case when &ar_n < 0 then 'error' when &ar_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ar_first' = '-' then null else '&ar_first' end, 'last' value case when '&ar_last' = '-' then null else '&ar_last' end,
         'n' value greatest(&ar_n, 0), 'cap' value 500, 'capped' value case when &ar_n > 500 then 'true' else 'false' end format json,
         'note' value case when &ar_n < 0 then 'the v$rman_status statement failed' else 'v$rman_status, rows of type COMMAND, lookback &hist_days days, newest 500 kept; first/last = the oldest and newest start time the view holds' end
         returning varchar2(4000))
from   dual;

spool off
exit

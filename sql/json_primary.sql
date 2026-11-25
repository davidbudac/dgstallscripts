-- HTML report data, PRIMARY side: one JSON object per line, appended to a bundle file (format v2, see docs/bundle-format.md).
-- Called by sh/collect.sh. Read-only. Every time is a full local date-time: 'YYYY-MM-DD HH:MI:SS'.
-- Args: 1 = from 'YYYY-MM-DD HH24:MI:SS'  2 = to  3 = history days  4 = baseline days (0 = none)  5 = bundle file (appended; keep it last)
set termout off echo off feedback off verify off heading off pagesize 0 linesize 32767
set trimspool on trimout on tab off
whenever sqlerror continue
define t_from    = "&1"
define t_to      = "&2"
define hist_days = "&3"
define base_days = "&4"
define out_file  = "&5"

-- Variables filled by the queries below. Each has a default: an undefined one would make sqlplus prompt, and stdin is /dev/null.
define ash_src   = "H"
define snap_lo   = 0
define snap_hi   = 0
define al_first  = "-"
define al_last   = "-"
define al_win    = -1
define al_hist   = -1
define al_sync   = -1
define al_off1   = "-"
define al_off2   = "-"
define rac_cluster = "-"
define rac_inst  = -1
column rac_cluster new_value rac_cluster noprint
column rac_inst new_value rac_inst noprint
column snap_lo  new_value snap_lo  noprint
column snap_hi  new_value snap_hi  noprint
column al_first new_value al_first noprint
column al_last  new_value al_last  noprint
column al_win   new_value al_win   noprint
column al_hist  new_value al_hist  noprint
column al_sync  new_value al_sync  noprint
column al_off1  new_value al_off1  noprint
column al_off2  new_value al_off2  noprint

-- The spool is open from here on: an ORA- error in any statement below lands in the bundle (the report lists it as a failed query).
-- The noprint selects below leave empty lines in it; readers skip those.
spool &out_file append

-- oldest and newest AWR snapshot: bounds the min/max scans of the coverage records
select nvl(min(snap_id), 0) snap_lo, nvl(max(snap_id), 0) snap_hi from dba_hist_snapshot where dbid = (select dbid from v$database);

-- RAC detection, in statements of their own: a failure here leaves the defaults and must not cost the meta line below. One row each, always.
select nvl(max(upper(value)), '-') rac_cluster from v$parameter where name = 'cluster_database';
select count(*) rac_inst from gv$instance;

-- ONE pass over v$diag_alert_ext for the coverage records: what it holds, rows in the window, matches for the history
-- list (I) and for the lines that end an UNSYNCHRONIZED period (S, never a line that is also in the history list), UTC offset of the rows
-- in the window. Same lower bound as the history query below, so a window older than the -d lookback is not covered by it (alert_sql then says so).
select to_char(min(originating_timestamp), 'YYYY-MM-DD HH24:MI:SS') al_first,
       to_char(max(originating_timestamp), 'YYYY-MM-DD HH24:MI:SS') al_last,
       count(case when cast(originating_timestamp as timestamp)
                       between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') then 1 end) al_win,
       count(case when k = 'I' then 1 end) al_hist,
       count(case when k = 'S' then 1 end) al_sync,
       min(case when cast(originating_timestamp as timestamp)
                     between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
                then to_char(originating_timestamp, 'TZH:TZM') end) al_off1,
       max(case when cast(originating_timestamp as timestamp)
                     between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
                then to_char(originating_timestamp, 'TZH:TZM') end) al_off2
from  (select originating_timestamp,
              case when (
       -- hist-pattern: begin
       case when message_text like '%UNSYNCHRONIZED%'
                 and not (regexp_like(message_text, 'RT_PMODE:[[:space:]]+(PRIMARY|PHYSICAL)[[:space:]]')
                          or regexp_like(message_text, 'UNSYNCHRONIZED[[:space:]]+reason[[:space:]]+ASYNC configuration')) then 1
            when message_text like '%ORA-16198%' or message_text like '%ORA-03135%' or message_text like '%ORA-03113%' or message_text like '%ORA-16055%'
              or message_text like '%ORA-16191%' or message_text like '%TNS-12535%' or message_text like '%TNS-12170%' or message_text like '%TNS-12609%'
              or message_text like '%Possible network disconnect%' then 1
            else 0 end
       -- hist-pattern: end
                   ) = 1 then 'I'
                   when
       -- sync-pattern: begin
       message_text like '%LAD:%' and (message_text like '%level SYNCHRONIZED%' or message_text like '%is SYNCHRONIZED%')
       -- sync-pattern: end
                   then 'S' end k
       from   v$diag_alert_ext
       where  component_id = 'rdbms'
       and    originating_timestamp > systimestamp - numtodsinterval(&hist_days, 'DAY'));

-- 1 s ASH if it still covers the start of the window, else the 10 s AWR copy
column ash_src new_value ash_src noprint
select case when min(sample_time) <= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') then 'V' else 'H' end ash_src
from   v$active_session_history;

select json_object('t' value 'meta', 'side' value 'primary', 'db' value d.name, 'uniq' value d.db_unique_name,
         'role' value d.database_role, 'open' value d.open_mode, 'pmode' value d.protection_mode,
         'plevel' value d.protection_level, 'inst' value i.instance_name, 'host' value i.host_name,
         'ver' value i.version_full, 'plat' value d.platform_name, 'from' value '&t_from', 'to' value '&t_to',
         'gen' value to_char(sysdate,'YYYY-MM-DD HH24:MI:SS'), 'tz' value to_char(systimestamp,'TZH:TZM'),
         'startup' value to_char(i.startup_time,'YYYY-MM-DD HH24:MI:SS'),
         'cluster_database' value case when '&rac_cluster' = '-' then null else '&rac_cluster' end,
         'inst_count' value case when &rac_inst < 0 then null else &rac_inst end,
         'ash' value '&ash_src' returning varchar2(4000))
from   v$database d, v$instance i;

-- coverage (cov) records: what each source holds (first, last), how many rows fall inside the window (n)
-- ASH: the source in use (V = v$active_session_history, H = AWR copy)
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'ash', 'kind' value '&ash_src',
         'st' value case when w.n > 0 then 'ok' else 'empty' end,
         'first' value to_char(h.f, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(h.l, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value w.n, 'cap' value null, 'capped' value 'false' format json,
         'note' value case '&ash_src' when 'V' then 'v$active_session_history' else 'dba_hist_active_sess_history' end
         returning varchar2(4000))
from  (select min(t) f, max(t) l
       from  (select sample_time t from v$active_session_history where '&ash_src' = 'V'
              union all
              select sample_time from dba_hist_active_sess_history
              where  '&ash_src' = 'H' and dbid = (select dbid from v$database) and snap_id in (&snap_lo, &snap_hi))) h,
      (select count(*) n
       from  (select sample_time from v$active_session_history
              where  '&ash_src' = 'V'
              and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
              union all
              select sample_time from dba_hist_active_sess_history
              where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
              and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS'))) w;

-- AWR snapshots: first/last = oldest begin and newest end held; n = snapshots overlapping the window
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'awr_snap',
         'st' value case when w.n > 0 then 'ok' else 'empty' end,
         'first' value to_char(h.f, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(h.l, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value w.n, 'cap' value null, 'capped' value 'false' format json,
         'note' value 'dba_hist_snapshot' returning varchar2(4000))
from  (select min(begin_interval_time) f, max(end_interval_time) l from dba_hist_snapshot where dbid = (select dbid from v$database)) h,
      (select count(distinct snap_id) n from dba_hist_snapshot
       where  dbid = (select dbid from v$database)
       and    end_interval_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
       and    begin_interval_time < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')) w;

-- 1 min system metrics (the wl records): n = minutes with values inside the window
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'sysmetric',
         'st' value case when w.n > 0 then 'ok' else 'empty' end,
         'first' value to_char(h.f, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(h.l, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value w.n, 'cap' value null, 'capped' value 'false' format json,
         'note' value 'dba_hist_sysmetric_history' returning varchar2(4000))
from  (select min(begin_time) f, max(begin_time) l from dba_hist_sysmetric_history
       where  dbid = (select dbid from v$database) and group_id = 2 and snap_id in (&snap_lo, &snap_hi)) h,
      (select count(distinct to_char(begin_time,'YYYY-MM-DD HH24:MI')) n from dba_hist_sysmetric_history
       where  dbid = (select dbid from v$database) and group_id = 2
       and    metric_name in ('Redo Generated Per Sec', 'User Transaction Per Sec', 'Logons Per Sec', 'Average Active Sessions')
       and    begin_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')) w;

-- alert log through SQL, from the single pass above. -1 = that pass failed. The window rows themselves come from the 'alert' query below.
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'alert_sql',
         'st' value case when &al_win < 0 then 'error' when &al_win > 0 then 'ok'
                         when to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') < systimestamp - numtodsinterval(&hist_days, 'DAY') then 'error'
                         else 'empty' end,
         'first' value case when '&al_first' = '-' then null else '&al_first' end,
         'last' value case when '&al_last' = '-' then null else '&al_last' end,
         'n' value greatest(&al_win, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &al_win < 0 then 'the pass over v$diag_alert_ext failed'
                           when to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') < systimestamp - numtodsinterval(&hist_days, 'DAY')
                                then 'the window starts before the -d lookback (&hist_days days): n and first are incomplete, raise -d'
                           else 'v$diag_alert_ext, component rdbms, lookback &hist_days days' end
         returning varchar2(4000))
from   dual;

-- the history list below keeps the newest 300 of the matches counted by the pass above
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'alhist', 'kind' value 'sql',
         'st' value case when &al_hist < 0 then 'error' when &al_hist > 0 then 'ok' else 'empty' end,
         'first' value case when '&al_first' = '-' then null else '&al_first' end,
         'last' value case when '&al_last' = '-' then null else '&al_last' end,
         'n' value greatest(&al_hist, 0), 'cap' value 300, 'capped' value case when &al_hist > 300 then 'true' else 'false' end format json,
         'note' value 'v$diag_alert_ext, lookback &hist_days days, newest 300 kept; routine RT_PMODE lines (PRIMARY, PHYSICAL, reason ASYNC configuration) excluded' returning varchar2(4000))
from   dual;

-- the same pass counted the lines that end an UNSYNCHRONIZED period: the history statement below keeps the newest 300 of them (alsync records)
select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'alsync', 'kind' value 'sql',
         'st' value case when &al_sync < 0 then 'error' when &al_sync > 0 then 'ok' else 'empty' end,
         'first' value case when '&al_first' = '-' then null else '&al_first' end,
         'last' value case when '&al_last' = '-' then null else '&al_last' end,
         'n' value greatest(&al_sync, 0), 'cap' value 300, 'capped' value case when &al_sync > 300 then 'true' else 'false' end format json,
         'note' value 'v$diag_alert_ext, lookback &hist_days days, newest 300 kept; lines that end an UNSYNCHRONIZED period of a destination (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)' returning varchar2(4000))
from   dual;

-- UTC offset the host used inside the window, from the alert log rows there (no row, no record: collect.sh then tries other sources)
select json_object('t' value 'clock', 'side' value 'primary', 'utc_off' value '&al_off1',
         'src' value case when '&al_off1' = '&al_off2' then 'alert log' else 'alert log, offset changes inside the window' end)
from   dual
where  '&al_off1' <> '-';

-- v$dataguard_status rows in the window (in memory: the view is lost at restart, so first/last say what it holds). The newest 500 rows of the window are kept; n counts all.
define dgs_n     = -1
define dgs_first = "-"
define dgs_last  = "-"
column dgs_n     new_value dgs_n     noprint
column dgs_first new_value dgs_first noprint
column dgs_last  new_value dgs_last  noprint
select count(case when timestamp between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS') then 1 end) dgs_n,
       nvl(to_char(min(timestamp), 'YYYY-MM-DD HH24:MI:SS'), '-') dgs_first, nvl(to_char(max(timestamp), 'YYYY-MM-DD HH24:MI:SS'), '-') dgs_last
from  (select timestamp, facility, severity, dest_id, error_code, message_num, message from v$dataguard_status);

select json_object('t' value 'dgstatus', 'side' value 'primary', 'ts' value to_char(timestamp, 'YYYY-MM-DD HH24:MI:SS'), 'facility' value facility,
         'severity' value severity, 'dest' value dest_id, 'err' value error_code, 'msg' value substr(message, 1, 300) returning varchar2(4000))
from  (select timestamp, facility, severity, dest_id, error_code, message,
              row_number() over (order by timestamp desc, message_num desc) rn
       from   v$dataguard_status
       where  timestamp between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS'))
where  rn <= 500
order  by rn desc;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'dgstatus',
         'st' value case when &dgs_n < 0 then 'error' when &dgs_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&dgs_first' = '-' then null else '&dgs_first' end, 'last' value case when '&dgs_last' = '-' then null else '&dgs_last' end,
         'n' value greatest(&dgs_n, 0), 'cap' value 500, 'capped' value case when &dgs_n > 500 then 'true' else 'false' end format json,
         'note' value case when &dgs_n < 0 then 'the v$dataguard_status statement failed' else 'v$dataguard_status, in memory (lost at restart); first/last = oldest and newest row it holds, newest 500 of the window kept' end
         returning varchar2(4000))
from   dual;

-- v$redo_dest_resp_histogram: per destination, whole-second response buckets (rows with frequency > 0). Counters as collected, NOT limited to the window. TIME is text (VARCHAR2(20)), kept as the view gives it.
define dh_n = -1
column dh_n new_value dh_n noprint
select count(*) dh_n from (select dest_id, duration, frequency, time from v$redo_dest_resp_histogram) where frequency > 0;

select json_object('t' value 'dest_hist', 'side' value 'primary', 'dest' value dest_id, 'dur' value duration, 'freq' value frequency, 'hit' value time returning varchar2(4000))
from   v$redo_dest_resp_histogram
where  frequency > 0
order  by dest_id, duration;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'dest_hist',
         'st' value case when &dh_n < 0 then 'error' when &dh_n > 0 then 'ok' else 'empty' end,
         'first' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'), 'last' value to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS'),
         'n' value greatest(&dh_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &dh_n < 0 then 'the v$redo_dest_resp_histogram statement failed' else 'as collected, counters not limited to the window; first = last = collection time' end
         returning varchar2(4000))
from   dual;

-- baseline: the same clock interval on each of the previous &base_days days, from dba_hist_event_histogram deltas of the AWR snapshots that overlap it (hourly snapshots
-- make that wider than the window: b/e say what was summed). base_day = one row per day (snaps = snapshots overlapping, used = those with a delta: a snapshot whose predecessor
-- has another startup_time is left out because the counters restarted), base_hist = the delta per event and bucket.
define bs_n     = -1
define bs_first = "-"
define bs_last  = "-"
column bs_n     new_value bs_n     noprint
column bs_first new_value bs_first noprint
column bs_last  new_value bs_last  noprint

with s as (
  select snap_id, startup_time, begin_interval_time b, end_interval_time e,
         lag(startup_time) over (partition by instance_number order by snap_id) prev_su
  from   dba_hist_snapshot
  where  dbid = (select dbid from v$database)
  and    end_interval_time >= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(&base_days + 1, 'DAY')
), d as (
  select dd from (select level dd from dual connect by level <= &base_days) where dd <= &base_days
)
select json_object('t' value 'base_day', 'side' value 'primary', 'd' value d.dd,
         'from' value to_char(to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY'), 'YYYY-MM-DD HH24:MI:SS'),
         'to' value to_char(to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY'), 'YYYY-MM-DD HH24:MI:SS'),
         'snaps' value count(s.snap_id), 'used' value count(case when s.prev_su = s.startup_time then 1 end),
         'b' value to_char(min(case when s.prev_su = s.startup_time then s.b end), 'YYYY-MM-DD HH24:MI:SS'),
         'e' value to_char(max(case when s.prev_su = s.startup_time then s.e end), 'YYYY-MM-DD HH24:MI:SS') returning varchar2(4000))
from   d left join s
       on  s.e > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
       and s.b < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
group  by d.dd
order  by d.dd;

with s as (
  select snap_id, instance_number, startup_time, begin_interval_time b, end_interval_time e
  from   dba_hist_snapshot
  where  dbid = (select dbid from v$database)
  and    end_interval_time >= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(&base_days + 1, 'DAY')
), h as (
  select s.b, s.e, g.event_name ev, g.wait_time_milli ms,
         g.wait_count - lag(g.wait_count) over
           (partition by g.instance_number, s.startup_time, g.event_name, g.wait_time_milli order by g.snap_id) n
  from   dba_hist_event_histogram g
  join   s on s.snap_id = g.snap_id and s.instance_number = g.instance_number
  where  g.dbid = (select dbid from v$database)
  and    g.event_name in ('SYNC Remote Write', 'log file sync')
), d as (
  select dd from (select level dd from dual connect by level <= &base_days) where dd <= &base_days
)
select json_object('t' value 'base_hist', 'side' value 'primary', 'd' value d.dd, 'ev' value h.ev, 'ms' value h.ms, 'n' value sum(h.n) returning varchar2(4000))
from   d join h
       on  h.e > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
       and h.b < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
where  h.n >= 0
group  by d.dd, h.ev, h.ms
having sum(h.n) > 0
order  by d.dd, h.ev, h.ms;

-- days with at least one usable delta in the histogram rows above (the same selection, so this fails when they fail); first/last = the AWR span held
with s as (
  select snap_id, instance_number, startup_time, begin_interval_time b, end_interval_time e
  from   dba_hist_snapshot
  where  dbid = (select dbid from v$database)
  and    end_interval_time >= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(&base_days + 1, 'DAY')
), h as (
  select s.b, s.e, g.event_name ev, g.wait_time_milli ms,
         g.wait_count - lag(g.wait_count) over
           (partition by g.instance_number, s.startup_time, g.event_name, g.wait_time_milli order by g.snap_id) n
  from   dba_hist_event_histogram g
  join   s on s.snap_id = g.snap_id and s.instance_number = g.instance_number
  where  g.dbid = (select dbid from v$database)
  and    g.event_name in ('SYNC Remote Write', 'log file sync')
), d as (
  select dd from (select level dd from dual connect by level <= &base_days) where dd <= &base_days
)
select c.n bs_n,
       nvl(to_char((select min(begin_interval_time) from dba_hist_snapshot where dbid = (select dbid from v$database)), 'YYYY-MM-DD HH24:MI:SS'), '-') bs_first,
       nvl(to_char((select max(end_interval_time) from dba_hist_snapshot where dbid = (select dbid from v$database)), 'YYYY-MM-DD HH24:MI:SS'), '-') bs_last
from  (select count(distinct d.dd) n
       from   d join h
              on  h.e > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
              and h.b < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') - numtodsinterval(d.dd, 'DAY')
       where  h.n >= 0) c;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'base_hist',
         'st' value case when &base_days <= 0 then 'skipped' when &bs_n < 0 then 'error' when &bs_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&bs_first' = '-' then null else '&bs_first' end, 'last' value case when '&bs_last' = '-' then null else '&bs_last' end,
         'n' value greatest(&bs_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &base_days <= 0 then 'option -b 0: no baseline requested'
                           when &bs_n < 0 then 'the baseline statements failed'
                           else 'previous &base_days days, same clock interval; n = days with a usable histogram delta; first/last = the AWR span held; dba_hist_event_histogram deltas, intervals after an instance restart left out' end
         returning varchar2(4000))
from   dual;

select json_object('t' value 'dest', 'id' value a.dest_id, 'dest' value a.destination, 'uniq' value a.db_unique_name,
         'status' value a.status, 'mode' value a.transmit_mode, 'affirm' value a.affirm,
         'net_timeout' value a.net_timeout, 'reopen' value a.reopen_secs, 'max_failure' value a.max_failure,
         'failures' value a.failure_count, 'error' value a.error, 'sync' value s.synchronization_status,
         'synced' value s.synchronized, 'gap' value s.gap_status returning varchar2(4000))
from   v$archive_dest a join v$archive_dest_status s on s.dest_id = a.dest_id
where  a.target = 'STANDBY' and a.status <> 'INACTIVE';

select json_object('t' value 'param', 'name' value name, 'value' value substr(value, 1, 1000) returning varchar2(4000))
from   v$parameter
where  name in ('data_guard_sync_latency', 'log_archive_config', 'fal_server')
   or (name like 'log\_archive\_dest\_%' escape '\' and name not like 'log\_archive\_dest\_state%' escape '\' and value is not null);

-- foreground sessions per minute: log file sync blocked by LGWR / other waits / on CPU (raw sample counts)
with ash as (
  select sample_time, session_id, session_type, session_state, event, blocking_session, program
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_id, session_type, session_state, event, blocking_session, program
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
)
select json_object('t' value 'fg', 'm' value m, 'lgwr' value sum(l), 'other' value sum(o), 'cpu' value sum(c))
from  (select to_char(a.sample_time,'YYYY-MM-DD HH24:MI') m,
              case when a.event = 'log file sync' and lg.session_id is not null then 1 else 0 end l,
              case when a.session_state = 'WAITING' and not (a.event = 'log file sync' and lg.session_id is not null) then 1 else 0 end o,
              case when a.session_state = 'ON CPU' then 1 else 0 end c
       from   ash a left join lg on lg.session_id = a.blocking_session
       where  a.session_type = 'FOREGROUND')
group  by m
order  by m;

-- commits blocked by LGWR in 10 s buckets
with ash as (
  select sample_time, session_type, event, blocking_session, program
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_type, event, blocking_session, program
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
)
select json_object('t' value 'fg10', 'b' value b, 'n' value count(*))
from  (select to_char(a.sample_time,'YYYY-MM-DD HH24:MI:') || lpad(to_char(trunc(extract(second from a.sample_time) / 10) * 10), 2, '0') b
       from   ash a join lg on lg.session_id = a.blocking_session
       where  a.session_type = 'FOREGROUND' and a.event = 'log file sync')
group  by b
order  by b;

-- ASH range held by the source in use: the first/last of the coverage records of the two queries below
define ash_first = "-"
define ash_last  = "-"
column ash_first new_value ash_first noprint
column ash_last  new_value ash_last  noprint
select nvl(to_char(min(t), 'YYYY-MM-DD HH24:MI:SS'), '-') ash_first, nvl(to_char(max(t), 'YYYY-MM-DD HH24:MI:SS'), '-') ash_last
from  (select sample_time t from v$active_session_history where '&ash_src' = 'V'
       union all
       select sample_time from dba_hist_active_sess_history
       where  '&ash_src' = 'H' and dbid = (select dbid from v$database) and snap_id in (&snap_lo, &snap_hi));

-- individual commit waits (lfs): one row per log file sync wait seen in ASH, keyed by session, serial# and seq#. seq# wraps, so samples of one key that are
-- more than lfs_gap seconds apart count as different waits. The longest 200 are kept (by time_waited, else by first-to-last sample span).
-- time_waited is set on the last sample of a wait only: tw stays null when no sample of the wait has a value, and 0 is kept as 0. lg = 1 when LGWR was the blocking session.
define lfs_gap = 3
define lfs_n   = -1
column lfs_gap new_value lfs_gap noprint
column lfs_n   new_value lfs_n   noprint
select case '&ash_src' when 'V' then 3 else 25 end lfs_gap from dual;

with ash as (
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, seq#, time_waited
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, seq#, time_waited
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
), c as (
  select a.session_id sid, a.ser ser, a.seq# seq, a.sample_time t, a.time_waited tw,
         case when lg.session_id is not null then 1 else 0 end lgwr,
         case when a.sample_time - lag(a.sample_time) over (partition by a.session_id, a.ser, a.seq# order by a.sample_time)
                   > numtodsinterval(&lfs_gap, 'SECOND') then 1 else 0 end brk
  from   ash a left join lg on lg.session_id = a.blocking_session
  where  a.session_type = 'FOREGROUND' and a.event = 'log file sync'
), g as (
  select sid, ser, seq, t, tw, lgwr, sum(brk) over (partition by sid, ser, seq order by t rows unbounded preceding) grp from c
), w as (
  select sid, ser, seq, grp, min(t) t1, max(t) t2, count(*) n, max(tw) tw, max(lgwr) lgwr
  from   g
  group  by sid, ser, seq, grp
), r as (
  select w.*, row_number() over (order by greatest(nvl(tw, 0) / 1000000,
              extract(day from (t2 - t1)) * 86400 + extract(hour from (t2 - t1)) * 3600 + extract(minute from (t2 - t1)) * 60 + extract(second from (t2 - t1))) desc, t1, sid) rn
  from   w
)
select json_object('t' value 'lfs', 'side' value 'primary', 'sid' value sid, 'ser' value ser, 'seq' value seq,
         'a' value to_char(t1, 'YYYY-MM-DD HH24:MI:SS.FF3'), 'z' value to_char(t2, 'YYYY-MM-DD HH24:MI:SS.FF3'),
         'n' value n, 'tw' value tw, 'lg' value lgwr returning varchar2(4000))
from   r
where  rn <= 200
order  by t1, sid;

-- totals over the same waits (all of them, not only the 200 kept), and the most sessions waiting in one sample: any blocker, and LGWR as blocker.
-- The same statement leaves the number of waits in lfs_n for the coverage record.
with ash as (
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, seq#, time_waited
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, seq#, time_waited
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
), c as (
  select a.session_id sid, a.ser ser, a.seq# seq, a.sample_time t, a.time_waited tw,
         case when lg.session_id is not null then 1 else 0 end lgwr,
         case when a.sample_time - lag(a.sample_time) over (partition by a.session_id, a.ser, a.seq# order by a.sample_time)
                   > numtodsinterval(&lfs_gap, 'SECOND') then 1 else 0 end brk
  from   ash a left join lg on lg.session_id = a.blocking_session
  where  a.session_type = 'FOREGROUND' and a.event = 'log file sync'
), g as (
  select sid, ser, seq, t, tw, lgwr, sum(brk) over (partition by sid, ser, seq order by t rows unbounded preceding) grp from c
), w as (
  select sid, ser, seq, grp, max(lgwr) lgwr from g group by sid, ser, seq, grp
), p as (
  select t, count(*) n, sum(lgwr) nlg from c group by t
)
select json_object('t' value 'lfs_sum', 'side' value 'primary', 'waits' value (select count(*) from w), 'lgwr_waits' value (select count(*) from w where lgwr = 1),
         'pk_n' value (select max(n) from p),
         'pk_at' value (select to_char(min(t) keep (dense_rank first order by n desc), 'YYYY-MM-DD HH24:MI:SS.FF3') from p),
         'pk_lg' value (select max(nlg) from p),
         'pk_lg_at' value (select to_char(min(t) keep (dense_rank first order by nlg desc), 'YYYY-MM-DD HH24:MI:SS.FF3') from p) returning varchar2(4000)),
       (select count(*) from w) lfs_n
from   dual;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'lfs',
         'st' value case when &lfs_n < 0 then 'error' when &lfs_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ash_first' = '-' then null else '&ash_first' end, 'last' value case when '&ash_last' = '-' then null else '&ash_last' end,
         'n' value greatest(&lfs_n, 0), 'cap' value 200, 'capped' value case when &lfs_n > 200 then 'true' else 'false' end format json,
         'note' value case when &lfs_n < 0 then 'the totals statement over ASH failed' else 'log file sync waits in ASH (&ash_src), longest 200 kept; first/last = what ASH holds' end returning varchar2(4000))
from   dual;

-- who waited (lfs_by): FOREGROUND samples on log file sync in the window, from the same ASH source as lfs, grouped by service, by module and by machine. n = samples, lg = of those the samples whose
-- blocking session was LGWR (same test as lfs), sess = distinct session_id and serial#, a/z = first and last sample. Samples are counts, not durations. The service name is looked up by hash in
-- v$active_services (min(name): the same hash can be listed once per container, which must not multiply the samples); a hash that is not listed there is written as 'hash <number>'.
-- The 15 groups with the most samples are kept per dim. The next statement counts all groups for the coverage record: lb_n = groups found over the three lists before the cut, lb_over = 1 when a list had more than 15.
define lb_n    = -1
define lb_over = 0
column lb_n    new_value lb_n    noprint
column lb_over new_value lb_over noprint
with ash as (
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, service_hash, module, machine
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, service_hash, module, machine
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
), s as (
  select a.service_hash, a.module, a.machine, a.session_id sid, a.ser, a.sample_time t,
         case when lg.session_id is not null then 1 else 0 end lgwr
  from   ash a left join lg on lg.session_id = a.blocking_session
  where  a.session_type = 'FOREGROUND' and a.event = 'log file sync'
), d as (
  select cast('service' as varchar2(7)) dim, to_char(service_hash) k, count(*) n, sum(lgwr) lg, count(distinct to_char(sid) || ',' || to_char(ser)) sess, min(t) a, max(t) z
  from   s group by service_hash
  union all
  select cast('module' as varchar2(7)), module, count(*), sum(lgwr), count(distinct to_char(sid) || ',' || to_char(ser)), min(t), max(t)
  from   s group by module
  union all
  select cast('machine' as varchar2(7)), machine, count(*), sum(lgwr), count(distinct to_char(sid) || ',' || to_char(ser)), min(t), max(t)
  from   s group by machine
), r as (
  select d.*, row_number() over (partition by dim order by n desc, k) rn from d
)
select json_object('t' value 'lfs_by', 'side' value 'primary', 'dim' value dim,
         'name' value substr(case when dim = 'service' and k is not null
                                  then nvl((select min(v.name) from v$active_services v where to_char(v.name_hash) = k), 'hash ' || k) else k end, 1, 64),
         'n' value n, 'lg' value lg, 'sess' value sess,
         'a' value to_char(a, 'YYYY-MM-DD HH24:MI:SS'), 'z' value to_char(z, 'YYYY-MM-DD HH24:MI:SS') returning varchar2(4000))
from   r
where  rn <= 15
order  by dim, rn;

with ash as (
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, service_hash, module, machine
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_id, session_serial# ser, session_type, event, blocking_session, service_hash, module, machine
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
), lg as (
  select session_id from (select session_id, program from v$active_session_history
                          union all select session_id, program from dba_hist_active_sess_history where dbid = (select dbid from v$database)
                                                                   and sample_time > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day)
  where program like '%(LGWR)%'
  union
  select sid from v$session where program like '%(LGWR)%'
), s as (
  select a.service_hash, a.module, a.machine, a.session_id sid, a.ser, a.sample_time t,
         case when lg.session_id is not null then 1 else 0 end lgwr
  from   ash a left join lg on lg.session_id = a.blocking_session
  where  a.session_type = 'FOREGROUND' and a.event = 'log file sync'
)
select nvl(sum(c), 0) lb_n, nvl(max(case when c > 15 then 1 else 0 end), 0) lb_over
from  (select dim, count(*) c
       from  (select cast('service' as varchar2(7)) dim from s group by service_hash
              union all
              select cast('module' as varchar2(7)) from s group by module
              union all
              select cast('machine' as varchar2(7)) from s group by machine)
       group by dim);

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'lfs_by',
         'st' value case when &lb_n < 0 then 'error' when &lb_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ash_first' = '-' then null else '&ash_first' end, 'last' value case when '&ash_last' = '-' then null else '&ash_last' end,
         'n' value greatest(&lb_n, 0), 'cap' value 15, 'capped' value case when &lb_over > 0 then 'true' else 'false' end format json,
         'note' value case when &lb_n < 0 then 'the statement over ASH failed' else 'log file sync samples in ASH (&ash_src) by service, module and machine, the 15 groups with the most samples kept per list; n = groups found over the three lists; first/last = what ASH holds' end
         returning varchar2(4000))
from   dual;

-- sampler gaps (ashgap): consecutive ASH samples (one row per sample_id) whose clock difference exceeds the sample_id difference x 1 s by more than 2 s.
-- sample_id advances once per second (sampling interval 1 s); the AWR copy keeps every 10th sample but the same sample_id. One minute before and after the window is read
-- so that the samples around its ends are included. Raw ids and times are written; the report decides. The largest 50 gaps are kept; the coverage record has all counts.
define ag_n = -1
define ag_s = -1
define ag_a = "-"
define ag_z = "-"
column ag_n new_value ag_n noprint
column ag_s new_value ag_s noprint
column ag_a new_value ag_a noprint
column ag_z new_value ag_z noprint

with s as (
  select sample_id, min(sample_time) t
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
  group  by sample_id
  union all
  select sample_id, min(sample_time)
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
  group  by sample_id
), d as (
  select sample_id id2, t t2, lag(sample_id) over (order by t) id1, lag(t) over (order by t) t1 from s
), x as (
  select id1, id2, t1, t2,
         extract(day from (t2 - t1)) * 86400 + extract(hour from (t2 - t1)) * 3600 + extract(minute from (t2 - t1)) * 60 + extract(second from (t2 - t1)) secs
  from   d
  where  id1 is not null and id2 > id1
), r as (
  select x.*, row_number() over (order by secs - (id2 - id1) desc, t1) rn from x where secs - (id2 - id1) > 2
)
select json_object('t' value 'ashgap', 'side' value 'primary', 'ia' value id1, 'a' value to_char(t1, 'YYYY-MM-DD HH24:MI:SS.FF3'),
         'iz' value id2, 'z' value to_char(t2, 'YYYY-MM-DD HH24:MI:SS.FF3') returning varchar2(4000))
from   r
where  rn <= 50
order  by t1;

with s as (
  select sample_id, min(sample_time) t
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
  group  by sample_id
  union all
  select sample_id, min(sample_time)
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' minute and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '1' minute
  group  by sample_id
), d as (
  select sample_id id2, t t2, lag(sample_id) over (order by t) id1, lag(t) over (order by t) t1 from s
), x as (
  select id1, id2, t1, t2,
         extract(day from (t2 - t1)) * 86400 + extract(hour from (t2 - t1)) * 3600 + extract(minute from (t2 - t1)) * 60 + extract(second from (t2 - t1)) secs
  from   d
  where  id1 is not null and id2 > id1
)
select (select count(*) from x where secs - (id2 - id1) > 2) ag_n, (select count(*) from s) ag_s,
       nvl((select to_char(min(t), 'YYYY-MM-DD HH24:MI:SS') from s), '-') ag_a, nvl((select to_char(max(t), 'YYYY-MM-DD HH24:MI:SS') from s), '-') ag_z
from   dual;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'ashgap',
         'st' value case when &ag_n < 0 then 'error' when &ag_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ag_a' = '-' then null else '&ag_a' end, 'last' value case when '&ag_z' = '-' then null else '&ag_z' end,
         'n' value greatest(&ag_n, 0), 'cap' value 50, 'capped' value case when &ag_n > 50 then 'true' else 'false' end format json,
         'note' value case when &ag_n < 0 then 'the statement over ASH failed' else 'gaps over 2 s between consecutive ASH samples (&ash_src), 1 s per sample_id; first/last = samples read, one minute around the window' end,
         'samples' value greatest(&ag_s, 0) returning varchar2(4000))
from   dual;

-- LGWR / LGnn / NSSn / TTnn / ARCn / TMON samples
with ash as (
  select sample_time, session_state, event, program, seq#, time_waited
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select sample_time, session_state, event, program, seq#, time_waited
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
)
select json_object('t' value 'tx', 'ts' value to_char(sample_time,'YYYY-MM-DD HH24:MI:SS.FF3'),
         'p' value regexp_substr(program, '\(([^)]+)\)', 1, 1, null, 1), 'ev' value event,
         'seq' value seq#, 'tw' value time_waited returning varchar2(4000))
from   ash
where  session_state = 'WAITING'
and   (program like '%(LGWR)%' or program like '%(LG0%' or program like '%(NSS%'
       or program like '%(TT0%' or program like '%(ARC%' or program like '%(TMON)%')
order  by sample_time;

-- the tx records above: how many samples of the transport processes the source held in the window
define tx_n = -1
column tx_n new_value tx_n noprint
with ash as (
  select session_state, program
  from   v$active_session_history
  where  '&ash_src' = 'V'
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
  union all
  select session_state, program
  from   dba_hist_active_sess_history
  where  '&ash_src' = 'H' and dbid = (select dbid from v$database)
  and    sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
)
select count(*) tx_n
from   ash
where  session_state = 'WAITING'
and   (program like '%(LGWR)%' or program like '%(LG0%' or program like '%(NSS%'
       or program like '%(TT0%' or program like '%(ARC%' or program like '%(TMON)%');

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'tx',
         'st' value case when &tx_n < 0 then 'error' when &tx_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ash_first' = '-' then null else '&ash_first' end, 'last' value case when '&ash_last' = '-' then null else '&ash_last' end,
         'n' value greatest(&tx_n, 0), 'cap' value null, 'capped' value 'false' format json,
         'note' value case when &tx_n < 0 then 'the count statement over ASH failed' else 'LGWR/LGnn/NSSn/TTnn/ARCn/TMON wait samples in ASH (&ash_src); first/last = what ASH holds' end returning varchar2(4000))
from   dual;

-- SYNC Remote Write histogram since startup
select json_object('t' value 'hist_su', 'ev' value event, 'b' value wait_time_format, 'us' value wait_time_micro, 'n' value wait_count)
from   v$event_histogram_micro
where  event in ('SYNC Remote Write', 'log file sync')
order  by event, wait_time_micro;

-- same, summed over the AWR snapshots that overlap the window
with h as (
  select s.begin_interval_time b, s.end_interval_time e, h.event_name, h.wait_time_milli ms,
         h.wait_count - lag(h.wait_count) over
           (partition by h.dbid, h.instance_number, h.event_name, h.wait_time_milli order by h.snap_id) d
  from   dba_hist_event_histogram h
  join   dba_hist_snapshot s on s.snap_id = h.snap_id and s.dbid = h.dbid and s.instance_number = h.instance_number
  where  h.dbid = (select dbid from v$database)
  and    h.event_name in ('SYNC Remote Write', 'log file sync')
  and    s.end_interval_time >= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day
)
select json_object('t' value 'hist_awr', 'ev' value event_name, 'ms' value ms, 'n' value sum(d),
         'b' value to_char(min(b),'YYYY-MM-DD HH24:MI'), 'e' value to_char(max(e),'YYYY-MM-DD HH24:MI'))
from   h
where  d >= 0
and    e > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
and    b < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
group  by event_name, ms
order  by event_name, ms;

-- workload per minute
select json_object('t' value 'wl', 'm' value to_char(begin_time,'YYYY-MM-DD HH24:MI'),
         'redo' value round(max(case metric_name when 'Redo Generated Per Sec'   then value end) / 1048576, 3),
         'txn'  value round(max(case metric_name when 'User Transaction Per Sec' then value end), 2),
         'logons' value round(max(case metric_name when 'Logons Per Sec'         then value end), 3),
         'aas'  value round(max(case metric_name when 'Average Active Sessions'  then value end), 2))
from   dba_hist_sysmetric_history
where  dbid = (select dbid from v$database)
and    group_id = 2
and    metric_name in ('Redo Generated Per Sec', 'User Transaction Per Sec', 'Logons Per Sec', 'Average Active Sessions')
and    begin_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
group  by to_char(begin_time,'YYYY-MM-DD HH24:MI')
order  by 1;

-- workload per snapshot interval (wl_hist): the last &hist_days days of dba_hist_sysmetric_summary (group 2) for this database and instance, one record per AWR snapshot interval. redo and redo_max are the
-- average and the largest 1 minute value of Redo Generated Per Sec over the interval in MB/s (as the wl records), txn the average of User Transaction Per Sec. Newest 1500 intervals kept.
-- The statement after the records counts the intervals of the lookback and finds the span the view holds, for the coverage record.
define wh_n     = -1
define wh_first = "-"
define wh_last  = "-"
column wh_n     new_value wh_n     noprint
column wh_first new_value wh_first noprint
column wh_last  new_value wh_last  noprint
select json_object('t' value 'wl_hist', 'side' value 'primary', 'b' value to_char(b, 'YYYY-MM-DD HH24:MI'), 'e' value to_char(e, 'YYYY-MM-DD HH24:MI'),
         'redo' value round(redo / 1048576, 3), 'redo_max' value round(redo_max / 1048576, 3), 'txn' value round(txn, 2) returning varchar2(4000))
from  (select b, e, redo, redo_max, txn, row_number() over (order by b desc) rn
       from  (select begin_time b, end_time e,
                     max(case when metric_name = 'Redo Generated Per Sec' then average end) redo,
                     max(case when metric_name = 'Redo Generated Per Sec' then maxval end) redo_max,
                     max(case when metric_name = 'User Transaction Per Sec' then average end) txn
              from   dba_hist_sysmetric_summary
              where  dbid = (select dbid from v$database)
              and    instance_number = (select instance_number from v$instance)
              and    group_id = 2
              and    metric_name in ('Redo Generated Per Sec', 'User Transaction Per Sec')
              and    begin_time > sysdate - &hist_days
              group  by snap_id, begin_time, end_time))
where  rn <= 1500
order  by b;

select count(distinct case when begin_time > sysdate - &hist_days then snap_id end) wh_n,
       nvl(to_char(min(begin_time), 'YYYY-MM-DD HH24:MI:SS'), '-') wh_first, nvl(to_char(max(end_time), 'YYYY-MM-DD HH24:MI:SS'), '-') wh_last
from   dba_hist_sysmetric_summary
where  dbid = (select dbid from v$database)
and    instance_number = (select instance_number from v$instance)
and    group_id = 2
and    metric_name in ('Redo Generated Per Sec', 'User Transaction Per Sec');

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'wl_hist',
         'st' value case when &wh_n < 0 then 'error' when &wh_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&wh_first' = '-' then null else '&wh_first' end, 'last' value case when '&wh_last' = '-' then null else '&wh_last' end,
         'n' value greatest(&wh_n, 0), 'cap' value 1500, 'capped' value case when &wh_n > 1500 then 'true' else 'false' end format json,
         'note' value case when &wh_n < 0 then 'the dba_hist_sysmetric_summary statement failed' else 'dba_hist_sysmetric_summary, group 2, lookback &hist_days days, one record per AWR snapshot interval, newest 1500 kept; first/last = the span the view holds, n = intervals in the lookback' end
         returning varchar2(4000))
from   dual;

-- alert log in the window
select json_object('t' value 'alert', 'side' value 'primary', 'ts' value to_char(originating_timestamp,'YYYY-MM-DD HH24:MI:SS.FF3'),
         'msg' value substr(rtrim(message_text, chr(10)), 1, 900) returning varchar2(4000))
from   v$diag_alert_ext
where  component_id = 'rdbms'
and    cast(originating_timestamp as timestamp)
       between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by originating_timestamp;

-- earlier Data Guard / network errors (alhist, newest 300) and the lines that end an UNSYNCHRONIZED period (alsync, newest 300), in ONE pass: the same pattern lists as the counts in the pass at the top
-- (routine RT_PMODE lines are not listed). k = I or S; a line of the history list is never also an S line.
select json_object('t' value case k when 'S' then 'alsync' else 'alhist' end, 'side' value 'primary', 'ts' value to_char(originating_timestamp,'YYYY-MM-DD HH24:MI:SS'),
         'msg' value substr(rtrim(message_text, chr(10)), 1, case k when 'S' then 200 else 300 end) returning varchar2(4000))
from  (select originating_timestamp, message_text, k,
              row_number() over (partition by k order by originating_timestamp desc) rn
       from  (select originating_timestamp, message_text,
                     case when (
       -- hist-pattern: begin
       case when message_text like '%UNSYNCHRONIZED%'
                 and not (regexp_like(message_text, 'RT_PMODE:[[:space:]]+(PRIMARY|PHYSICAL)[[:space:]]')
                          or regexp_like(message_text, 'UNSYNCHRONIZED[[:space:]]+reason[[:space:]]+ASYNC configuration')) then 1
            when message_text like '%ORA-16198%' or message_text like '%ORA-03135%' or message_text like '%ORA-03113%' or message_text like '%ORA-16055%'
              or message_text like '%ORA-16191%' or message_text like '%TNS-12535%' or message_text like '%TNS-12170%' or message_text like '%TNS-12609%'
              or message_text like '%Possible network disconnect%' then 1
            else 0 end
       -- hist-pattern: end
                          ) = 1 then 'I'
                          when
       -- sync-pattern: begin
       message_text like '%LAD:%' and (message_text like '%level SYNCHRONIZED%' or message_text like '%is SYNCHRONIZED%')
       -- sync-pattern: end
                          then 'S' end k
              from   v$diag_alert_ext
              where  component_id = 'rdbms'
              and    originating_timestamp > systimestamp - numtodsinterval(&hist_days, 'DAY'))
       where  k is not null)
where  rn <= 300
order  by originating_timestamp;

-- archived log sequences sent to the standby destination(s) in the window
select json_object('t' value 'arch', 'side' value 'primary', 'dest' value l.dest_id, 'thr' value l.thread#, 'seq' value l.sequence#,
         'first' value to_char(l.first_time,'YYYY-MM-DD HH24:MI:SS'), 'next' value to_char(l.next_time,'YYYY-MM-DD HH24:MI:SS'),
         'done' value to_char(l.completion_time,'YYYY-MM-DD HH24:MI:SS'), 'creator' value l.creator, 'reg' value l.registrar,
         'fal' value l.fal, 'mb' value round(l.blocks * l.block_size / 1048576, 1))
from   v$archived_log l
where  l.dest_id in (select dest_id from v$archive_dest where target = 'STANDBY')
and    l.completion_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by l.completion_time;

-- scheduled activity in the lookback (act), three statements of their own, each with its own coverage record (src act, kind rman, job or logsw). first/last = the oldest and newest row the view holds, n = rows in the lookback
-- before the cut. Times are the local time of this host.
-- RMAN commands (v$rman_status, rows of type COMMAND): name = operation and object type, a/z = start and end time (z is null while the command has no end time), st = status. Newest 500 kept.
define ar_n     = -1
define ar_first = "-"
define ar_last  = "-"
column ar_n     new_value ar_n     noprint
column ar_first new_value ar_first noprint
column ar_last  new_value ar_last  noprint
select json_object('t' value 'act', 'side' value 'primary', 'kind' value 'rman', 'name' value substr(trim(operation || ' ' || object_type), 1, 100),
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

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'act', 'kind' value 'rman',
         'st' value case when &ar_n < 0 then 'error' when &ar_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&ar_first' = '-' then null else '&ar_first' end, 'last' value case when '&ar_last' = '-' then null else '&ar_last' end,
         'n' value greatest(&ar_n, 0), 'cap' value 500, 'capped' value case when &ar_n > 500 then 'true' else 'false' end format json,
         'note' value case when &ar_n < 0 then 'the v$rman_status statement failed' else 'v$rman_status, rows of type COMMAND, lookback &hist_days days, newest 500 kept; first/last = the oldest and newest start time the view holds' end
         returning varchar2(4000))
from   dual;

-- scheduler job runs (cdb_scheduler_job_run_details): name = owner.job_name, con = con_id, a = actual_start_date converted to the UTC offset this host has now (to_char(systimestamp, 'TZH:TZM')) and cut to a DATE,
-- z = a + run_duration, st = status. A job with more than 24 runs a day on average over the lookback is written as ONE record (freq true, n = its runs, a = first start, z = last start, no status) and its runs are not listed.
-- every other run is one record (freq false, n 1). Newest 2000 run records kept (the summaries are not cut). The count statement finds: aj_n = all rows in the lookback, aj_runs = the run records before the cut.
define aj_n     = -1
define aj_runs  = 0
define aj_first = "-"
define aj_last  = "-"
column aj_n     new_value aj_n     noprint
column aj_runs  new_value aj_runs  noprint
column aj_first new_value aj_first noprint
column aj_last  new_value aj_last  noprint
with r as (
  select owner || '.' || job_name name, con_id, status st,
         cast(actual_start_date at time zone to_char(systimestamp, 'TZH:TZM') as date) a,
         cast(actual_start_date at time zone to_char(systimestamp, 'TZH:TZM') as date) + run_duration z,
         count(*) over (partition by con_id, owner, job_name) cnt
  from   cdb_scheduler_job_run_details
  where  actual_start_date > systimestamp - numtodsinterval(&hist_days, 'DAY')
), x as (
  select name, con_id, a, z, st, 0 fr, 1 n, row_number() over (order by a desc, name) rn
  from   r where cnt <= 24 * &hist_days
  union all
  select name, con_id, min(a), max(a), cast(null as varchar2(30)), 1, count(*), to_number(null)
  from   r where cnt > 24 * &hist_days
  group  by name, con_id
)
select json_object('t' value 'act', 'side' value 'primary', 'kind' value 'job', 'name' value substr(name, 1, 128), 'con' value con_id,
         'a' value to_char(a, 'YYYY-MM-DD HH24:MI:SS'), 'z' value to_char(z, 'YYYY-MM-DD HH24:MI:SS'), 'st' value st,
         'freq' value case when fr = 1 then 'true' else 'false' end format json, 'n' value n returning varchar2(4000))
from   x
where  fr = 1 or rn <= 2000
order  by a, name;

select count(*) aj_n, count(case when cnt <= 24 * &hist_days then 1 end) aj_runs,
       (select nvl(to_char(cast(min(actual_start_date) at time zone to_char(systimestamp, 'TZH:TZM') as date), 'YYYY-MM-DD HH24:MI:SS'), '-') from cdb_scheduler_job_run_details) aj_first,
       (select nvl(to_char(cast(max(actual_start_date) at time zone to_char(systimestamp, 'TZH:TZM') as date), 'YYYY-MM-DD HH24:MI:SS'), '-') from cdb_scheduler_job_run_details) aj_last
from  (select count(*) over (partition by con_id, owner, job_name) cnt
       from   cdb_scheduler_job_run_details
       where  actual_start_date > systimestamp - numtodsinterval(&hist_days, 'DAY'));

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'act', 'kind' value 'job',
         'st' value case when &aj_n < 0 then 'error' when &aj_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&aj_first' = '-' then null else '&aj_first' end, 'last' value case when '&aj_last' = '-' then null else '&aj_last' end,
         'n' value greatest(&aj_n, 0), 'cap' value 2000, 'capped' value case when &aj_runs > 2000 then 'true' else 'false' end format json,
         'note' value case when &aj_n < 0 then 'the cdb_scheduler_job_run_details statement failed' else 'cdb_scheduler_job_run_details, lookback &hist_days days, newest 2000 run records kept, a job with more than 24 runs a day is one summary record; n = all rows in the lookback; first/last = the oldest and newest start the view holds, in the UTC offset this host has now' end
         returning varchar2(4000))
from   dual;

-- log switches (v$log_history): a = first_time (the time the log sequence was opened, i.e. the switch into it), thr = thread#, seq = sequence#. Newest 5000 kept.
define sw_n     = -1
define sw_first = "-"
define sw_last  = "-"
column sw_n     new_value sw_n     noprint
column sw_first new_value sw_first noprint
column sw_last  new_value sw_last  noprint
select json_object('t' value 'act', 'side' value 'primary', 'kind' value 'logsw', 'a' value to_char(first_time, 'YYYY-MM-DD HH24:MI:SS'), 'thr' value thread#, 'seq' value sequence# returning varchar2(4000))
from  (select first_time, thread#, sequence#, row_number() over (order by first_time desc, sequence# desc) rn
       from   v$log_history
       where  first_time > sysdate - &hist_days)
where  rn <= 5000
order  by first_time, thread#, sequence#;

select count(case when first_time > sysdate - &hist_days then 1 end) sw_n,
       nvl(to_char(min(first_time), 'YYYY-MM-DD HH24:MI:SS'), '-') sw_first, nvl(to_char(max(first_time), 'YYYY-MM-DD HH24:MI:SS'), '-') sw_last
from   v$log_history;

select json_object('t' value 'cov', 'side' value 'primary', 'src' value 'act', 'kind' value 'logsw',
         'st' value case when &sw_n < 0 then 'error' when &sw_n > 0 then 'ok' else 'empty' end,
         'first' value case when '&sw_first' = '-' then null else '&sw_first' end, 'last' value case when '&sw_last' = '-' then null else '&sw_last' end,
         'n' value greatest(&sw_n, 0), 'cap' value 5000, 'capped' value case when &sw_n > 5000 then 'true' else 'false' end format json,
         'note' value case when &sw_n < 0 then 'the v$log_history statement failed' else 'v$log_history, lookback &hist_days days, newest 5000 kept; first/last = the oldest and newest first_time the view holds' end
         returning varchar2(4000))
from   dual;

spool off
exit

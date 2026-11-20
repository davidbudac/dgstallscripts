-- HTML report data, PRIMARY side: one JSON object per line, appended to a bundle file.
-- Called by sh/collect.sh. Read-only.
-- Args: 1 = from 'YYYY-MM-DD HH24:MI:SS'  2 = to  3 = history days  4 = bundle file (appended)
set termout off echo off feedback off verify off heading off pagesize 0 linesize 32767
set trimspool on trimout on tab off
whenever sqlerror continue
define t_from    = "&1"
define t_to      = "&2"
define hist_days = "&3"
define out_file  = "&4"

-- 1 s ASH if it still covers the start of the window, else the 10 s AWR copy
column ash_src new_value ash_src noprint
select case when min(sample_time) <= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') then 'V' else 'H' end ash_src
from   v$active_session_history;

spool &out_file append

select json_object('t' value 'meta', 'side' value 'primary', 'db' value d.name, 'uniq' value d.db_unique_name,
         'role' value d.database_role, 'open' value d.open_mode, 'pmode' value d.protection_mode,
         'plevel' value d.protection_level, 'inst' value i.instance_name, 'host' value i.host_name,
         'ver' value i.version_full, 'plat' value d.platform_name, 'from' value '&t_from', 'to' value '&t_to',
         'gen' value to_char(sysdate,'YYYY-MM-DD HH24:MI:SS'), 'tz' value to_char(systimestamp,'TZH:TZM'),
         'ash' value '&ash_src' returning varchar2(4000))
from   v$database d, v$instance i;

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
from  (select to_char(a.sample_time,'HH24:MI') m,
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
from  (select to_char(a.sample_time,'HH24:MI:') || lpad(to_char(trunc(extract(second from a.sample_time) / 10) * 10), 2, '0') b
       from   ash a join lg on lg.session_id = a.blocking_session
       where  a.session_type = 'FOREGROUND' and a.event = 'log file sync')
group  by b
order  by b;

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
select json_object('t' value 'tx', 'ts' value to_char(sample_time,'HH24:MI:SS.FF3'),
         'p' value regexp_substr(program, '\(([^)]+)\)', 1, 1, null, 1), 'ev' value event,
         'seq' value seq#, 'tw' value time_waited returning varchar2(4000))
from   ash
where  session_state = 'WAITING'
and   (program like '%(LGWR)%' or program like '%(LG0%' or program like '%(NSS%'
       or program like '%(TT0%' or program like '%(ARC%' or program like '%(TMON)%')
order  by sample_time;

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
         'b' value to_char(min(b),'HH24:MI'), 'e' value to_char(max(e),'HH24:MI'))
from   h
where  d >= 0
and    e > to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
and    b < to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
group  by event_name, ms
order  by event_name, ms;

-- workload per minute
select json_object('t' value 'wl', 'm' value to_char(begin_time,'HH24:MI'),
         'redo' value round(max(case metric_name when 'Redo Generated Per Sec'   then value end) / 1048576, 3),
         'txn'  value round(max(case metric_name when 'User Transaction Per Sec' then value end), 2),
         'logons' value round(max(case metric_name when 'Logons Per Sec'         then value end), 3),
         'aas'  value round(max(case metric_name when 'Average Active Sessions'  then value end), 2))
from   dba_hist_sysmetric_history
where  dbid = (select dbid from v$database)
and    group_id = 2
and    metric_name in ('Redo Generated Per Sec', 'User Transaction Per Sec', 'Logons Per Sec', 'Average Active Sessions')
and    begin_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
group  by to_char(begin_time,'HH24:MI')
order  by 1;

-- alert log in the window
select json_object('t' value 'alert', 'side' value 'primary', 'ts' value to_char(originating_timestamp,'HH24:MI:SS.FF3'),
         'msg' value substr(rtrim(message_text, chr(10)), 1, 900) returning varchar2(4000))
from   v$diag_alert_ext
where  component_id = 'rdbms'
and    cast(originating_timestamp as timestamp)
       between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by originating_timestamp;

-- earlier Data Guard / network errors
select json_object('t' value 'alhist', 'side' value 'primary', 'ts' value to_char(originating_timestamp,'YYYY-MM-DD HH24:MI:SS'),
         'msg' value substr(rtrim(message_text, chr(10)), 1, 300) returning varchar2(4000))
from  (select originating_timestamp, message_text
       from   v$diag_alert_ext
       where  component_id = 'rdbms'
       and    originating_timestamp > systimestamp - numtodsinterval(&hist_days, 'DAY')
       and   (message_text like '%UNSYNCHRONIZED%' or message_text like '%ORA-16198%' or message_text like '%ORA-03135%'
              or message_text like '%ORA-16055%' or message_text like '%TNS-12535%' or message_text like '%TNS-12170%')
       order  by originating_timestamp desc
       fetch first 300 rows only)
order  by originating_timestamp;

-- archived log sequences sent to the standby destination(s) in the window
select json_object('t' value 'arch', 'side' value 'primary', 'dest' value l.dest_id, 'thr' value l.thread#, 'seq' value l.sequence#,
         'first' value to_char(l.first_time,'HH24:MI:SS'), 'next' value to_char(l.next_time,'HH24:MI:SS'),
         'done' value to_char(l.completion_time,'HH24:MI:SS'), 'creator' value l.creator, 'reg' value l.registrar,
         'fal' value l.fal, 'mb' value round(l.blocks * l.block_size / 1048576, 1))
from   v$archived_log l
where  l.dest_id in (select dest_id from v$archive_dest where target = 'STANDBY')
and    l.completion_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by l.completion_time;

spool off
exit

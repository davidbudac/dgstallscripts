-- Step 1: steady latency or rare long outliers?
prompt
prompt ### 14 Wait averages since instance startup
col avg_ms for 999990.99
select event, total_waits,
       round(time_waited_micro/1000/nullif(total_waits,0),2) avg_ms
from   v$system_event
where  event in ('log file sync','log file parallel write','SYNC Remote Write',
                 'Redo Transport MISC','Redo Transport Open','Redo Transport Detach',
                 'Redo Transport Close','Redo Transport Ping')
order  by event;

prompt
prompt ### 15 SYNC Remote Write histogram since startup (outliers in 1 s+ buckets = stalls)
select wait_time_format, wait_count
from   v$event_histogram_micro
where  event = 'SYNC Remote Write'
order  by wait_time_micro;

prompt
prompt ### 16 SYNC response per destination, whole-second buckets (TIME = last hit)
select dest_id, time, duration seconds, frequency
from   v$redo_dest_resp_histogram
where  frequency > 0
order  by dest_id, duration;

prompt
prompt ### 17 AWR histogram per snapshot in the window (needs Diagnostics Pack)
col wait_ms for 99999999
with h as (
  select s.end_interval_time, h.event_name, h.wait_time_milli,
         h.wait_count - lag(h.wait_count) over
           (partition by h.dbid, h.instance_number, h.event_name, h.wait_time_milli
            order by h.snap_id) waits
  from   dba_hist_event_histogram h
  join   dba_hist_snapshot s
         on s.snap_id = h.snap_id and s.dbid = h.dbid and s.instance_number = h.instance_number
  where  h.event_name in ('SYNC Remote Write','log file sync')
  and    s.end_interval_time >= to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS') - interval '1' day
)
select to_char(end_interval_time,'MM-DD HH24:MI') snap_end, event_name,
       wait_time_milli wait_ms, waits
from   h
where  waits > 0
and    wait_time_milli >= 64
and    end_interval_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
                             and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS') + interval '2' hour
order  by end_interval_time, event_name, wait_time_milli;

prompt
prompt ### 18 Workload per minute: was the application still sending work and logging in?
col redo_mb_s for 99990.99
col txn_s     for 9999990.9
col logons_s  for 99990.99
col aas       for 9990.9
select to_char(begin_time,'MM-DD HH24:MI') minute,
       round(max(case metric_name when 'Redo Generated Per Sec'   then value end)/1048576,2) redo_mb_s,
       round(max(case metric_name when 'User Transaction Per Sec' then value end),1)         txn_s,
       round(max(case metric_name when 'Logons Per Sec'           then value end),2)         logons_s,
       round(max(case metric_name when 'Average Active Sessions'  then value end),1)         aas
from   dba_hist_sysmetric_history
where  group_id = 2
and    metric_name in ('Redo Generated Per Sec','User Transaction Per Sec',
                       'Logons Per Sec','Average Active Sessions')
and    begin_time between to_date(substr('&t_from',1,19),'YYYY-MM-DD HH24:MI:SS')
                      and to_date(substr('&t_to',1,19),'YYYY-MM-DD HH24:MI:SS')
group  by to_char(begin_time,'MM-DD HH24:MI')
order  by 1;

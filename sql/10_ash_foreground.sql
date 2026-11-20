-- Step 1: when did commits wait, and on what? (needs Diagnostics Pack)
prompt
prompt ### 10 Foreground sessions per minute, DBA_HIST ASH (10 s samples)
prompt     Many 'log file sync' rows with blocking_session = LGWR's SID = commits stuck behind LGWR.
select to_char(sample_time,'MM-DD HH24:MI') minute,
       nvl(event,'ON CPU')                  event,
       blocking_session,
       count(*)                             samples
from   dba_hist_active_sess_history
where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
                       and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
and    session_type = 'FOREGROUND'
group  by to_char(sample_time,'MM-DD HH24:MI'), nvl(event,'ON CPU'), blocking_session
order  by 1, 4 desc;

prompt
prompt ### 11 Foreground sessions per minute, V$ ASH (1 s samples; empty once aged out)
select to_char(sample_time,'MM-DD HH24:MI') minute,
       nvl(event,'ON CPU')                  event,
       blocking_session,
       count(*)                             samples
from   v$active_session_history
where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
                       and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
and    session_type = 'FOREGROUND'
group  by to_char(sample_time,'MM-DD HH24:MI'), nvl(event,'ON CPU'), blocking_session
order  by 1, 4 desc;

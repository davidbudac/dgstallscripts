-- Step 1: LGWR and the redo transport processes, sample by sample (needs Diagnostics Pack)
-- Same seq# on consecutive rows = one continuous wait.
-- time_waited_ms is filled only on the sample where the wait ended (0 = still waiting).
col proc for a8
col blk  for 99999
prompt
prompt ### 12 LGWR / NSS / TT / ARC / TMON, DBA_HIST ASH (10 s samples)
select to_char(sample_time,'HH24:MI:SS')                  t,
       session_id                                         sid,
       regexp_substr(program,'\(([^)]+)\)',1,1,null,1)    proc,
       session_state                                      state,
       event, seq#,
       round(time_waited/1000)                            time_waited_ms,
       blocking_session                                   blk,
       p1, p2, p3
from   dba_hist_active_sess_history
where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
                       and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
and   (program like '%(LGWR)%' or program like '%(LG0%' or program like '%(NSS%'
       or program like '%(TT0%' or program like '%(ARC%' or program like '%(TMON)%')
order  by sample_time, proc;

prompt
prompt ### 13 Same, V$ ASH (1 s samples; empty once aged out)
select to_char(sample_time,'HH24:MI:SS')                  t,
       session_id                                         sid,
       regexp_substr(program,'\(([^)]+)\)',1,1,null,1)    proc,
       session_state                                      state,
       event, seq#,
       round(time_waited/1000)                            time_waited_ms,
       blocking_session                                   blk,
       p1, p2, p3
from   v$active_session_history
where  sample_time between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
                       and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
and   (program like '%(LGWR)%' or program like '%(LG0%' or program like '%(NSS%'
       or program like '%(TT0%' or program like '%(ARC%' or program like '%(TMON)%')
order  by sample_time, proc;

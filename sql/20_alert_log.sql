-- Step 2: alert log for the window, unfiltered. PRIMARY only (ORA-01219 on a mounted standby:
-- use sh/alert_log_scan.sh there).
-- Slow on a large alert log; adrci "show alert -p" is the fallback.
prompt
prompt ### 20 Alert log in the window (all messages)
select to_char(originating_timestamp,'MM-DD HH24:MI:SS.FF3') t,
       message_text
from   v$diag_alert_ext
where  component_id = 'rdbms'
and    cast(originating_timestamp as timestamp)
       between to_timestamp('&t_from','YYYY-MM-DD HH24:MI:SS')
           and to_timestamp('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by originating_timestamp;

prompt
prompt ### 21 Earlier occurrences, last &hist_days days (same time of day = scheduled cause?)
select to_char(originating_timestamp,'YYYY-MM-DD HH24:MI:SS.FF3') t,
       message_text
from   v$diag_alert_ext
where  component_id = 'rdbms'
and    originating_timestamp > systimestamp - numtodsinterval(&hist_days,'DAY')
and   (message_text like '%UNSYNCHRONIZED%'
       or message_text like '%ORA-16198%'
       or message_text like '%ORA-03135%'
       or message_text like '%ORA-16055%'
       or message_text like '%TNS-12535%'
       or message_text like '%TNS-12170%')
order  by originating_timestamp;

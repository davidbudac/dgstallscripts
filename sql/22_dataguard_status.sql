-- Steps 2 and 3: in-memory Data Guard messages (recent only; lost at restart). Works on a mounted standby.
col facility for a24
col severity for a13
prompt
prompt ### 22 V$DATAGUARD_STATUS in the window
select to_char(timestamp,'MM-DD HH24:MI:SS') t, facility, severity, dest_id, message message_text
from   v$dataguard_status
where  timestamp between to_date(substr('&t_from',1,19),'YYYY-MM-DD HH24:MI:SS')
                     and to_date(substr('&t_to',1,19),'YYYY-MM-DD HH24:MI:SS')
order  by timestamp;

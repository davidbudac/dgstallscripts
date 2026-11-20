-- Step 3: standby receive side, current state. Most useful while a stall is happening.
col action for a14
col role   for a26
prompt
prompt ### 50 Data Guard processes (RFS = receiving redo)
select name, pid, role, action, client_pid, client_role, thread#, sequence#, block#
from   v$dataguard_process
order  by role, name;

prompt
prompt ### 51 Standby redo logs (all ACTIVE at once = too few or archiving behind)
select thread#, group#, sequence#, status, round(bytes/1048576) mb, last_change#, last_time
from   v$standby_log
order  by thread#, group#;

prompt
prompt ### 52 Lag and apply statistics
col value for a20
col unit for a30
select name, value, unit, time_computed
from   v$dataguard_stats;

prompt
prompt ### 53 Current gaps
select * from v$archive_gap;

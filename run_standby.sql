-- Data Guard SYNC stall analysis: STANDBY side. Read-only, works in MOUNT (no DBA_HIST).
-- Usage (from this directory, on the standby host):
--   sqlplus -S / as sysdba @run_standby.sql "2026-11-13 20:35:00" "2026-11-13 20:58:00" [history_days]
-- Writes dg_standby_<db_unique_name>_<now>.txt in the current directory.
-- The alert log is not readable from SQL in MOUNT: run sh/alert_log_scan.sh as well.
-- history_days is accepted for symmetry with run_primary.sql and not used here.
set termout off
column 3 new_value 3 noprint
select '' "3" from dual where rownum = 0;
define t_from    = "&1"
define t_to      = "&2"
define hist_days = "&3"
column hd new_value hist_days noprint
select nvl('&hist_days','30') hd from dual;
@@sql/_settings.sql
column spool_name new_value spool_name noprint
select 'dg_standby_' || lower(db_unique_name) || '_' || to_char(sysdate,'YYYYMMDD_HH24MISS') || '.txt' spool_name
from   v$database;
set termout on
spool &spool_name
prompt ===== DG SYNC stall analysis: STANDBY, window &t_from to &t_to
@@sql/00_context.sql
@@sql/22_dataguard_status.sql
@@sql/40_redo_shipping.sql
@@sql/50_standby_state.sql
spool off
prompt
prompt Output written to &spool_name
exit

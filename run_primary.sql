-- Data Guard SYNC stall analysis: PRIMARY side. Read-only.
-- Usage (from this directory, on the primary host):
--   sqlplus -S / as sysdba @run_primary.sql "2026-11-13 20:35:00" "2026-11-13 20:58:00" [history_days]
-- Writes dg_primary_<db_unique_name>_<now>.txt in the current directory.
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
select 'dg_primary_' || lower(db_unique_name) || '_' || to_char(sysdate,'YYYYMMDD_HH24MISS') || '.txt' spool_name
from   v$database;
set termout on
spool &spool_name
prompt ===== DG SYNC stall analysis: PRIMARY, window &t_from to &t_to
@@sql/00_context.sql
@@sql/10_ash_foreground.sql
@@sql/12_ash_lgwr_transport.sql
@@sql/14_sync_latency.sql
@@sql/20_alert_log.sql
@@sql/22_dataguard_status.sql
@@sql/30_dest_config.sql
@@sql/40_redo_shipping.sql
spool off
prompt
prompt Output written to &spool_name
exit

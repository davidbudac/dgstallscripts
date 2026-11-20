prompt
prompt ### 00 Context: database, instance, diag paths
col host_name for a30
col db_unique_name for a20
select name, db_unique_name, database_role, open_mode,
       protection_mode, protection_level
from   v$database;

select instance_name, host_name, version_full, startup_time
from   v$instance;

select name, value
from   v$diag_info
where  name in ('Diag Trace', 'Diag Alert', 'ADR Home');

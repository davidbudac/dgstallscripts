-- Step 2: redo transport configuration and current state (primary)
prompt
prompt ### 30 Remote destinations: mode, timers, errors
col destination for a30
col error for a50
select dest_id, destination, status, transmit_mode, affirm,
       net_timeout, reopen_secs, max_failure, failure_count, error
from   v$archive_dest
where  target = 'STANDBY' and status <> 'INACTIVE';

prompt
prompt ### 31 Remote destinations: sync and gap state
select dest_id, status, database_mode, recovery_mode, protection_mode,
       synchronization_status, synchronized, gap_status, error
from   v$archive_dest_status
where  type <> 'LOCAL' and status <> 'INACTIVE';

prompt
prompt ### 32 Transport-related parameters
col value for a150 word_wrapped
select name, value
from   v$parameter
where  (name like 'log_archive_dest_%' and name not like 'log_archive_dest_state%' and value is not null)
   or   name in ('data_guard_sync_latency','fal_server','log_archive_config',
                 'standby_file_management','dg_broker_start');

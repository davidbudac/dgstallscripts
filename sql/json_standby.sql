-- HTML report data, STANDBY side: one JSON object per line, appended to a bundle file.
-- Called by sh/collect.sh. Read-only; works with the standby mounted.
-- Args: 1 = from 'YYYY-MM-DD HH24:MI:SS'  2 = to  3 = history days (unused)  4 = bundle file (appended)
set termout off echo off feedback off verify off heading off pagesize 0 linesize 32767
set trimspool on trimout on tab off
whenever sqlerror continue
define t_from   = "&1"
define t_to     = "&2"
define out_file = "&4"

spool &out_file append

select json_object('t' value 'meta', 'side' value 'standby', 'db' value d.name, 'uniq' value d.db_unique_name,
         'role' value d.database_role, 'open' value d.open_mode, 'pmode' value d.protection_mode,
         'plevel' value d.protection_level, 'inst' value i.instance_name, 'host' value i.host_name,
         'ver' value i.version_full, 'plat' value d.platform_name, 'from' value '&t_from', 'to' value '&t_to',
         'gen' value to_char(sysdate,'YYYY-MM-DD HH24:MI:SS'), 'tz' value to_char(systimestamp,'TZH:TZM')
         returning varchar2(4000))
from   v$database d, v$instance i;

-- sequences received in the window (FAL = YES: fetched as a gap)
select json_object('t' value 'arch', 'side' value 'standby', 'dest' value l.dest_id, 'thr' value l.thread#, 'seq' value l.sequence#,
         'first' value to_char(l.first_time,'HH24:MI:SS'), 'next' value to_char(l.next_time,'HH24:MI:SS'),
         'done' value to_char(l.completion_time,'HH24:MI:SS'), 'creator' value l.creator, 'reg' value l.registrar,
         'fal' value l.fal, 'mb' value round(l.blocks * l.block_size / 1048576, 1))
from   v$archived_log l
where  l.completion_time between to_date('&t_from','YYYY-MM-DD HH24:MI:SS') and to_date('&t_to','YYYY-MM-DD HH24:MI:SS')
order  by l.completion_time;

select json_object('t' value 'srl', 'thr' value thread#, 'grp' value group#, 'seq' value sequence#, 'st' value status,
         'mb' value round(bytes / 1048576))
from   v$standby_log
order  by thread#, group#;

select json_object('t' value 'dgstat', 'name' value name, 'value' value value, 'unit' value unit)
from   v$dataguard_stats;

spool off
exit

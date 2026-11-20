-- Steps 2 and 3: which log sequences were archived/received in the window, how, and when.
-- On the primary: rows for the standby destination show when each sequence reached it.
-- On the standby: FAL = YES means the sequence was fetched as a gap.
col creator   for a7
col registrar for a9
col fal       for a3
prompt
prompt ### 40 Archived logs completed in the window (all destinations)
select dest_id, thread#, sequence#, first_time, next_time, completion_time,
       creator, registrar, fal, round(blocks*block_size/1048576,1) mb
from   v$archived_log
where  completion_time between to_date(substr('&t_from',1,19),'YYYY-MM-DD HH24:MI:SS')
                           and to_date(substr('&t_to',1,19),'YYYY-MM-DD HH24:MI:SS')
order  by completion_time, dest_id;

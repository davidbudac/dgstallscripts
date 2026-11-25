-- sh/collect.sh list: how far back the two database sources of this instance reach, one marker line and one result line each:
--   SRC:ASH, then ASH TAB the oldest sample_time of v$active_session_history (in memory), or ASH TAB - when it holds no rows
--   SRC:AWR, then AWR TAB the oldest begin_interval_time of dba_hist_snapshot, or AWR TAB - when there is no snapshot
-- Read-only (SELECT). Each statement stands alone: one that fails prints its Oracle error after its marker line and the next one still runs
-- (dba_hist_snapshot raises ORA-01219 on a mounted standby). No arguments.
set heading off feedback off pagesize 0 linesize 1000 verify off trimspool on tab off
whenever sqlerror continue
prompt SRC:ASH
select 'ASH' || chr(9) || nvl(to_char(min(sample_time), 'YYYY-MM-DD HH24:MI:SS'), '-') from v$active_session_history;
prompt SRC:AWR
select 'AWR' || chr(9) || nvl(to_char(min(begin_interval_time), 'YYYY-MM-DD HH24:MI:SS'), '-') from dba_hist_snapshot;
exit

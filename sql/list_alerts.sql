-- sh/collect.sh list, primary (open) only: the lines of the alert log that start or end an incident, one per row: time TAB I|S TAB text.
-- I = a line of the one pattern list (same as the history in json_primary.sql); S = a line that ends an UNSYNCHRONIZED period of a destination.
-- Args: 1 = days to look back. Read-only. On a mounted standby v$diag_alert_ext raises ORA-01219: use `collect.sh list -a <alert log>` there.
set heading off feedback off pagesize 0 linesize 1000 verify off trimspool on tab off
whenever sqlerror continue
define hist_days = "&1"
select to_char(ts, 'YYYY-MM-DD HH24:MI:SS') || chr(9) || kind || chr(9) || replace(replace(substr(message_text, 1, 200), chr(10), ' '), chr(9), ' ')
from  (select originating_timestamp ts, message_text,
              case when (
       -- hist-pattern: begin
       case when message_text like '%UNSYNCHRONIZED%'
                 and not (regexp_like(message_text, 'RT_PMODE:[[:space:]]+(PRIMARY|PHYSICAL)[[:space:]]')
                          or regexp_like(message_text, 'UNSYNCHRONIZED[[:space:]]+reason[[:space:]]+ASYNC configuration')) then 1
            when message_text like '%ORA-16198%' or message_text like '%ORA-03135%' or message_text like '%ORA-03113%' or message_text like '%ORA-16055%'
              or message_text like '%ORA-16191%' or message_text like '%TNS-12535%' or message_text like '%TNS-12170%' or message_text like '%TNS-12609%'
              or message_text like '%Possible network disconnect%' then 1
            else 0 end
       -- hist-pattern: end
                   ) = 1 then 'I'
                   when
       -- sync-pattern: begin
       message_text like '%LAD:%' and (message_text like '%level SYNCHRONIZED%' or message_text like '%is SYNCHRONIZED%')
       -- sync-pattern: end
                   then 'S'
              end kind
       from   v$diag_alert_ext
       where  component_id = 'rdbms'
       and    originating_timestamp > systimestamp - numtodsinterval(&hist_days, 'DAY'))
where  kind is not null
order  by ts;
exit

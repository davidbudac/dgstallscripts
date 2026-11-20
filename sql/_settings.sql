-- Common SQL*Plus settings for the DG SYNC stall scripts (read-only).
set linesize 250 pagesize 50000 trimspool on trimout on tab off
set feedback off verify off heading on underline on
alter session set nls_date_format = 'YYYY-MM-DD HH24:MI:SS';
alter session set nls_timestamp_format = 'YYYY-MM-DD HH24:MI:SS.FF3';
col event        for a34
col program      for a10
col message_text for a150 word_wrapped
col name         for a40
col value        for a60

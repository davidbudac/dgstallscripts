# Shared awk fragments for collect.sh and alert_log_scan.sh. Sourced, not run:  . "$DIR/sh/dglib.sh"   (POSIX awk only: no gawk functions)
#
# HISTAWK  dghist(line): 1 when a line is an "earlier occurrence" worth listing. THE list of patterns: sql/json_primary.sql, sql/20_alert_log.sql and
#          sql/list_alerts.sql carry the same list as LIKE / regexp_like patterns between "hist-pattern" markers; tests/run.sh checks that all agree.
#          dgsync(line): 1 for the lines that end an UNSYNCHRONIZED period of a destination (LAD:n ... level SYNCHRONIZED, LAD:n is SYNCHRONIZED): the alsync records and the S lines of `collect.sh list`.
#          sql/json_primary.sql (twice) and sql/list_alerts.sql carry the same condition between "sync-pattern" markers; tests/run.sh checks that those agree with each other and with this function.
#          Routine lines are NOT incidents: RT_PMODE for PRIMARY and PHYSICAL, and "level UNSYNCHRONIZED reason ASYNC configuration".
# DATEAWK  dnum(y,m,d) days since 1970-01-01; ep("YYYY-MM-DD HH:MI:SS") seconds since 1970 (naive, no zone); fmt(seconds) back to the same text.
HISTAWK='
function dghist(s) {
  if (s ~ /UNSYNCHRONIZED/ && !(s ~ /RT_PMODE:[ \t]+(PRIMARY|PHYSICAL)[ \t]/ || s ~ /UNSYNCHRONIZED[ \t]+reason[ \t]+ASYNC configuration/)) return 1
  return (s ~ /ORA-16198|ORA-03135|ORA-03113|ORA-16055|ORA-16191|TNS-12535|TNS-12170|TNS-12609|Possible network disconnect/) }
function dgsync(s) { return (s ~ /LAD:[0-9]+[ \t]+is[ \t]+SYNCHRONIZED/ || (s ~ /LAD:[0-9]+/ && s ~ /level[ \t]+SYNCHRONIZED/)) }'
DATEAWK='
function dnum(y, m, d,   era, yoe, doy) {
  if (m <= 2) y--
  era = int(y / 400); yoe = y - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468 }
function ep(s) { return dnum(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2) }
function fmt(e,   sec, z, era, doe, yoe, y, doy, mp, d, m) {
  sec = e % 86400; z = (e - sec) / 86400 + 719468; era = int(z / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365); y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1; m = (mp < 10 ? mp + 3 : mp - 9); if (m <= 2) y++
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, m, d, int(sec / 3600), int(sec % 3600 / 60), sec % 60) }'

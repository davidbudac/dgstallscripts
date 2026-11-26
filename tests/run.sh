#!/bin/sh
# Tests for dgstallscripts.   Usage: sh tests/run.sh        (UPDATE=1 rewrites tests/expected/* from the current collect.sh and report)
#
#   report build   make_report.sh reproduces examples/sample-report.html under sh and dash
#   bundle format  the example bundles and every bundle collect.sh writes here are well-formed v2 (check_bundle.py)
#   render         headless Chrome: the example (v2) and a v1 bundle give their expected claims, no JS errors; a window across midnight
#                  and one over several days; cov/clock/unknown records change nothing; the generated scenarios of bundle_tool.py gen
#                  (quiet window, two incidents, ASH outside the window, time drift and sampler gap, ORA-03135 only, different UTC offsets,
#                  RT_PMODE families, a RAC primary, a Linux pair with every record of the newer collector with and without a standby sampler gap,
#                  instances started after the window) each give their expected claim file and the assertions listed next to them
#   hand-over      the two plain-text blocks ("For the network team", "For the ticket") of the example, of the v1 and pre-phase-3 bundles and of every scenario:
#                  golden files, one block per incident, no interpretation (tests/wording.py), at most 60 lines and 110 columns for the example,
#                  Copy and Download give the shown text (clicked in the browser with stubs), the newer sections (standby receive side, baseline,
#                  dgstatus rows, destination histogram, network history, recurrence) say what the data says (tests/extract.py --parts)
#   panes          the report pane and the hand-over pane (tab, sidebar, a link of the report, the address #handover, Back and Forward; charts drawn again for the page shown), the section order
#                  (every chart before Signals), no card caption over 120 characters, the Reading disclosures (closed; open for printing, closed again), Copy and Download .txt from the
#                  hand-over pane against the golden hand-over texts (extract.py --captions, --order, --readings, --delivered; gate.sh with GATE_HASH)
#   zoom           the timeline, commit waits, active sessions by wait event, listener logins and sampler share one range: a drag zooms all five, the click ending it goes nowhere, Ctrl + wheel zooms and a plain
#                  wheel does not, the Incident tabs and the Whole window button and tab set the range (hover.html, extract.py --ui)
#   collect.sh     raw-log fixtures with a window across midnight, a failing and a partial sqlplus (stub), the caps; hosts with stubbed tools
#                  (Linux with sar, chronyc, ntpq, getent, netstat, ping, sysctl, lsnrctl; AIX with no, lssrc, ntpq; a bare host with none of them):
#                  listener server-to-server connections, endpoints from tnsnames.ora, sqlnet.ora timeouts, sar parsing from canned output, clock state,
#                  derived peer, the sampler log; `collect.sh list`; the next-command hints; make_report.sh defaults; net_sampler.sh; the history pattern list
#   cards          extract.py --cards: "Episodes side by side", "Who waited", "Active sessions by wait event" (aas: the chart, its series and colours, the empty states, a capped and a failed source;
#                  the per-minute totals of its tooltips against the bundle's fg and aas records, extract.py --aas) and the activity bars of the day-and-hour grid (the example, `full`, `hist`, `stfail` (statements that failed),
#                  `capped` (sources cut at their cap), v1, pre-phase-3 and the scenarios without the lookback and impact records), the grouped entries of the explanation tables, and that none of it is in the hand-over texts
#   new records    collect.sh with the stub's `full` mode: lfs_by, aas, wl_hist, alsync and act (rman, job, logsw) kept, a failing or omitted statement an error cov record,
#                  the standby side, the text alert log path of alsync, caps; lints of the SQL files (every &variable defined, no blank line in a statement, a cov record per record type,
#                  the sync pattern equal in the SQL files and sh/dglib.sh)
#   lint           the shell scripts stay POSIX sh / POSIX awk
# python3 is needed for the format and render tests; the render tests skip with a message when Chrome is missing.
# No database is needed: collect.sh is pointed at a missing or stub sqlplus with SQLPLUS=. The host tools never come from the machine running the tests:
# collect.sh runs with a PATH made of links to the basic utilities plus the stubs of tests/fixtures/host (see mkhost), and DGR_NOW fixes the clock.

T=$(cd "$(dirname "$0")" && pwd); R=$(dirname "$T")
W=${TMPDIR:-/tmp}/dgr-tests.$$; mkdir -p "$W" || exit 1
trap 'rm -rf "$W"' 0 1 2 15
PASS=0 NFAIL=0 NSKIP=0
pass() { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { NFAIL=$((NFAIL + 1)); echo "FAIL  $1"; [ -z "$2" ] || echo "$2" | sed 's/^/          /'; }
skip() { NSKIP=$((NSKIP + 1)); echo "skip  $1"; }
same() { if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$(diff "$2" "$3" | head -12)"; fi; }   # name, got, expected
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
DASH=; [ -x /bin/dash ] && DASH=/bin/dash
EX="$R/examples/sample_primary.jsonl $R/examples/sample_standby.jsonl"

# ---------------------------------------------------------------- report build
for SH in sh $DASH; do
  "$SH" "$R/sh/make_report.sh" -o "$W/report.html" $EX 2>/dev/null
  same "make_report.sh under $SH reproduces examples/sample-report.html" "$W/report.html" "$R/examples/sample-report.html"
done
[ -n "$DASH" ] || skip "make_report.sh under dash: /bin/dash not found"

# ---------------------------------------------------------------- bundle format
if [ $HAVE_PY = 1 ]; then
  for f in $EX; do
    if out=$(python3 "$T/check_bundle.py" "$f" collector); then pass "format: $(basename "$f") is a well-formed v2 bundle with every cov record of the current collector"; else fail "format: $(basename "$f")" "$out"; fi
  done
  python3 "$T/bundle_tool.py" gen "$W/gen"
  nb=0; for f in "$W"/gen/*.jsonl; do nb=$((nb + 1)); if out=$(python3 "$T/check_bundle.py" "$f"); then :; else fail "format: generated $(basename "$f")" "$out"; fi; done
  [ "$NFAIL" -gt 0 ] || pass "format: the $nb generated scenario bundles are well-formed v2 bundles"
else skip "format and render tests: python3 not found"; fi

# ---------------------------------------------------------------- render
# claim files under tests/expected/ are what the report states for a scenario (extract.py): UPDATE=1 rewrites them after an intended change
claims() { if [ -n "$UPDATE" ]; then cp "$2" "$T/expected/$3"; echo "updated tests/expected/$3"; else same "$1" "$2" "$T/expected/$3"; fi; }
has_l() { if grep -Eq "$2" "$1"; then pass "$3"; else fail "$3" "no line matches: $2"; fi; }        # file, regex, name
no_l() { if grep -Eq "$2" "$1"; then fail "$3" "$(grep -E "$2" "$1" | head -3 | cut -c1-240)"; else pass "$3"; fi; }
if [ $HAVE_PY = 1 ] && sh "$T/gate.sh" --have-chrome; then
  render() { n=$1; shift; sh "$T/gate.sh" "$W/$n" "$@"; }
  nojs() { if [ -s "$W/$1.js" ]; then fail "$2: JavaScript console errors" "$(head -5 "$W/$1.js")"; else pass "$2: no JavaScript console errors"; fi; }
  strip() { python3 "$T/extract.py" "$W/$1.dom" --strip > "$W/$1.stripped"; }
  # the same file names in each directory: the report footer shows them
  mkdir -p "$W/v1" "$W/v2" "$W/mid" "$W/multi" "$W/ora" "$W/tz"
  cp "$T/fixtures/v1/"sample_*.jsonl "$W/v1/"; cp $EX "$W/v2/"
  render v1 "$W/v1/sample_primary.jsonl" "$W/v1/sample_standby.jsonl"
  render v2 "$W/v2/sample_primary.jsonl" "$W/v2/sample_standby.jsonl"
  claims "render: v2 example bundles give the expected claims" "$W/v2.txt" baseline.txt
  claims "render: v1 sample bundles give the expected claims (coverage unknown)" "$W/v1.txt" v1.txt
  nojs v1 "render v1"; nojs v2 "render v2"
  strip v2
  n=$(grep -o '&lt;div class="h"&gt;' "$W/v2.dom" | wc -l | tr -d ' ')
  if [ "$n" -gt 100 ]; then pass "render: hovering the charts logged $n tooltips"; else fail "render: hovering the charts logged only $n tooltips"; fi
  if grep -qE 'NaN|undefined|Invalid Date' "$W/v2.stripped"; then fail "render v2: NaN, undefined or Invalid Date on the page"; else pass "render v2: no NaN, undefined or Invalid Date on the page"; fi
  # bundles written before collector phase 3 (no new records, no new cov records, no meta fields) must render exactly as they did
  mkdir -p "$W/pre3"; cp "$T/fixtures/pre3/"sample_*.jsonl "$W/pre3/"
  render pre3 "$W/pre3/sample_primary.jsonl" "$W/pre3/sample_standby.jsonl"
  claims "render: bundles from before collector phase 3 give the claims they gave then" "$W/pre3.txt" baseline_pre3.txt
  nojs pre3 "render of a pre-phase-3 bundle"
  no_l "$W/pre3.txt" 'RAC database' "render: a bundle without cluster_database / inst_count shows no RAC notice"
  # claims that must never come back, in any report
  for n in v1 v2; do no_l "$W/$n.txt" 'Points to:|Commits blocked|remote end stopped answering' "render $n: none of the retired claims (\"Points to\", \"Commits blocked\", \"remote end stopped answering\")"; done
  # v1: no coverage records, so nothing is ruled out; the reason is stated
  no_l "$W/v1.txt" '^RULED:' "render v1: nothing is ruled out without coverage records"
  has_l "$W/v1.txt" '^NOTICES: .*Coverage unknown' "render v1: a notice says coverage is unknown"
  has_l "$W/v1.txt" '^NOTCHECKED: .*coverage unknown' "render v1: not-checked entries give coverage unknown as the reason"
  has_l "$W/v1.txt" '^STAT: Commits behind LGWR .*bucket counts only' "render v1: the commit figure says it comes from bucket counts"
  # the example: observations come with time, host, source and precision; readings are conditional
  has_l "$W/v2.txt" '^  OBSERVED: 20:38:58.734 \| Primary \| alert log \(v\$diag_alert_ext\) \| ORA-16198' "render v2: the ORA-16198 observation carries time, host and source"
  has_l "$W/v2.txt" '^  READING: If the primary instance and its clock ran normally' "render v2: the reading is conditional"
  has_l "$W/v2.txt" 'client address \(ADDRESS=\(PROTOCOL=tcp\)\(HOST=198.51.100.11\)\(PORT=40112\)\)' "render v2: the client address of the Fatal NI block is an observation"
  has_l "$W/v2.txt" '^STAT: Commit waits ≥ 1 s ≥ 21.6 s .*longest wait ≥ 20.0 s; 18 sessions' "render v2: the commit wait is a bound from per-wait records"
  hand() {   # render name, golden name: the two hand-over texts
    python3 "$T/extract.py" "$W/$1.dom" --net > "$W/$1.net"; python3 "$T/extract.py" "$W/$1.dom" --ticket > "$W/$1.ticket"
    claims "hand-over, network team, $2: the text is the expected one" "$W/$1.net" "handover_$2.net.txt"
    claims "hand-over, ticket, $2: the text is the expected one" "$W/$1.ticket" "handover_$2.ticket.txt"
    if out=$(python3 "$T/wording.py" "$W/$1.net" "$W/$1.ticket"); then pass "hand-over, $2: no interpretation, cause, advice or question outside quoted log text; ASCII only"; else fail "hand-over, $2: wording" "$out"; fi
    st=$(python3 "$T/wording.py" --stats "$W/$1.net"); w=${st##*maxwidth=}
    if [ "$w" -le 110 ]; then pass "hand-over, $2: no line of the network text is wider than 110 columns ($st)"; else fail "hand-over, $2: a line is $w columns wide" "$st"; fi
  }
  parts() { python3 "$T/extract.py" "$W/$1.dom" --parts > "$W/$1.parts"; claims "newer sections, $2: what they say is the expected text" "$W/$1.parts" "parts_$2.txt"; }
  cards() { python3 "$T/extract.py" "$W/$1.dom" --cards > "$W/$1.cards"; claims "episodes side by side, who waited, activity bars, $2: what they say is the expected text" "$W/$1.cards" "cards_$2.txt"; }
  hand v2 sample; hand v1 v1; hand pre3 pre3; parts v2 sample; parts v1 v1; parts pre3 pre3; cards v2 sample; cards v1 v1; cards pre3 pre3
  st=$(python3 "$T/wording.py" --stats "$W/v2.net"); l=${st#*lines=}; l=${l%% *}
  if [ "$l" -le 60 ]; then pass "hand-over, sample: the network text of one incident has $l lines (at most 60)"; else fail "hand-over, sample: $l lines" "$st"; fi
  tl=$(python3 "$T/wording.py" --stats "$W/v2.ticket"); tl=${tl#*lines=}; tl=${tl%% *}
  if [ "$tl" -lt "$l" ]; then pass "hand-over, sample: the ticket text ($tl lines) is shorter than the network text ($l lines)"; else fail "hand-over, sample: the ticket text has $tl lines, the network text $l"; fi
  python3 "$T/extract.py" "$W/v2.dom" --facts > "$W/v2.facts"
  has_l "$W/v2.net" '^Oracle Data Guard redo transport \(TCP\) from primary prim-host.example 198.51.100.11 to standby$' "hand-over, sample: the first line names the hosts and the direction"
  has_l "$W/v2.net" '^19:38:58.734Z 20:38:58.734 primary ORA-16198 ' "hand-over, sample: the timeout error carries its time in UTC and in the host's local time, the host and the code"
  has_l "$W/v2.net" 'address: \(ADDRESS=\(PROTOCOL=tcp\)\(HOST=198.51.100.11\)\(PORT=40112\)\)' "hand-over, sample: the standby's network error block gives the client address as logged"
  has_l "$W/v2.net" '^ +12535, ns secondary 12560, nt main 0, nt secondary 0, nt OS 0; Client' "hand-over, sample: the error numbers of the block are as logged"
  has_l "$W/v2.net" '^19:53:27.905Z 20:53:27.905 primary LAD:2 SYNCHRONIZED' "hand-over, sample: the time the destination was synchronized again"
  has_l "$W/v2.net" 'not available, primary and standby: sar ETCP, TCP, DEV, EDEV: no sysstat network history on this host \(AIX\)' "hand-over, sample: an unavailable measurement source is one line with the reason from its cov record"
  has_l "$W/v2.net" 'NET_TIMEOUT 30 s, REOPEN 300 s' "hand-over, sample: the destination timeouts"
  has_l "$W/v2.net" 'SQLNET.EXPIRE_TIME 10; not set: SQLNET.OUTBOUND_CONNECT_TIMEOUT' "hand-over, sample: sqlnet.ora timeouts, with the ones that are not set"
  has_l "$W/v2.net" '^primary ntpq -p 08:12:40Z: source ntp1.example.net, stratum 2, offset \+0.412 ms' "hand-over, sample: the NTP state of each host as collected, with the time it was read"
  has_l "$W/v2.net" '^primary -> 198.51.100.12:1526 08:12:58Z: rtt avg 0.41 ms' "hand-over, sample: the check at collection time is a section of its own and says when it ran (UTC)"
  has_l "$W/v2.net" 'primary sampler: 5 of 209 pings without reply \(20:38:35 to 20:38:55 local\)' "hand-over, sample: the sampler of the window is listed apart from the check at collection time"
  has_l "$W/v2.net" 'standby ASH: holds nothing before 2026-11-14 03:51:20Z' "hand-over, sample: a source that did not cover the incident is listed with its reason"
  has_l "$W/v2.ticket" '^Destination LAD:2 not synchronized: 14 min 29 s' "hand-over, sample: the ticket gives how long the destination was not synchronized"
  has_l "$W/v2.ticket" '^least 20.0 s, less than 40.0 s; most sessions in one sample 18' "hand-over, sample: the ticket gives the commit wait with its bounds"
  has_l "$W/v2.ticket" '^Longest SYNC write: LGWR .SYNC Remote Write., at least 20.0 s, less than 40.0 s' "hand-over, sample: the ticket gives the longest SYNC write with its bound"
  has_l "$W/v2.ticket" 'ORA-16198 at 19:38:58.734Z' "hand-over, sample: the ticket gives the transport error with its code and its time in UTC"
  has_l "$W/v2.ticket" '^Not covered for that interval: standby ASH source' "hand-over, sample: the ticket says what the data did not cover for the incident interval"
  no_l "$W/v2.ticket" '^(Summary|Impact|Root cause|Next steps|Title)' "hand-over, sample: the ticket has no title, summary, impact, root cause or next-steps scaffolding"
  has_l "$W/v2.facts" '\| ntp \|' "render v2: the NTP state is in the facts list"
  has_l "$W/v2.facts" '\| lastok \|.*\| quiet$' "render v2: the facts list marks what the report does not repeat in every incident as quiet"
  has_l "$W/v2.facts" '^FACT as collected \| primary \| cfg \| .*endpoints: primary host prim-host.example .*network checks \(collect.sh -p\): primary to 198.51.100.12:1526, standby to 198.51.100.11:1526' "render v2: the facts list holds the endpoints"
  has_l "$W/v2.facts" '^CLOCKS .*"standby_times_converted_to_primary_time": false' "render v2: the facts list says whether standby times were converted"
  has_l "$W/v2.facts" 'FACT 2026-11-13 20:39:09.112 \| standby \| ni \|' "render v2: the facts list holds the standby's Fatal NI block"

  # the v2 sample moved by 3 h 22 min: 23:57 -> 00:20, the stall straddles midnight
  for s in primary standby; do python3 "$T/bundle_tool.py" shift 12120 "$R/examples/sample_$s.jsonl" > "$W/mid/sample_$s.jsonl"; done
  render mid "$W/mid/sample_primary.jsonl" "$W/mid/sample_standby.jsonl"
  python3 "$T/extract.py" "$W/mid.dom" --mask > "$W/mid.masked"; python3 "$T/extract.py" "$W/v2.dom" --mask > "$W/base.masked"
  same "render: a window across midnight changes only the clock times (durations, counts and titles equal the baseline)" "$W/mid.masked" "$W/base.masked"
  if grep -q '^SUB: .*2026-11-13 23:57:00 to 2026-11-14 00:20:00' "$W/mid.txt" && grep -q 'STAT: Destination not synchronized .* 11-14 00:00:58 → 11-14 00:15:27' "$W/mid.txt" \
     && grep -q 'OBSERVED: 11-14 00:00:58.734 | Primary | alert log (v$diag_alert_ext) | ORA-16198' "$W/mid.txt"; then pass "render: a window across midnight shows the date on its times"
  else fail "render: a window across midnight shows the date on its times" "$(grep -E '^(SUB|STAT)' "$W/mid.txt")"; fi
  if grep -q '&lt;div class="h"&gt;11-14 00:0' "$W/mid.dom" && grep -q 'Standby · 11-13 23:58' "$W/mid.dom"; then pass "render: tooltips carry the date when the window crosses midnight"
  else fail "render: tooltips carry the date when the window crosses midnight"; fi
  nojs mid "render across midnight"
  strip mid; if grep -qE 'NaN|undefined|Invalid Date' "$W/mid.stripped"; then fail "render across midnight: NaN, undefined or Invalid Date on the page"; fi

  # the browser's own zone must not matter: the window sits in the repeated hour of the New York clock change (2026-11-01 01:00-02:00)
  for s in primary standby; do python3 "$T/bundle_tool.py" shift -1104900 "$R/examples/sample_$s.jsonl" > "$W/tz/sample_$s.jsonl"; done
  TZ=America/New_York render tz "$W/tz/sample_primary.jsonl" "$W/tz/sample_standby.jsonl"
  python3 "$T/extract.py" "$W/tz.dom" --mask > "$W/tz.masked"
  grep -v '^HISTNOTE' "$W/tz.masked" > "$W/tz.masked2"; grep -v '^HISTNOTE' "$W/base.masked" > "$W/base.masked2"   # the history does not move with the window: how many episodes lie before and after it changes
  same "render: the browser's time zone (New York, on its clock-change night) moves nothing" "$W/tz.masked2" "$W/base.masked2"
  if grep -q '^SUB: .*2026-11-01 01:40:00 to 02:03:00' "$W/tz.txt" && grep -q 'STAT: Commit waits ≥ 1 s ≥ 21.6 s .* 18 sessions at 01:43:50' "$W/tz.txt"; then pass "render: times show as logged in that zone"
  else fail "render: times show as logged in that zone" "$(grep -E '^(SUB|STAT: Commit)' "$W/tz.txt")"; fi
  nojs tz "render in another browser zone"

  # the same data in a window of two days
  for s in primary standby; do python3 "$T/bundle_tool.py" extend "2026-11-15 20:58:00" "$R/examples/sample_$s.jsonl" > "$W/multi/sample_$s.jsonl"; done
  render multi "$W/multi/sample_primary.jsonl" "$W/multi/sample_standby.jsonl"
  nojs multi "render over two days"
  strip multi
  if grep -qE 'NaN|undefined|Invalid Date' "$W/multi.stripped" || ! grep -q '^SUB: .* to 2026-11-15 20:58:00' "$W/multi.txt"; then fail "render over two days: dates missing or NaN on the page"
  else pass "render over two days: dates on the page, no NaN"; fi

  # a cov record whose note quotes an ORA- error, a clock record and an unknown record type must not show up as failed queries
  cp "$R/examples/sample_primary.jsonl" "$W/ora/sample_primary.jsonl"; cp "$R/examples/sample_standby.jsonl" "$W/ora/sample_standby.jsonl"
  echo '{"t":"cov","side":"primary","src":"alert_sql","st":"error","first":null,"last":null,"n":0,"cap":null,"capped":false,"note":"no coverage record: ORA-00942: table or view does not exist"}' >> "$W/ora/sample_primary.jsonl"
  echo '{"t":"from_the_future","side":"primary","x":1}' >> "$W/ora/sample_primary.jsonl"
  echo '{"t":"cov","side":"primary","src":"from_the_future","st":"ok","first":null,"last":null,"n":1,"cap":null,"capped":false,"note":"a source of a later collector"}' >> "$W/ora/sample_primary.jsonl"
  render ora "$W/ora/sample_primary.jsonl" "$W/ora/sample_standby.jsonl"
  no_l "$W/ora.txt" '^NOTICES: .*Queries that failed' "render: cov notes with ORA- text, clock and unknown records are not failed queries"
  nojs ora "render with extra records"

  # one side only, and a bundle with nothing in it: the page must still render
  mkdir -p "$W/edge"; : > "$W/edge/empty.jsonl"
  render e_p "$W/gen/two_primary.jsonl"; nojs e_p "primary bundle only"; has_l "$W/e_p.txt" '^NOTICES: No standby bundle' "primary bundle only: a notice says the standby is missing"
  render e_s "$W/gen/two_standby.jsonl"; nojs e_s "standby bundle only"; has_l "$W/e_s.txt" '^NOTICES: No primary bundle' "standby bundle only: a notice says the primary is missing"
  render e_0 "$W/edge/empty.jsonl"; nojs e_0 "an empty bundle"
  no_l "$W/e_s.txt" '^RULED:' "standby bundle only: nothing is ruled out"
  # ---- scenarios (generated by bundle_tool.py gen): each states what it must show, and the whole claim file is kept under tests/expected/
  for sc in quiet two noash drift lost tzoff rtpmode rac full sbgap late hist waitcov; do
    render g_$sc "$W/gen/${sc}_primary.jsonl" "$W/gen/${sc}_standby.jsonl"
    nojs g_$sc "scenario $sc"
    claims "scenario $sc: the claims are the expected ones" "$W/g_$sc.txt" "scenario_$sc.txt"
    hand g_$sc "$sc"; parts g_$sc "$sc"
    no_l "$W/g_$sc.txt" 'Points to:|Commits blocked|remote end stopped answering' "scenario $sc: none of the retired claims"
    no_l "$W/g_$sc.txt" 'NaN|undefined|Invalid Date' "scenario $sc: no NaN, undefined or Invalid Date in the claims"
  done
  # lookback records that failed (stfail) or were cut at their cap (capped): rendered for the cards only, so no hand-over, parts or claim file of their own
  for sc in stfail capped; do
    render g_$sc "$W/gen/${sc}_primary.jsonl" "$W/gen/${sc}_standby.jsonl"
    nojs g_$sc "scenario $sc"
    no_l "$W/g_$sc.txt" 'NaN|undefined|Invalid Date' "scenario $sc: no NaN, undefined or Invalid Date in the claims"
  done
  # quiet window: three isolated 1 s samples of log file sync are ordinary commit activity, not a blocked period
  has_l "$W/g_quiet.txt" '^STAT: Incidents None' "quiet window: no incident"
  has_l "$W/g_quiet.txt" '^STAT: Commit waits ≥ 1 s None longest single wait under 2.0 s \(one sample\)' "quiet window: isolated single samples give no blocked duration"
  no_l "$W/g_quiet.txt" '^SIGNAL' "quiet window: no signal"
  # two incidents in one window
  has_l "$W/g_two.txt" '^STAT: Incidents 2 first 10:05:00, last 10:30:00' "two incidents: the card counts both"
  [ "$(grep -c '^SIGNAL: Incident' "$W/g_two.txt")" = 2 ] && pass "two incidents: one signal block per incident" || fail "two incidents: one signal block per incident"
  has_l "$W/g_two.txt" '^SIGNAL: Incident 2 .* · ORA-03135' "two incidents: the second one (ORA-03135 with a gap) is described, not dropped"
  has_l "$W/g_two.txt" '^STAT: Commit waits ≥ 1 s ≥ 29.1 s .*longest wait 30.1 s; 12 sessions at 10:05:25' "two incidents: commit waits come from the per-wait records, exact where time_waited is present"
  # ASH that does not cover the window: not checked, never ruled out
  no_l "$W/g_noash.txt" '^RULED: .*(SYNC write stall|Local redo|Primary host)' "ASH outside the window: nothing is ruled out from it"
  has_l "$W/g_noash.txt" '^NOTCHECKED: SYNC write stall before the first event · primary ASH holds nothing before 2026-11-20 10:20:10' "ASH outside the window: not checked, with the reason"
  has_l "$W/g_noash.txt" '^NOTCHECKED: Primary host stopped for the whole wait · no ASH sample before' "ASH outside the window: the host-stop question is not checked"
  # a time drift and a sampler gap: surfaced as observations, and no network-style reading
  has_l "$W/g_drift.txt" '^  OBSERVED: .* \| Primary \| alert log .* \| "Warning: VKTM detected a forward time drift\."' "drift: the primary's VKTM line is an observation"
  has_l "$W/g_drift.txt" '^  OBSERVED: .* \| Standby \| alert log file \| "Warning: VKTM detected a forward time drift\."' "drift: the standby's VKTM line is an observation"
  has_l "$W/g_drift.txt" '^  OBSERVED: .* \| ASH sample_id against sample_time \| consecutive samples' "drift: the ASH sampler gap is an observation"
  has_l "$W/g_drift.txt" '^  OBSERVED: .*the line is stamped .* its begin time .* is 17 min 18 s earlier, while the message states 30 s' "drift: the LGWR trace line that disagrees with the clock is an observation"
  no_l "$W/g_drift.txt" 'If the primary instance and its clock ran normally|remote end|stopped answering' "drift: no network-style reading"
  has_l "$W/g_drift.txt" '^  READING: The primary.s LGWR gave up on a SYNC wait .* This data cannot show whether the reply was lost' "drift: the reading says the data cannot discriminate"
  no_l "$W/g_drift.txt" '^RULED: .*(stopped for the whole wait|SYNC write stall)' "drift: no host-stop and no SYNC-stall claim is ruled out"
  has_l "$W/g_drift.txt" '^STAT: Host or clock indicators 4 ' "drift: the card counts the indicators"
  # ORA-03135 without ORA-16198
  has_l "$W/g_lost.txt" '^SIGNAL: Incident 1 .* · ORA-03135, destination UNSYNCHRONIZED' "ORA-03135 without ORA-16198: the incident is described"
  has_l "$W/g_lost.txt" '^  READING: ORA-03135 at .* An instance or host shutdown on either side is enough to end a connection' "ORA-03135 incident: the shutdown lines are named as a possible explanation"
  has_l "$W/g_lost.txt" '^STAT: Destination not synchronized 1 min 58 s ' "ORA-03135 incident: the unsynchronized period ends at the primary shutdown"
  # clocks: standby times are converted to the primary's local time, with a notice
  has_l "$W/g_tzoff.txt" '^NOTICES: Clocks differ between the hosts' "UTC offsets differ: a notice says so"
  has_l "$W/g_tzoff.txt" '^SUB: .*primary UTC\+01:00, standby UTC\+00:00; standby times converted to primary time' "UTC offsets differ: the header says which zone each side used"
  has_l "$W/g_tzoff.txt" '^  OBSERVED: 11:05:32.900 \| Standby \|' "UTC offsets differ: a standby line logged at 10:05:32.900 its own time is shown at 11:05:32.900"
  has_l "$W/g_tzoff.txt" '^RULED: Standby host stopped for the whole wait · the standby alert log has 2 lines \(first 11:05:12.300\)' "UTC offsets differ: the converted standby time falls inside the primary's wait interval"
  has_l "$W/g_tzoff.txt" 'assumes the hosts. clocks agree' "UTC offsets differ: the reading states the clock assumption"
  # RT_PMODE families
  has_l "$W/g_rtpmode.txt" '^STAT: Incidents 2 first 10:30:00, last 10:40:00' "RT_PMODE: \"reason ASYNC configuration\" and the PRIMARY/PHYSICAL lines are not incidents"
  has_l "$W/g_rtpmode.txt" '^STAT: Destination not synchronized 1 min 10 s 2 periods' "RT_PMODE: only the two real unsynchronized periods are counted"
  has_l "$W/g_rtpmode.txt" 'with the reason "destination has a gap"' "RT_PMODE: the stated reason is surfaced"
  has_l "$W/g_rtpmode.txt" 'with the reason "no available SRLs"' "RT_PMODE: another stated reason is surfaced"
  has_l "$W/g_rtpmode.txt" '^HISTNOTE: 2 episodes on 2 days .*7 routine lines' "RT_PMODE: the history counts episodes and leaves out the routine lines"
  has_l "$W/g_two.txt" '^NONEFOUND: Incident 1 · VKTM time-drift warning on either host' "two incidents: an absence is listed as \"none found\", not as ruled out"
  no_l "$W/g_two.txt" '^RULED: .*(VKTM|Refused logins)' "two incidents: absence-only entries are not under \"Ruled out\""
  has_l "$W/g_lost.txt" '^  READING: ORA-03135 at .*: the primary at 10:15:00.400 \(1.4 s before the error\) and the standby at 10:15:01.600 \(180 ms before the error\)' "ORA-03135 incident: each side's shutdown lines are listed with their own distance"
  has_l "$W/g_lost.txt" '^STAT: Destination not synchronized 1 min 58 s .* \(the primary instance shutdown; no SYNCHRONIZED line\)' "ORA-03135 incident: the period ends at the primary's instance shutdown, not at the window end"
  has_l "$W/g_lost.txt" 'Nonzero nt secondary / nt OS codes \(nt secondary 113\)' "ORA-03135 incident: a nonzero nt secondary code is called an errno value, not \"no OS error\""
  # RAC: the collector reads one instance; meta.cluster_database / inst_count make the report say so, and only then
  has_l "$W/g_rac.txt" '^NOTICES: .*The primary is a RAC database cluster_database TRUE, 2 instance\(s\) open; data of one instance only \(proddb1, prim-host\.example\); blockers on the others are not resolved' "RAC: a notice says only one instance was collected and what is not resolved"
  no_l "$W/g_quiet.txt" 'RAC database' "RAC: no notice for a single instance (cluster_database FALSE)"
  no_l "$W/v2.txt" 'RAC database' "RAC: no notice on the example bundles (cluster_database FALSE, 1 instance)"
  no_l "$W/v1.txt" 'RAC database' "RAC: no notice on a v1 bundle (no such fields)"
  mkdir -p "$W/racn"; sed 's/"inst_count":1/"inst_count":3/' "$W/gen/quiet_primary.jsonl" > "$W/racn/quiet_primary.jsonl"; cp "$W/gen/quiet_standby.jsonl" "$W/racn/"
  render g_racn "$W/racn/quiet_primary.jsonl" "$W/racn/quiet_standby.jsonl"; nojs g_racn "RAC with more than one instance"
  has_l "$W/g_racn.txt" '^NOTICES: .*The primary is a RAC database cluster_database FALSE, 3 instance\(s\) open' "RAC: more than one open instance is enough"
  # the coverage table lists the sources it knows (the newer collector's too); a source it does not know stays out, and so do the by-design skips of the other side
  KNOWN='database|ash|awr_snap|sysmetric|lfs|lfs_by|aas|alsync|wl_hist|act|ashgap|tx|alert_sql|alert_text|alhist|dgstatus|trace|listener|lsnr_ref|lsnr_srv|cid|net|ep|conn|sqlnet|ostcp|ntp|sar|netsamp|dest_hist|base_hist|rfs_ev|rfs_hist|dgproc|archgap'
  if [ "$(grep '^COV:' "$W/v2.txt" | grep -cvE "^COV: (primary|standby)/($KNOWN)")" = 0 ]; then pass "render: every row of the coverage table is a source the page knows"; else fail "render: unknown cov sources in the coverage table" "$(grep '^COV:' "$W/v2.txt" | cut -c1-100)"; fi
  for src in tx dgstatus lsnr_srv ep conn sqlnet ostcp ntp sar netsamp dest_hist base_hist rfs_ev rfs_hist dgproc archgap; do has_l "$W/g_full.txt" "^COV: (primary|standby)/$src" "render full: the coverage table has the source $src"; done
  for src in primary/lfs_by primary/aas primary/wl_hist primary/alsync/sql standby/alsync/text primary/act/rman primary/act/job primary/act/logsw standby/act/rman; do has_l "$W/g_full.txt" "^COV: $src " "render full: the coverage table has the source $src (a source with kinds shows its kind)"; done
  no_l "$W/g_full.txt" '^COV: standby/(lfs_by|aas|wl_hist|act/job|act/logsw) ' "render full: the by-design skips of the standby (lfs_by, aas, wl_hist, job and log-switch activity) are not listed"
  has_l "$W/g_full.txt" '^COV: primary/wl_hist \| ok \| 11-12 00:00 – 11-20 14:00 \| 206 / cap 1500 \| not a window source$' "render full: the lookback sources say they are not window sources (wl_hist, alsync, act)"
  has_l "$W/g_full.txt" '^COV: primary/lfs_by \| ok \| .* \| 10 / cap 15 \| yes$' "render full: lfs_by is a window source and holds the window"
  no_l "$W/g_full.txt" '^COV: primary/(rfs_ev|rfs_hist|dgproc|archgap)' "render full: the primary's by-design skips of standby-only sources are not listed"
  no_l "$W/ora.txt" '^COV: .*from_the_future' "render: a cov source the page does not know stays out of the coverage table"
  has_l "$W/g_full.txt" '^COV: standby/sar/ETCP \| error ' "render full: a sysstat report the file lacks is an error row with sar's message"
  has_l "$W/g_full.txt" '^COV: standby/sar/ETCP .*Requested activities not available in file /var/log/sa/sa20' "render full: ... and the message is in the row"
  python3 "$T/extract.py" "$W/g_drift.dom" --facts > "$W/g_drift.facts"
  [ "$(grep -c '^FACT .*| drift |' "$W/g_drift.facts")" = 2 ] && pass "drift: the facts list holds both VKTM lines" || fail "drift: the facts list holds both VKTM lines"
  has_l "$W/g_drift.facts" '^FACT .*\| primary \| gap \| ASH sample_id against sample_time' "drift: the facts list holds the sampler gap"
  # ---- the hand-over texts and the newer sections, scenario by scenario
  [ "$(grep -c '^#### incident' "$W/g_two.net")" = 2 ] && [ "$(grep -c '^#### incident' "$W/g_two.ticket")" = 2 ] && pass "hand-over, two incidents: one block per incident, in both texts" || fail "hand-over, two incidents: one block per incident"
  has_l "$W/g_two.net" '^Incident 1 of 2: 2026-11-20 10:05:00Z' "hand-over, two incidents: the first block says which incident it is"
  has_l "$W/g_two.net" '^Incident 2 of 2: 2026-11-20 10:30:00Z' "hand-over, two incidents: the second block says which incident it is"
  has_l "$W/g_two.ticket" '^Incident 2 of 2: ' "hand-over, two incidents: the ticket has a block for the second one too"
  has_l "$W/g_quiet.net" '^No incident in the data of the window 2026-11-20 09:20:00Z to 09:45:00Z: the primary alert log covers the$' "hand-over, quiet window: the text says that no incident was found and what it rests on"
  has_l "$W/g_quiet.ticket" '^Incident: none found in the data \(the primary alert log covers the window\)' "hand-over, quiet window: the ticket says the same"
  has_l "$W/g_noash.ticket" '^Not covered for that interval: primary ASH source \(holds nothing before 2026-11-20 10:20:10Z' "hand-over, ASH outside the window: the ticket says that the primary ASH did not cover it"
  has_l "$W/g_lost.net" 'shutdown or process-termination line' "hand-over, ORA-03135 after a shutdown: the shutdown lines are host-side observations"
  has_l "$W/g_lost.net" 'nt main 513, nt secondary$' "hand-over, ORA-03135 incident: the nonzero nt secondary code is given as logged (1/2)"
  has_l "$W/g_lost.net" '^ +113, nt OS 0; connecting to' "hand-over, ORA-03135 incident: the nonzero nt secondary code is given as logged (2/2)"
  has_l "$W/g_drift.net" '^09:5[0-9]:[0-9][0-9]\.[0-9]*Z .* primary LGWR trace line: begin time <11/20/2026 09:48:12> is 17 min 18 s earlier|primary LGWR trace line: begin time <11/20/2026 09:48:12> is 17 min 18 s earlier' "hand-over, drift: the LGWR trace line that disagrees with the clock is a host-side observation"
  has_l "$W/g_drift.net" 'standby alert log "Warning: VKTM detected a forward time drift\."' "hand-over, drift: the standby's VKTM line is listed with its host"
  no_l "$W/g_drift.net" '^VKTM time-drift lines: none' "hand-over, drift: it does not say that no VKTM line was found"
  has_l "$W/g_tzoff.net" '^10:05:32.900Z 10:05:32.900 standby' "hand-over, different offsets: a standby line logged at 10:05:32.900 on its own clock is 10:05:32.900Z at UTC+00:00"
  has_l "$W/g_tzoff.net" '^10:05:30.200Z 11:05:30.200 primary ORA-16198' "hand-over, different offsets: the primary line at 11:05:30.200 local (UTC+01:00) is 10:05:30.200Z"
  has_l "$W/g_tzoff.net" '^\(primary \+01:00, standby \+00:00\)\. Tags:' "hand-over, different offsets: the header says which offset each host used"
  has_l "$W/g_full.net" '^09:05:30.200Z 10:05:30.200 primary ORA-16198 ' "hand-over, full: the primary's error at 10:05:30.200 local is 09:05:30.200Z"
  has_l "$W/g_full.net" '^09:05:31.100Z 09:05:31.100 standby Fatal NI connect error 12170: "TNS-12535: TNS:operation timed out",' "hand-over, full: the standby's block is at the standby's own local time, which is an hour behind the primary's clock"
  has_l "$W/g_full.net" '^ +\(ADDRESS=\(PROTOCOL=tcp\)\(HOST=198.51.100.11\)\(PORT=40112\)\)' "hand-over, full: the client address of the block is as logged"
  no_l "$W/g_full.net" 'BEQ|beq|PROGRAM=oracle\)\(ARGV0' "hand-over, full: a local (BEQ) error block is not a network fact and is left out"
  has_l "$W/g_full.net" '^09:05:40Z +09:05:40 +standby listener: from 198.51.100.11:51234, service SID:proddb_s, return code 12518$' "hand-over, full: a connection of the peer at the standby listener, with source IP and port, time and result"
  has_l "$W/g_full.net" '^09:10:05Z +10:10:05 +primary listener: from 198.51.100.12:50123, service proddb, return code 0 \[1 s\]$' "hand-over, full: ... and at the primary listener, after the incident began, with the return code as logged"
  no_l "$W/g_full.net" '192\.0\.2\.77' "hand-over, full: a PROGRAM=oracle connection from another address (a database link) is not listed as a connection of the peer"
  has_l "$W/g_full.net" '^09:04:35Z +10:04:35 +primary last SYNC Remote Write that ASH sampled as completed, time_waited 3 ms' "hand-over, full: the last SYNC write that ASH sampled as completed before the stall"
  has_l "$W/g_full.net" '^09:05:00Z +10:05:00 +primary SYNC wait that timed out began \(LGWR trace: begin time <11/20/2026$' "hand-over, full: the start of the wait that timed out, from the LGWR trace"
  has_l "$W/g_full.net" 'sar ETCP: atmptf/s 0.12, estres/s 0.2, retrans/s 12.5, isegerr/s 0.4, orsts/s 0.9' "hand-over, full: the TCP retransmission rate of the interval that overlaps the incident"
  has_l "$W/g_full.net" 'sar eth0: rxpck/s 149, txpck/s 108, rxkB/s 127, txkB/s 84.35; EDEV all 0/s \[avg\]' "hand-over, full: interface and error rates per interface"
  has_l "$W/g_full.net" '^09:04:05Z +09:04:05 +standby sampler: 6 of 88 pings without reply \(09:05:05 to 09:05:30 local\)' "hand-over, full: the standby's sampler at the standby's own local time"
  has_l "$W/g_full.net" "not available, standby: sar ETCP, TCP: not recorded by this host's sysstat file" "hand-over, full: a sysstat report the host did not record is one line with the reason"
  has_l "$W/g_full.net" 'network check \(ping, retransmit counter, Send-Q\): not run \(primary and standby: "option -p not given"\)' "hand-over, full: no check at collection time: said so, with the reason of its cov record"
  has_l "$W/g_full.net" '^UTC offset in the window: primary \+01:00 \(alert log\), standby \+00:00 \(alert log\)' "hand-over, full: the UTC offset of each host in the window"
  has_l "$W/g_full.net" '^primary chronyc tracking 13:45:00Z: source ntp1.example.net, stratum 3, offset \+0.412 ms, synced yes' "hand-over, full: the NTP state of each host as collected"
  has_l "$W/g_full.net" '^before the window: 7 found, newest first: 2026-11-19 09:04Z' "hand-over, full: the episodes of the alert-log history before the window, in UTC"
  has_l "$W/g_full.net" '; after it: none found\.$' "hand-over, full: ... and none after it"
  has_l "$W/g_full.net" '^OTHER EPISODES IN THE ALERT-LOG HISTORY \(UTC, window offset\)$' "hand-over, full: the history is not called earlier"
  has_l "$W/g_full.net" '^History read: primary and standby alert logs .*capped: no' "hand-over, full: the lookback and whether the history was capped"
  python3 "$T/extract.py" "$W/g_full.dom" --facts > "$W/g_full.facts"
  has_l "$W/g_full.facts" '\| standby \| sbwait \| .*RFS \(TNS V1-V3\) .*inc=\[1\]' "full: the standby's ASH samples inside the wait that timed out are a fact of the incident"
  has_l "$W/g_full.facts" '\| (primary|standby) \| sar \| ' "full: the in-window network counters around the incident are facts"
  has_l "$W/g_full.facts" '\| (primary|standby) \| netsamp \| ' "full: the sampler lines around the incident are facts"
  has_l "$W/g_full.facts" '\| (primary|standby) \| peer \| .*return codes 12518 ×1' "full: the peer's connections at the listener around the incident are facts"
  has_l "$W/g_full.facts" '\| (primary|standby) \| ntp \| .*as collected 2026-11-20 13:45:00' "full: the NTP offsets are facts, labelled as collected"
  has_l "$W/g_full.txt" "^RULED: Standby host stopped for the whole wait · the standby's ASH sampler ran" "full: the standby's sampler ran through the wait (its coverage record and gap check): the standby was not stopped for the whole wait"
  no_l "$W/g_full.txt" '^NOTCHECKED: Standby host stopped' "full: ... so that entry is no longer not checked"
  has_l "$W/g_full.txt" "READING: Lines of the two hosts are ordered here by their timestamps.*clock synchronisation state when the bundles were collected \(not at the incident\): primary chronyc tracking: source ntp1.example.net, offset \+0.412 ms" "full: the cross-host reading uses the collected NTP state"
  no_l "$W/g_full.txt" 'NTP state is not part of this bundle' "full: ... and no longer says that it is not part of the bundle"
  has_l "$W/g_sbgap.txt" '^NOTCHECKED: Standby host stopped for the whole wait .*standby ASH sampler gap' "sbgap: a gap in the standby's sampler inside the wait: not ruled out, with the gap as the reason"
  no_l "$W/g_sbgap.txt" '^RULED: Standby host stopped' "sbgap: ... and not ruled out by anything else"
  has_l "$W/g_sbgap.txt" '^STAT: Host or clock indicators 1 .*ASH sampler gaps over 2 s, 10:00:00 to 10:45:00: primary 0, standby 1' "sbgap: the standby's gap counts as a host indicator, and the card names the interval"
  has_l "$W/g_sbgap.net" '^09:04:59Z 09:04:59 standby ASH sampler: sample_id 500200 to 500201' "sbgap: the gap is a host-side observation of the standby, in its own local time"
  has_l "$W/g_sbgap.txt" '^  READING: .*ASH sampler gap of' "sbgap: the reading names the gap and does not read the timeout as a lost reply"
  has_l "$W/g_late.parts" '^RFSNOTE: .*started 2026-11-20 12:00, after the window: counters hold nothing from it' "late: RFS counters since a startup after the window say that they hold nothing from the incident"
  has_l "$W/g_late.parts" '^HISTFOOT: .*started 2026-11-20 12:00, after the window: counters hold nothing from it' "late: so do the primary's counters"
  has_l "$W/g_late.parts" '^SBNOTE: .*does not cover the whole window: standby ASH holds nothing before 2026-11-20 12:00:30' "late: the standby's ASH that starts after the window says so"
  has_l "$W/g_late.txt" '^NOTCHECKED: Standby ASH samples of redo-related processes during the wait · standby ASH holds nothing before 2026-11-20 12:00:30' "late: the standby's ASH samples of the wait are not checked, with the reason"
  has_l "$W/g_full.parts" '^BASENOTE: 5 of 7 baseline days had usable data' "full: the baseline states how many days had usable data"
  has_l "$W/g_full.parts" '^  BASE: 2026-11-17 \(3 days earlier\) .*no AWR snapshot for that interval \(outside the retention\)' "full: a baseline day outside the AWR retention says so"
  has_l "$W/g_full.parts" '^  BASE: 2026-11-15 \(5 days earlier\) .*no usable delta \(the instance restarted' "full: a baseline day over an instance restart says so"
  has_l "$W/g_full.parts" '^HISTTABS: Window \(AWR\) \| Since startup \| Destination' "full: the response histogram of the destination is a tab beside the SYNC histogram"
  has_l "$W/g_full.parts" '^DGROWS: 3' "full: the dgstatus rows of both sides are in the alert log table"
  has_l "$W/g_full.parts" '^  DGROW: 10:05:31 \| Standby dgstatus \| Network Services · Error · error 12535 TNS-12535' "full: a dgstatus row is tagged and shows its facility, severity and error"
  has_l "$W/g_full.parts" '^ALTABS: All \| Matches \| Primary \| Standby \| dgstatus' "full: the alert log table can be filtered to the dgstatus rows"
  has_l "$W/g_full.parts" '^  SBTX: RFS \(TNS V1-V3\) \| RFS dispatch \| 3 \|' "full: the standby's process wait samples are a table, RFS apart from the other processes"
  has_l "$W/g_full.parts" '^  RFSEV: RFS write \| 412,880,311 ' "full: RFS events since startup"
  has_l "$W/g_full.parts" '^SARROWS: [0-9]+, of them overlapping an incident: [1-9]' "full: sysstat rows in the window, those that overlap an incident marked"
  has_l "$W/g_full.parts" '^NETWORK CARDS: During the window \| Network history \(sysstat\) \| When the bundle was collected, not during the window' "full: the network section keeps the window and the collection time apart"
  has_l "$W/g_full.parts" '^NETCHART: Sampler of the window \(net_sampler.sh\)$' "full: the sampler chart of the window is drawn with the charts, not among the tables of the network section"
  has_l "$W/g_full.parts" '^  CFG: Endpoint \(primary\) \| LAD:2 proddb_s_dgmgrl → stby-host.example:1526' "full: endpoints in the configuration"
  has_l "$W/g_full.parts" '^  CFG: sqlnet.ora timeouts \(primary\) \| SQLNET.EXPIRE_TIME 10' "full: the sqlnet.ora timeouts in the configuration"
  has_l "$W/g_full.parts" '^RECURCELLS: [1-9]' "full: the episodes by day and hour are drawn"
  has_l "$W/g_full.txt" '^NOTICES: Clocks differ between the hosts .*chronyc tracking' "full: the NTP state is in the clock notice (the offsets differ here)"
  has_l "$W/v2.txt" '^NOTICES: Clock synchronisation as collected ' "sample: the NTP state has a notice of its own when the offsets agree"
  # ---- review round: the history is read back from the collection time (it holds episodes after the window too)
  has_l "$W/g_hist.net" '^before the window: 2 found, newest first: 2026-11-07 10:04Z, 2026-11-02 10:04Z; after it: 3 found, oldest$' "history before the window: counted and listed newest first, apart from what came after"
  has_l "$W/g_hist.net" '^first: 2026-11-14 10:04Z, 2026-11-17 10:04Z, 2026-11-19 10:04Z\.$' "history after the window: counted and listed oldest first"
  has_l "$W/g_hist.net" '^OTHER EPISODES IN THE ALERT-LOG HISTORY \(UTC, window offset\)$' "history: the heading is neutral, not earlier"
  has_l "$W/g_hist.net" '^History read: primary 2026-10-21 to 2026-11-20, newest 300 lines kept, capped: no; standby ' "history: the lookback period is stated"
  has_l "$W/g_hist.txt" '^HISTNOTE: 5 episodes on 5 days \(2 before the window, 3 after\)' "history note: how many before the window and how many after it"
  python3 "$T/extract.py" "$W/g_hist.dom" --facts > "$W/g_hist.facts"
  has_l "$W/g_hist.facts" '\| recur \| .*5 episodes outside this window in the alert-log history: 2 before the window \(newest 2026-11-07 10:04:[0-9:]*\), 3 after it \(oldest 2026-11-14 10:04:' "history fact: counts before and after the window"
  has_l "$W/g_hist.parts" '^RECURNOTE: Episode starts by day \(rows, newest first\) and hour, primary local time; outlined row: window day\.$' "history view by day and hour: rows newest first, the window day outlined"
  for f in v1 v2 pre3 g_full g_hist g_two g_quiet; do no_l "$W/$f.net" 'EARLIER|[Ee]arlier episodes' "hand-over, $f: the network text does not call history episodes earlier"; no_l "$W/$f.ticket" '[Ee]arlier episodes' "hand-over, $f: nor does the ticket"; done
  no_l "$W/g_hist.txt" '^HISTNOTE:.*[Ee]arlier' "history note: does not call them earlier"
  # ---- one check, one interval, one answer: the ASH sampler-gap check ends shortly after the SYNC wait but ASH covers the wait (as in a live case)
  has_l "$W/g_waitcov.txt" '^STAT: Host or clock indicators – VKTM time drift: primary 0, standby 0 · ASH sampler gaps over 2 s, 10:00:00 to 10:45:00: primary – \(ASH holds nothing after 10:06:20\)' "waitcov: the card does not say None for a source that did not cover the window; it names the interval and the reason"
  has_l "$W/g_waitcov.txt" '^RULED: Primary host stopped for the whole wait · ASH sample_id and sample_time advanced together from before 10:05:00.000 to after 10:05:30.200: the sampler ran' "waitcov: the wait itself is covered: the Ruled-out entry names its interval"
  has_l "$W/g_waitcov.net" '^ASH sampler gaps over 2 s, primary: none from 2026-11-20 10:05:00Z to 10:05:30Z \(the SYNC wait\); not checked$' "waitcov: the network text gives the result for the same SYNC-wait interval (1/2)"
  has_l "$W/g_waitcov.net" '^ +for 2026-11-20 10:03:30Z to 10:11:20Z \(the incident interval\): no ASH rows after 10:06:20Z$' "waitcov: ... and, apart, what is not checked of the wider interval (2/2), never none"
  has_l "$W/g_waitcov.net" '^ASH sampler gaps over 2 s, standby: not checked from 2026-11-20 10:04:58Z to 10:05:32Z \(the SYNC wait \+-2 s\):$' "waitcov: the standby has its own statement, its interval widened by 2 s as in the Ruled-out entry"
  has_l "$W/g_waitcov.ticket" '^ASH sampler gaps over 2 s, primary: none from 2026-11-20 10:05:00Z to 10:05:30Z \(the SYNC wait\); standby: not$' "waitcov: the ticket gives the same result for the same interval"
  no_l "$W/g_waitcov.txt" '^NOTCHECKED: ASH sampler gap' "waitcov: no separate not-checked entry for the gap check: the wait is known and covered"
  no_l "$W/g_waitcov.net" 'ASH sampler gaps over 2 s: (none|not checked on)|none on the primary' "waitcov: no statement of the gap check without its interval, none that says 'not checked on every host'"
  no_l "$W/g_waitcov.ticket" 'not checked on every host' "waitcov: the ticket states each host's result"
  for f in v1 v2 pre3 g_quiet g_two g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_full g_sbgap g_late g_hist g_waitcov; do
    no_l "$W/$f.txt" '^STAT: Host or clock indicators None .*ASH sampler gaps over 2 s[^:]*: .*(–|no ASH gap check)' "card, $f: it never says None next to a source that did not cover the window"
    no_l "$W/$f.net" 'ASH sampler gaps over 2 s: ' "hand-over, $f: the gap check is stated per host, with its interval"
  done
  # the return code of the listener is printed as logged; it is glossed once, in the legend
  for f in v2 g_full g_two g_sbgap g_late; do no_l "$W/$f.net" '\((accepted|refused)\)' "hand-over, $f: listener return codes are printed as logged, not glossed per line"; done
  has_l "$W/g_full.net" '^TIMELINE \(listener return code 0 = the listener handed the connection off; other values are TNS error numbers\)$' "hand-over, full: the legend of the return codes appears once, in the timeline heading"
  # a "none sampled" is never alone when another source of the bundle reports the thing: the LGWR trace line that names the wait
  has_l "$W/g_noash.ticket" '^Longest SYNC write: ASH sampled no SYNC wait of 1 s or more in this incident \(10 s samples\); not checked,$' "noash ticket: no SYNC wait sampled, and that it was not checked (1/3)"
  has_l "$W/g_noash.ticket" '^holds nothing before 2026-11-20 10:20:10Z; the interval starts 2026-11-20 10:04:00Z; the LGWR trace line at$' "noash ticket: ... why (2/3)"
  has_l "$W/g_noash.ticket" '^10:05:30.200Z reports a wait of <30> seconds \(begin time <11/20/2026 10:05:00>\)\.$' "noash ticket: ... together with the LGWR trace line that reports a wait of 30 s (3/3)"
  has_l "$W/g_drift.ticket" "reports a wait of <30> seconds, but$" "drift ticket (1/2)"
  has_l "$W/g_drift.ticket" "^its begin time <11/20/2026 09:48:12> is 17 min 18 s earlier than the line's own time\\.$" "drift ticket: the trace line whose begin time disagrees with its own timestamp is stated with that disagreement"
  has_l "$W/g_drift.net" "primary LGWR trace line reports a SYNC wait of <30> seconds; its begin time$" "drift network text (1/2)"
  has_l "$W/g_drift.net" "^ +<11/20/2026 09:48:12> disagrees with the line's own time" "drift network text: the timeline has a row for the reported wait, so a missing ASH stall is not read as no wait"
  has_l "$W/v2.ticket" 'the LGWR trace line at 19:38:58.734Z reports a wait of$' "sample ticket: the longest SYNC write names the trace line that reports the wait (1/2)"
  has_l "$W/v2.ticket" '^<30> seconds \(begin time <11/13/2026 20:38:28>\)\.$' "sample ticket: ... and its begin time (2/2)"
  python3 "$T/extract.py" "$W/g_two.dom" --ui > "$W/g_two.ui"
  has_l "$W/g_two.ui" '^visible at start: net:1 ticket:1$' "ui: the first incident shows first"
  has_l "$W/g_two.ui" '^net: copy equals the shown text; download equals the shown text as dg-network-team-facts_proddb_2026-11-20_incident1.txt \(text/plain;charset=utf-8\)$' "ui: Copy and Download .txt give the text shown (network team)"
  has_l "$W/g_two.ui" '^ticket: copy equals the shown text; download equals the shown text as dg-ticket-facts_proddb_2026-11-20_incident1.txt ' "ui: Copy and Download .txt give the text shown (ticket)"
  has_l "$W/g_two.ui" '^fallback: copy:Databases: proddb' "ui: without the clipboard API, Copy selects a text area and uses the copy command"
  has_l "$W/g_two.ui" '^after choosing the last incident: net:2 ticket:2$' "ui: the incident tabs switch both blocks"
  has_l "$W/g_two.ui" '^destination tab: ([0-9]{1,2}|1[01][0-9]|120) characters: Responses of LAD:2 per bucket of whole seconds' "ui: the destination tab of the histogram"
  has_l "$W/g_two.ui" '^startup tab: ([0-9]{1,2}|1[01][0-9]|120) characters: Waits per bucket' "ui: the caption of the startup tab of the histogram is short too"
  # ---- two panes: the report (default) and the hand-over texts; the pane is chosen by the tabs, the sidebar, links and the address
  python3 "$T/extract.py" "$W/v2.dom" --ui > "$W/v2.ui"
  has_l "$W/g_two.ui" '^panes at start: report:shown handover:hidden; tab report; address none$' "panes: the report is shown first, the hand-over pane is hidden"
  has_l "$W/g_two.ui" '^after the Hand-over tab: report:hidden handover:shown; tab handover; address #handover; Copy and Download buttons shown$' "panes: the Hand-over tab shows the hand-over pane (and its buttons), hides the report, and sets the address"
  has_l "$W/g_two.ui" '^after the Report tab: report:shown handover:hidden; tab report; address #report$' "panes: the Report tab brings the report back"
  has_l "$W/g_two.ui" '^timeline chart width after the Report tab: ([4-9][0-9]{2}|[0-9]{4,})$' "panes: the charts are drawn again for the page that is shown (not at the 320 of a hidden page)"
  # ---- zoom: one range for the timeline, commit waits, active sessions by wait event, listener logins and the sampler
  Z='Zoomed to [0-9:]{8} – [0-9:]{8} \([^)]* of the 23 min 0 s window\)'
  has_l "$W/v2.ui" "^zoom after a drag across the timeline: tl $Z \| fg $Z \| aasViz $Z \| ls $Z \| ns $Z$" "zoom: a drag across the timeline zooms the five charts on the window's clock to the same range (commit waits and active sessions by wait event among them)"
  has_l "$W/v2.ui" '^active sessions chart zoomed: the area runs past the left edge and past the right edge of the plot$' "zoom: the area of the active-sessions chart runs on under the clip path to the neighbouring minutes, so that its shape is that of the whole-window view"
  has_l "$W/v2.ui" '^click that ends the drag: swallowed; timeline tab selected: none$' "zoom: the click that ends a drag reaches no mark, and no preset tab stays selected"
  has_l "$W/v2.ui" '^zoom after the Whole window button: tl whole \| fg whole \| aasViz whole \| ls whole \| ns whole$' "zoom: the Whole window button shows the whole window on every chart"
  has_l "$W/v2.ui" "^plain wheel: page scrolls, whole; Ctrl \+ wheel: taken, $Z$" "zoom: a plain wheel scrolls the page, Ctrl + wheel zooms"
  has_l "$W/v2.ui" '^zoom after the Incident 1 tab: tl Zoomed to 20:37:01 – 20:54:27 ' "zoom: the Incident tab of the timeline sets the shared range"
  has_l "$W/v2.ui" '^zoom at the end: tl whole \| fg whole \| aasViz whole \| ls whole \| ns whole$' "zoom: the Whole window tab puts every chart back"
  has_l "$W/v2.ui" '^sampler tooltip in the middle of the zoomed chart: inside the range$' "zoom: the sampler's tooltip reads its time from the zoomed range"
  has_l "$W/v2.ui" '^zoom after the Incident 1 tab: .*; tab selected: Incident 1$' "zoom: the Incident 1 tab shows selected after its click"
  has_l "$W/g_two.ui" '^zoom after the Incident 1 tab: .*; tab selected: Incident 1$' "zoom: two incidents, the Incident 1 tab shows selected after its click"
  has_l "$W/g_two.ui" '^zoom at the end: tl whole ' "zoom: two incidents, back to the whole window"
  has_l "$W/g_two.ui" '^link in Signals to the hand-over pane: report:hidden handover:shown; tab handover; address #handover$' "panes: a link of the report that targets the hand-over pane switches the pane"
  has_l "$W/g_two.ui" '^sidebar Report entry: report:shown handover:hidden; tab report; address #report$' "panes: the sidebar entry Report shows the report"
  has_l "$W/g_two.ui" '^sidebar Hand-over entry: report:hidden handover:shown; tab handover; address #handover; report sections in the sidebar not listed$' "panes: the sidebar entry Hand-over shows the hand-over pane, and the report sections leave the sidebar"
  has_l "$W/g_two.ui" '^report sections in the sidebar after the Report entry: listed$' "panes: the report sections are in the sidebar again with the report"
  has_l "$W/g_two.ui" '^sidebar entry of a report section: report:shown handover:hidden; tab report; address #signals$' "panes: a sidebar entry of a report section keeps the report shown and sets the address"
  has_l "$W/g_two.ui" '^before Back, on the hand-over pane: report:hidden handover:shown; tab handover; address #handover$' "panes (history): on the hand-over pane"
  has_l "$W/g_two.ui" '^Back: report:shown handover:hidden; tab report; address #signals$' "panes (history): Back returns to the report"
  has_l "$W/g_two.ui" '^Forward: report:hidden handover:shown; tab handover; address #handover$' "panes (history): Forward returns to the hand-over pane"
  has_l "$W/g_two.ui" '^address #signals typed: report:shown handover:hidden; tab report; address #signals$' "panes: an address that names a report section shows the report"
  python3 "$T/extract.py" "$W/g_noash.dom" --ui > "$W/g_noash.ui"
  has_l "$W/g_noash.ui" '^data-go link to #handover: report:hidden handover:shown; tab handover; address #handover$' "panes: the hint that names the hand-over text links to the hand-over pane (a data-go link of the report)"
  # a page opened on #handover shows the hand-over pane first and is otherwise the same report
  GATE_HASH='#handover' sh "$T/gate.sh" "$W/g_two_ho" "$W/gen/two_primary.jsonl" "$W/gen/two_standby.jsonl"
  nojs g_two_ho "address #handover"
  python3 "$T/extract.py" "$W/g_two_ho.dom" --ui > "$W/g_two_ho.ui"
  has_l "$W/g_two_ho.ui" '^panes at start: report:hidden handover:shown; tab handover; address #handover$' "panes: an address #handover opens the hand-over pane"
  has_l "$W/g_two_ho.ui" '^timeline chart width after the Report tab: ([4-9][0-9]{2}|[0-9]{4,})$' "panes: a report opened from a page that started on #handover is drawn at the width of the page"
  same "panes: a page opened on #handover holds the same claims as the page opened on the report" "$W/g_two_ho.txt" "$W/g_two.txt"
  # the section order: every chart before Signals; the hand-over texts in the other pane, after the report
  want='report summary timeline sequence commits who lgwr aas baseline recur listener rfsCard nsCard signals explain next coverage episodes history alerts traces shipping cidCard config standby rfsEvCard network paneHandover handover'
  python3 "$T/extract.py" "$W/v2.dom" --order > "$W/v2.order"
  if [ "$(cat "$W/v2.order")" = "$want" ]; then pass "order, example: summary, the chart sections, then the findings, the logs, the configuration and hosts; the hand-over pane last"; else fail "order, example" "$(cat "$W/v2.order")"; fi
  python3 "$T/extract.py" "$W/g_quiet.dom" --order > "$W/g_quiet.order"
  if awk '{ s = 0; for (i = 1; i <= NF; i++) { if ($i == "signals") s = 1; if (s && ($i == "timeline" || $i == "sequence" || $i == "commits" || $i == "who" || $i == "lgwr" || $i == "aas" || $i == "baseline" || $i == "recur" || $i == "listener" || $i == "rfsCard" || $i == "nsCard")) exit 1 } exit 0 }' "$W/g_quiet.order"; then pass "order, quiet scenario: no chart section after Signals"; else fail "order, quiet scenario: a chart after Signals" "$(cat "$W/g_quiet.order")"; fi
  has_l "$W/g_quiet.order" '^report summary timeline sequence commits who lgwr aas baseline recur listener rfsCard ' "order, quiet scenario: the chart sections keep their order"
  # captions: one line, at most 120 characters, in every rendered scenario (the tab-dependent ones are checked in the ui log above)
  for f in v1 v2 pre3 g_quiet g_two g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_full g_sbgap g_late g_hist g_waitcov; do
    python3 "$T/extract.py" "$W/$f.dom" --captions > "$W/$f.captions"
    mx=$(cut -d' ' -f1 "$W/$f.captions" | sort -n | tail -1); n=$(wc -l < "$W/$f.captions" | tr -d ' ')
    if [ "$n" -ge 20 ] && [ "$mx" -le 120 ]; then pass "captions, $f: $n cards, the longest caption has $mx characters (at most 120)"; else fail "captions, $f: $n cards, the longest caption has $mx characters" "$(awk -F' [|] ' '$1 + 0 > 120' "$W/$f.captions" | head -3 | cut -c1-200)"; fi
  done
  # Reading: a closed disclosure on the page, opened for the printout, closed again after it
  python3 "$T/extract.py" "$W/g_two.dom" --readings > "$W/g_two.readings"; python3 "$T/extract.py" "$W/v2.dom" --readings > "$W/v2.readings"
  no_l "$W/g_two.readings" '^open' "Reading, two incidents: no Reading disclosure is open"
  [ "$(grep -c '^closed | Reading ([0-9]*)$' "$W/g_two.readings")" = "$(grep -c '^SIGNAL' "$W/g_two.txt")" ] && pass "Reading, two incidents: every signal block has its Reading in a closed disclosure" || fail "Reading, two incidents: signal blocks and Reading disclosures differ" "$(cat "$W/g_two.readings")"
  has_l "$W/v2.readings" '^DIVRD: 0$' "Reading, example: no Reading outside a disclosure"
  [ "$(grep -c '^closed | Reading (' "$W/v2.readings")" = 4 ] && pass "Reading, example: the two signal blocks, the episodes counts and the recurrence line each have a closed disclosure" || fail "Reading, example: Reading disclosures" "$(cat "$W/v2.readings")"
  no_l "$W/v2.readings" '^open' "Reading, example: no Reading disclosure is open"
  has_l "$W/g_two.ui" '^Reading blocks: 2, open at start 0, open for printing 2, open after printing 0$' "Reading, two incidents: the print events open them and close them again"
  has_l "$W/v2.ui" '^Reading blocks: 4, open at start 0, open for printing 4, open after printing 0$' "Reading, example: the print events open them and close them again"
  # Copy and Download .txt from the hand-over pane deliver the golden hand-over texts (each incident), also on a page opened on #handover
  for f in v2:sample g_two:two g_two_ho:two; do
    r=${f%%:*}; gname=${f##*:}
    for how in copy dl; do for blk in net ticket; do
      python3 "$T/extract.py" "$W/$r.dom" --delivered $how $blk > "$W/$r.$how.$blk"
      same "hand-over pane, $r: $how delivers the golden $blk text of every incident" "$W/$r.$how.$blk" "$T/expected/handover_$gname.$blk.txt"
    done; done
  done
  for e in e_p e_s e_0; do python3 "$T/extract.py" "$W/$e.dom" --net > "$W/$e.net"; python3 "$T/extract.py" "$W/$e.dom" --ticket > "$W/$e.ticket"
    if [ -s "$W/$e.net" ] && [ -s "$W/$e.ticket" ] && out=$(python3 "$T/wording.py" "$W/$e.net" "$W/$e.ticket"); then pass "hand-over, $e: both texts exist and state no interpretation"; else fail "hand-over, $e" "$out"; fi; done

  # ---- sources that no longer reach the window: a notice, and the column "Reached the window" of the coverage table (from the cov records and the bundle headers only)
  for e in e_p e_s; do python3 "$T/extract.py" "$W/$e.dom" --parts > "$W/$e.parts"; done
  has_l "$W/g_late.txt" '^NOTICES: .*Some sources do not reach the whole window Primary, collected 3 h 30 min after the window: every source reached the window Standby, collected 3 h 30 min after the window: ASH \(V\) holds none of the window \(11-20 12:00 to 11-20 13:59\)' "reach, late: a notice says how long after the window each bundle was collected and which source holds nothing of it, with what it holds"
  has_l "$W/g_noash.txt" '^NOTICES: Some sources do not reach the whole window Primary, collected 4 h 0 min after the window: ASH \(H\) holds part of it \(11-20 10:20 to 11-20 10:40\)' "reach, noash: a source that holds only part of the window says so, with what it holds"
  has_l "$W/g_tzoff.txt" 'Standby, collected 4 h 0 min after the window: ASH \(V\) holds none of the window \(11-20 14:45 to 11-20 15:44\)' "reach, different UTC offsets: the standby's times are the converted ones"
  has_l "$W/v2.txt" '^NOTICES: .*Some sources do not reach the whole window Primary, collected 12 h 15 min after' "reach, sample: the example bundles collected after the window"
  for f in g_full g_sbgap v1; do no_l "$W/$f.txt" 'do not reach the whole window' "reach, $f: no notice when every source reached the window, and none for a bundle without coverage records"; done
  has_l "$W/g_late.parts" '^REACH: standby/ash/V \| not at all$' "reach, late: a source that holds nothing of the window is 'not at all'"
  has_l "$W/g_noash.parts" '^REACH: primary/ash/H \| part of it$' "reach, noash: a source that starts inside the window is 'part of it'"
  has_l "$W/g_full.parts" '^REACH: primary/ash/V \| whole window$' "reach, full: a source that holds the window is 'whole window'"
  has_l "$W/g_full.parts" '^REACH: primary/ntp \| as collected$' "reach, full: the sources read at collection time are 'as collected'"
  has_l "$W/g_full.parts" '^REACH: standby/sar/ETCP \| not applicable$' "reach, full: a source that was not read (a failed sysstat report) is 'not applicable'"
  has_l "$W/g_full.parts" '^REACH: standby/lsnr_ref \| whole window$' "reach, full: a text log read after the window that ends earlier still reaches it"
  has_l "$W/v1.parts" '^REACH: no coverage rows$' "reach, v1: no coverage records, no reach column"
  # ---- what would settle a Not-checked entry: a separate line under the entry, built from the coverage result, with the exact command
  has_l "$W/g_late.txt" '^HINT: Would settle: Standby ASH holds nothing before 2026-11-20 12:00:30; collected 3 h 30 min after the window: sh/collect.sh standby "2026-11-20 10:00" "2026-11-20 10:30"$' "hints, late: the standby ASH that no longer reaches the window: collect sooner, with the command and the window of the bundle"
  has_l "$W/g_tzoff.txt" '^HINT: .*: sh/collect.sh standby "2026-11-20 10:00" "2026-11-20 10:45"$' "hints, different UTC offsets: the command for the standby gives its window in the standby's own clock (the report shows it converted)"
  has_l "$W/g_noash.txt" '^HINT: Would settle: Primary ASH was read from the AWR copy \(10 s samples, one in ten\): sh/collect.sh primary "2026-11-20 10:00" "2026-11-20 10:30"$' "hints, noash: ASH read from the AWR copy: collect sooner"
  has_l "$W/g_noash.txt" '^HINT: Would settle: Idle timeouts of a firewall or load balancer between the hosts are recorded on neither host\. Addresses and port to ask about: Hand-over, For the network team$' "hints, noash: what lies outside the tool is stated as a fact and has no command"
  has_l "$W/g_drift.txt" '^HINT: Adds Observed rows: The primary sampler log does not hold this interval; start the sampler before the next occurrence \(one line every 5 s\), then add its log: nohup sh sh/net_sampler\.sh <peer IP> <listener port> 5 /var/tmp/net_sampler\.log >/dev/null 2>&1 & sh/collect\.sh -n /var/tmp/net_sampler\.log primary "<from>" "<to>"$' "hints, drift: the sampler for the next occurrence (no endpoint in the bundle: the address is a placeholder)"
  has_l "$W/g_lost.parts" '^  CMD: nohup sh sh/net_sampler\.sh <peer IP> <listener port> 5 /var/tmp/net_sampler\.log >/dev/null 2>&1 &$' "hints, lost: the sampler command in the card for the next occurrence"
  has_l "$W/v1.txt" '^HINT: Would settle: The primary bundle is format v1, without coverage records: sh/collect\.sh primary "2026-11-13 20:35" "2026-11-13 20:58"$' "hints, v1: collect a v1 bundle again with the current collector"
  has_l "$W/e_p.txt" '^HINT: Would settle: No standby bundle; the window is in the primary host.s local time: sh/collect\.sh standby "2026-11-20 10:00" "2026-11-20 10:45"$' "hints, primary bundle only: collect the standby bundle (and the window is the primary's clock)"
  has_l "$W/e_s.txt" '^HINT: Would settle: No primary bundle' "hints, standby bundle only: collect the primary bundle"
  no_l "$W/g_full.txt" '^HINT' "hints, full: no hint where the evidence is complete (a ruling-out or a none-found has none)"
  for f in v1 v2 pre3 g_quiet g_two g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_full g_sbgap g_late g_hist g_waitcov; do
    awk '/^NOTCHECKED:/ { nc = 1; next } /^HINT:/ { if (!nc) print "a hint without a Not-checked entry before it: " substr($0, 1, 80) } /^(RULED|NONEFOUND|RULED\/NC)/ { nc = 0 }' "$W/$f.txt" > "$W/$f.hintpos"
    if [ -s "$W/$f.hintpos" ]; then fail "hints, $f: a hint stands under something that is not a Not-checked entry" "$(head -2 "$W/$f.hintpos")"; else pass "hints, $f: every hint stands under a Not-checked entry"; fi
    no_l "$W/$f.net" 'sh/collect\.sh|net_sampler|What would settle' "hints, $f: the network text carries no hint"; no_l "$W/$f.ticket" 'sh/collect\.sh|net_sampler|What would settle' "hints, $f: the ticket text carries no hint"
  done
  for f in g_noash g_drift g_lost v1 g_rtpmode; do
    grep '^NEXT:' "$W/$f.parts" | sort > "$W/$f.nx"; if [ -s "$W/$f.nx" ] && [ "$(uniq -d "$W/$f.nx" | wc -l | tr -d ' ')" = 0 ]; then pass "next occurrence, $f: each hint is in the card once"; else fail "next occurrence, $f: a hint twice, or none" "$(uniq -d "$W/$f.nx" | cut -c1-120)"; fi
  done
  has_l "$W/g_late.parts" '^  FOR: Would settle: Standby ASH samples of redo-related processes during the wait$' "next occurrence, late: a hint lists the entries it would settle"
  has_l "$W/g_noash.parts" '^  FOR: Would settle: SYNC write stall before the first event ; Local redo write stall before the first event ; Primary host stopped for the whole wait$' "next occurrence, noash: one hint for the entries of the one cause"
  has_l "$W/g_drift.parts" '^  FOR: Adds Observed rows for: ' "next occurrence, drift: the sampler hint says it adds Observed rows"
  has_l "$W/g_full.parts" '^NEXT: No Not-checked entry has a hint\.$' "next occurrence, full: with no hint the card says so in one line"
  has_l "$W/g_quiet.parts" '^NEXT: No Not-checked entry has a hint' "next occurrence, quiet window: one line"
  # ---- explanations against the evidence: one table per incident, seven rows in a fixed order, the report's own column words, filled through the static map
  for f in v1 v2 pre3 g_quiet g_two g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_full g_sbgap g_late g_hist g_waitcov; do
    if [ "$f" = g_quiet ] || [ "$f" = g_rac ]; then has_l "$W/$f.parts" '^EXPL: No incident in this window' "explanations, $f: no incident, one line"; continue; fi
    n=$(grep -c '^EXPL: Incident' "$W/$f.parts"); r=$(grep -c '^  EXPLROW:' "$W/$f.parts")
    if [ "$n" -ge 1 ] && [ "$r" = $((n * 7)) ]; then pass "explanations, $f: $n table(s) of 7 rows"; else fail "explanations, $f: $n tables, $r rows"; fi
    grep '^  EXPLROW:' "$W/$f.parts" | head -7 | sed 's/ | Observed:.*//' | tr '\n' '#' > "$W/$f.rows"
    if [ "$(cat "$W/$f.rows")" = '  EXPLROW: Redo or its acknowledgement lost on the network path#  EXPLROW: Idle timeout on a connection (a device between the hosts dropped an idle session)#  EXPLROW: Standby slow to write or to answer (RFS, standby redo log I/O)#  EXPLROW: Standby host stopped (pause, VM stun, starvation)#  EXPLROW: Standby instance or process shut down or restarted#  EXPLROW: Primary host stopped or its clock jumped#  EXPLROW: Local redo write on the primary slow#' ]; then pass "explanations, $f: the seven rows in the fixed order with their labels"; else fail "explanations, $f: rows or labels" "$(cat "$W/$f.rows" | tr '#' '\n')"; fi
    no_l "$W/$f.parts" '^(  )?EXPL.*([Ss]upports|[Cc]ontradicts|[Ll]ikely|[Ss]core|[Pp]robab)' "explanations, $f: no \"supports\", \"contradicts\", \"likely\" or score"
    no_l "$W/$f.parts" '^  EXPLUNPLACED: .*(lgwrwait|state2|lsnrx|lfsmax|sbwait|netsamp|clockjump|lastok)' "explanations, $f: the rows placed in no row are named, not given by their internal kind"
  done
  has_l "$W/g_full.parts" '^  EXPLEVERY: Observed in every case: .*ORA-16198 \(primary\) 10:05:30\.200.*LAD:2 UNSYNCHRONIZED 10:05:30\.400' "explanations, full: the timeout error and the destination leaving the synchronized state are listed once above the table"
  has_l "$W/g_full.parts" '^  EXPLROW: Primary host stopped or its clock jumped \| Observed:  \| Ruled out: Primary host stopped for the whole wait \| None found: VKTM time-drift warning on either host \| Not checked: $' "explanations, full: a ruled-out and a none-found entry sit in their own columns of their row"
  has_l "$W/g_full.parts" '^  EXPLROW: Local redo write on the primary slow \| Observed:  \| Ruled out:  \| None found:  \| Not checked: Local redo write stall before the first event$' "explanations, full: a not-checked entry sits in its own column"
  has_l "$W/g_full.parts" '^  EXPLROW: Standby slow to write or to answer .*Observed: .*Standby ASH samples inside the wait 10:05:04' "explanations, full: the standby's ASH samples inside the wait are Observed under the slow-standby row"
  has_l "$W/g_full.parts" '^  EXPLROW: Standby host stopped .*Ruled out: Standby host stopped for the whole wait' "explanations, full: the standby-host-stopped ruling-out sits under its row"
  has_l "$W/g_full.parts" '^  EXPLROW: Redo or its acknowledgement lost on the network path \| Observed: sysstat ETCP \(primary\)' "explanations, full: the sysstat rows of the window are Observed under the network row"
  has_l "$W/g_full.parts" '^  EXPLROW: Standby instance or process shut down or restarted \| Observed: .*Connections of the peer at the standby listener 10:05:40' "explanations, full: the peer's connections at the standby listener are Observed under the standby-restart row"
  has_l "$W/g_full.parts" '^  EXPLUNPLACED: Not placed here, in Signals: .*Endpoints and destination as collected' "explanations, full: what is placed in no row is named"
  has_l "$W/g_drift.parts" '^  EXPLROW: Standby host stopped .*Observed: .*VKTM time-drift line \(standby\)' "explanations, drift: the standby's VKTM line is Observed under the standby-stopped row"
  has_l "$W/g_drift.parts" '^  EXPLROW: Primary host stopped or its clock jumped \| Observed: .*ASH sampler gap \(primary\).*VKTM time-drift line \(primary\).*LGWR trace line against its own clock' "explanations, drift: the primary's VKTM line, sampler gap and clock mismatch are Observed under the primary-stopped row"
  has_l "$W/g_lost.parts" '^  EXPLROW: Idle timeout on a connection .*Observed: ORA-03135 \(primary\)' "explanations, lost: an ORA-03135 is Observed under the connection rows, not in every case"
  no_l "$W/g_lost.parts" '^  EXPLEVERY: .*ORA-03135' "explanations, lost: ... and not listed as common to every row"
  no_l "$W/v1.parts" '^  EXPLROW: .*Ruled out: [A-Za-z]' "explanations, v1: coverage unknown, so the Ruled out column is empty"
  has_l "$W/v1.parts" '^  EXPLROW: Standby host stopped .*Not checked: .*Standby host stopped for the whole wait' "explanations, v1: what Signals ruled out elsewhere is Not checked here, as in Signals"
  has_l "$W/g_waitcov.parts" '^  EXPLROW: Standby slow to write or to answer .*Not checked: .*Standby ASH samples of redo-related processes during the wait' "explanations, waitcov: a source that does not cover the wait is Not checked under the row it bears on"
  # every title the table shows has its row in Signals to link to
  python3 - "$W/g_full.dom" > "$W/g_full.links" <<'PY'
import re, sys
d = open(sys.argv[1], encoding='utf-8').read()
d = re.sub(r'<script.*?</script>', '', d, flags=re.S)
ids = set(re.findall(r'\bid="([^"]+)"', d))
bad = [g for g in re.findall(r'data-go="#([^"]+)"', re.search(r'id="explBody".*?id="coverage"', d, flags=re.S).group(0)) if g not in ids and g not in ('lgwr', 'commits', 'traces', 'listener', 'standby', 'network')]
if bad: print('\n'.join(bad))
PY
  if [ -s "$W/g_full.links" ]; then fail "explanations, full: a title links to a row that does not exist" "$(head -3 "$W/g_full.links")"; else pass "explanations, full: every title links to an existing row of Signals"; fi
  # ---- the sequence of the incident
  has_l "$W/g_full.parts" '^  SEQPANEL: Stall \| 10:04:31\.700 to 10:05:44\.300 \(1 min 13 s\)$' "sequence, full: the stall panel has labelled start and end times"
  has_l "$W/g_full.parts" '^  SEQPANEL: Recovery \| 10:10:03\.500 to 10:10:22\.000 \(18\.5 s\)$' "sequence, full: a recovery panel with its own axis, around the reconnect and the return to SYNCHRONIZED"
  has_l "$W/g_full.parts" '^  SEQARIA: Sequence of incident 1: 12 events on a primary lane above a standby lane$' "sequence, full: the chart has an aria-label"
  has_l "$W/g_full.parts" '^  SEQMARKS: 12 shapes with a tooltip, 5 margin bands, 2 margin scale marks$' "sequence, full: every mark has a tooltip, the standby marks have the cross-host margin band, each panel its scale mark"
  has_l "$W/g_full.parts" '^  SEQMARK 1 \| 10:04:35 – 10:04:36 \| Primary \| Last completed SYNC write: time_waited 3 ms' "sequence, full: the last completed SYNC write is the first mark, drawn as its 1 s sampling interval"
  has_l "$W/g_full.parts" '^  SEQMARK 2 \| 10:05:00 – 10:05:30 \| Primary \| SYNC wait that timed out: from 10:05:00 to 10:05:30\.200 \| begin time in the LGWR trace' "sequence, full: the SYNC wait is a span on the primary lane"
  has_l "$W/g_full.parts" '^  SEQMARK 4 \| 10:05:30\.200 \| Primary \| ORA-16198 \(primary\).*millisecond timestamp$' "sequence, full: a millisecond timestamp is a point"
  has_l "$W/g_full.parts" '^  SEQMARK 6 \| 10:05:31\.100 \| Standby \| Fatal NI connect error 12170 \(standby\)' "sequence, full: a network-layer error block of the standby is on the standby lane"
  has_l "$W/g_full.parts" '^  SEQMARK 8 \| 10:05:40 – 10:05:41 \| Standby \| Connection of the peer at the standby listener, return code 12518: from 198\.51\.100\.11:51234, service SID:proddb_s \| .*1 s timestamp$' "sequence, full: a listener connection of the peer is a 1 s mark on the lane of the host that logged it"
  has_l "$W/g_full.parts" '^  SEQMARK 12 \| 10:10:20\.500 \| Primary \| LAD:2 SYNCHRONIZED' "sequence, full: the return to SYNCHRONIZED"
  has_l "$W/g_full.parts" '^  SEQMARK 3 \| 10:05:04 – 10:05:23 \| Standby \| Standby ASH samples inside the wait.* \| .*ASH 1 s samples$' "sequence, full: the standby ASH samples inside the wait are drawn with their sampling interval"
  has_l "$W/g_two.parts" '^  SEQPANEL: Stall \|' "sequence, two incidents: the first incident"
  [ "$(grep -c '^SEQ: Incident' "$W/g_two.parts")" = 2 ] && pass "sequence, two incidents: one view per incident" || fail "sequence, two incidents: one view per incident"
  if [ "$(grep -c '^  SEQPANEL: Stall and recovery' "$W/g_rtpmode.parts")" = 2 ] && [ "$(grep -c '^  SEQPANEL' "$W/g_rtpmode.parts")" = 2 ]; then pass "sequence, rtpmode: an incident that fits in about 90 s is one panel"; else fail "sequence, rtpmode: one panel per incident expected" "$(grep '^  SEQPANEL' "$W/g_rtpmode.parts")"; fi
  if [ "$(grep -c '^  SEQPANEL' "$W/g_full.parts")" = 2 ] && [ "$(grep -c '^  SEQPANEL: Stall |' "$W/g_full.parts")" = 1 ] && [ "$(grep -c '^  SEQPANEL: Recovery |' "$W/g_full.parts")" = 1 ]; then pass "sequence, full: an incident longer than about 90 s is a stall panel and a recovery panel"; else fail "sequence, full: panels" "$(grep '^  SEQPANEL' "$W/g_full.parts")"; fi
  has_l "$W/g_sbgap.parts" '^  SEQMARK [0-9]+ \| 10:04:59 – 10:05:30 \| Standby \| ASH sampler gap \(standby\)' "sequence, sbgap: the standby's sampler gap is on the standby lane"
  has_l "$W/g_drift.parts" '^  SEQMARK [0-9]+ \| [0-9:.]+ \| (Primary|Standby) \| VKTM time-drift line \(' "sequence, drift: the VKTM lines are marks"
  has_l "$W/g_drift.parts" '^  SEQMARK [0-9]+ \| [0-9:.]+ \| Primary \| LGWR trace line against its own clock' "sequence, drift: the LGWR trace line that disagrees with the clock is a mark"
  has_l "$W/e_p.parts" '^  SEQLANE: no standby bundle$' "sequence, primary bundle only: the standby lane says so"
  has_l "$W/e_s.parts" '^  SEQLANE: no primary bundle$' "sequence, standby bundle only: the primary lane says so"
  no_l "$W/e_p.parts" '^  SEQMARKS: .* [1-9][0-9]* margin bands' "sequence, primary bundle only: no margin band (there is no second lane to compare with)"
  has_l "$W/g_noash.parts" '^  SEQMARKS: [0-9]+ shapes' "sequence, noash: drawn without the primary ASH facts"
  has_l "$W/v1.parts" '^  SEQMARKS: [0-9]+ shapes' "sequence, v1: a v1 bundle draws the same view from its facts"
  has_l "$W/pre3.parts" '^  SEQPANEL: ' "sequence, pre-phase-3 bundles: drawn"
  for f in v1 v2 pre3 g_two g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_full g_sbgap g_late g_hist g_waitcov e_p e_s; do no_l "$W/$f.parts" 'NaN|undefined|Invalid Date' "sequence and tables, $f: no NaN, undefined or Invalid Date"; done
  [ "$(grep -c '^SEQ: Incident' "$W/g_lost.parts")" -ge 1 ] && pass "sequence, lost (ORA-03135 and no ORA-16198): drawn" || fail "sequence, lost"
  has_l "$W/g_quiet.parts" '^SEQ: No incident in this window' "sequence, quiet window: one line, no chart"
  has_l "$W/g_full.parts" '^SEQNOTE: Shaded band: ±2 s clock margin between the hosts; order inside it is not established\.' "sequence: the caption says that ordering within the margin is not established"
  # the tabs, the click on a mark and on a title (tests/hover.html)
  has_l "$W/g_two.ui" '^sequence at start: 1$' "ui: the first incident's sequence shows first"
  has_l "$W/g_two.ui" '^sequence after choosing the last incident: 2$' "ui: the sequence tabs switch the incident"
  has_l "$W/g_two.ui" '^sequence mark click: #inc[12]-o[0-9]+ -> li flashed$' "ui: a click on a mark of the sequence jumps to its Observed row"
  has_l "$W/g_two.ui" '^explanation title click: #en-[0-9]+-[a-z-]+ -> div flashed$' "ui: a click on a title of the explanation table jumps to its entry in Signals"
  # ---- the cards of the lookback and impact records (extract.py --cards): episodes side by side, who waited, the activity bars of the day-and-hour grid, the grouped entries of the explanation table
  for sc in full hist two quiet stfail capped; do cards g_$sc $sc; done
  for sc in noash drift lost tzoff rtpmode rac late waitcov sbgap; do python3 "$T/extract.py" "$W/g_$sc.dom" --cards > "$W/g_$sc.cards"; done
  for n in v2 v1 pre3 g_full g_hist g_two g_quiet g_sbgap g_stfail g_capped; do no_l "$W/$n.cards" 'NaN|undefined|Invalid Date' "cards, $n: no NaN, undefined or Invalid Date"; done
  # the example: the incident first, then the episodes of the history, newest first
  [ "$(grep -o '^  EPROW [a-z0-9]*' "$W/v2.cards" | tr '\n' ' ')" = '  EPROW inc1   EPROW h3   EPROW h2   EPROW h1   EPROW h0 ' ] && pass "episodes, example: the incident of the window first, then the four episodes of the history, newest first" || fail "episodes, example: row order" "$(grep -o '^  EPROW [a-z0-9]*' "$W/v2.cards" | tr '\n' ' ')"
  has_l "$W/v2.cards" '^  EPROW inc1 \| 2026-11-13 Fri / 20:38:01 / this window, incident 1 \|' "episodes, example: the incident is marked as this window's, with date, weekday and time of day"
  has_l "$W/v2.cards" '^  EPROW inc1 .*\| 20:53:27 / 15 min 26 s after the first line \| average 1.31 MB/s, largest 1 minute 2.4 MB/s / 20:00 to 21:00 \|' "episodes, example: the return time, and the redo rate of the AWR interval with the interval's own begin and end"
  has_l "$W/v2.cards" '^  EPROW h3 .*\| 20:52:27 / 14 min 20 s after the first line \| average 1.62 MB/s, largest 1 minute 2.7 MB/s / 20:00 to 21:00 \| RMAN \(primary\): BACKUP DB INCR, 20:31:05 to 21:12:25, COMPLETED / RMAN \(standby\): none / job: APP_OWNER.EXPORT_REPORTS, 20:37:10 to 20:40:05, SUCCEEDED / log switch: thread 1 sequence 114379, \+23 s$' "episodes, example: an RMAN command and a job run with their own times, a log switch with its signed offset, \"none\" where the source holds the interval"
  has_l "$W/v2.cards" '^  EPROW h2 .*\| 20:59:43 / 15 min 12 s after the first line \| not covered \| RMAN \(primary\): BACKUP DB INCR, 20:29:50 to 21:11:10, COMPLETED WITH WARNINGS /' "episodes, example: a command that started 14 min before the start but was still running at it is listed (the count below says within 10 minutes)"
  has_l "$W/v2.cards" '^  EPROW h0 .*\| not covered \| RMAN .*log switch: not covered$' "episodes, example: an episode that the AWR and the log-switch history do not reach says not covered, not none"
  has_l "$W/v2.cards" '^  EPCOUNT: An RMAN command named BACKUP DB INCR started within 10 minutes before 4 of the 5 episodes that v\$rman_status covers on the primary\.$' "episodes, example: the count of RMAN starts within 10 minutes before the episodes the view covers"
  has_l "$W/v2.cards" '^  EPCOUNT: A run of job named APP_OWNER.EXPORT_REPORTS started within 10 minutes before 2 of the 5 episodes that cdb_scheduler_job_run_details covers\.$' "episodes, example: the count of job runs"
  has_l "$W/v2.cards" '^  EPCOUNT: A log switch within 60 s of the start: 2 of 4 episodes that v\$log_history covers\.$' "episodes, example: the count of log switches within 60 s, out of the episodes the view covers"
  has_l "$W/v2.cards" '^  EPCOUNT: Job APP_OWNER.REFRESH_MV_STOCK ran 2880 times in the lookback \(more than 24 a day on average; .*\): not listed per episode\.$' "episodes, example: a frequent job is named once under the table, not listed per episode"
  has_l "$W/v2.cards" '^  EPCOUNT: A line that ends the UNSYNCHRONIZED period follows 4 of the 4 episodes of the history that alsync covers\.$' "episodes, example: the count of return lines"
  has_l "$W/v2.cards" '^  EPCOUNT: Reading: if an activity starts at the same time as most of the episodes, it is a candidate to look at; coincidence in time does not show that it produced them, and work scheduled outside the database \(cron, backups of the host, the network\) is not in these views\.$' "episodes, example: one conditional Reading, which names what a coincidence cannot show"
  [ "$(grep -c 'EPCOUNT: Reading' "$W/v2.cards")" = 1 ] && pass "episodes, example: exactly one Reading sentence" || fail "episodes, example: the number of Reading sentences"
  no_l "$W/v2.cards" '^  EPROW .*(\| 0 \||no return line.*caused|because)' "episodes, example: no zero for a missing value, no cause stated"
  # who waited
  has_l "$W/v2.cards" '^WHOTABS: Incident 1$' "who waited, example: one incident, one tab"
  has_l "$W/v2.cards" '^  WHOLIST service: ordersvc.example 60 samples · 60 behind LGWR · 42 sessions ; reportsvc.example 22 samples · 22 behind LGWR · 14 sessions ; hash 3427055676 21 samples' "who waited, example: services ranked by samples, with the samples behind LGWR and the distinct sessions; a hash with no name stays a hash"
  has_l "$W/v2.cards" '^  WHOLIST module: .*no value 25 samples' "who waited, example: a null module is \"no value\""
  has_l "$W/v2.cards" '^  WHOLIST machine: app01.example 35 samples' "who waited, example: machines"
  has_l "$W/v2.cards" '^  WHOCAP: AWR ASH \(dba_hist_active_sess_history, 10 s samples\): samples, not durations or commits\. Lists for the whole window\. 10 groups found, none cut\.$' "who waited, example: the caption names the ASH source and its interval, says the counts are samples, and that the lists are for the whole window"
  has_l "$W/v2.cards" '^  WHOPEAK: Peak in one sample: 18 at 20:38:50.118; behind LGWR 18 at 20:38:50.118 \(lfs_sum, whole window\)\.$' "who waited, example: the most sessions in one sample, from lfs_sum"
  has_l "$W/v2.cards" '^  WHOWL txn \| User transactions per second \| 44.1 average of 3 minutes, 20:35 to 20:37 \| 0.2 lowest of 16 minutes \(20:38 to 20:53\), at 20:40$' "who waited, example: transactions before the first event (average, minutes named) against the lowest minute of the incident (minute named)"
  has_l "$W/v2.cards" '^  WHOWL redo \| Redo, MB per second \| 2.1 average of 3 minutes' "who waited, example: redo"
  has_l "$W/v2.cards" '^  WHOWL logons \| Logons per second \| 0.9 average of 3 minutes' "who waited, example: logons"
  # the grid
  has_l "$W/v2.cards" '^RECURBARS: [0-9]+ RMAN bars, 2 job bars; legend: .*RMAN command, start to end \(v\$rman_status\).*job run overlapping the start of an episode' "grid, example: RMAN bars and the job runs that overlap a start are drawn, with a legend"
  has_l "$W/v2.cards" '^  RECURBAR: RMAN BACKUP DB INCR \(primary\) \| start 2026-11-13 20:31:30 \| end 2026-11-13 21:12:50 \| status COMPLETED$' "grid, example: the tooltip of a bar has the name, start, end and status"
  has_l "$W/v2.cards" '^  RECURBAR: Job APP_OWNER.EXPORT_REPORTS \| start 2026-11-06 20:37:10 \| end 2026-11-06 20:40:05 \| status SUCCEEDED \| overlaps the start of a listed occurrence$' "grid, example: a job run that overlaps a start is drawn, its tooltip says so"
  [ "$(grep -c 'RECURBAR: Job ' "$W/v2.cards")" = 2 ] && pass "grid, example: only the two job runs that overlap a start are drawn, not the 62 others" || fail "grid, example: job bars"
  # the grouped entries of the explanation table
  has_l "$W/v2.parts" "EXPLROW: Redo or its acknowledgement lost on the network path .*LGWR wait on 'SYNC Remote Write' in ASH, 3 rows, 20:38:01 to 20:39:02 ;" "explanations: the facts of one kind and name in a cell are one entry with its count and time range"
  python3 - "$W/v2.parts" "$W/g_full.parts" "$W/g_two.parts" "$W/g_hist.parts" <<'PY' > "$W/dupcells.out" 2>&1 && pass "explanations: no cell of any table repeats an entry title (a single fact stays a single entry, the rest are grouped)" || fail "explanations: an entry title is repeated in a cell" "$(head -4 "$W/dupcells.out")"
import re, sys
bad = []
for f in sys.argv[1:]:
    for l in open(f, encoding='utf-8'):
        if not l.lstrip().startswith('EXPLROW'): continue
        for cell in l.split(' | ')[1:2]:                                             # the Observed cell
            titles = [re.sub(r'(, \d+ rows)?,? ?[0-9][0-9:.]*( to [0-9:.]+)?$', '', e.strip()) for e in cell.split(' ; ')]
            titles = [re.sub(r'^Observed: ', '', t) for t in titles]
            d = {t for t in titles if titles.count(t) > 1}
            if d: bad.append('%s: %s' % (f, sorted(d)))
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
  has_l "$W/g_two.ui" '^explanation fact click: #inc[12]-o[0-9]+ -> li flashed$' "ui: a click on a grouped fact of the explanation table jumps to its first Observed row"
  has_l "$W/g_two.ui" '^who at start: 1$' "ui: the first incident's impact view shows first"
  has_l "$W/g_two.ui" '^who after choosing the last incident: 2$' "ui: the tabs of Who waited switch the incident"
  # active sessions by wait event (aas): the chart with its series and the colours of Enterprise Manager's wait classes, the data it is drawn from, the empty states
  has_l "$W/v2.cards" '^AAS: 11 areas, 23 minutes with a hover mark$' "aas, example: one area per event (eleven) and one hover mark per minute of the window"
  has_l "$W/v2.cards" '^  AASNOTE: Average active sessions per minute by wait event, foreground and background, AWR ASH \(10 s samples\)\.$' "aas, example: the caption says what is drawn, that it counts foreground and background sessions, and from which ASH source"
  has_l "$W/v2.cards" '^  AASLEGEND: ON CPU · CPU \| db file sequential read · User I/O \| db file scattered read · User I/O \| log file parallel write · System I/O \| db file parallel write · System I/O \| buffer busy waits · Concurrency \| enq: TX - row lock contention · Application \| log file sync · Commit \| log buffer space · Configuration \| SQL\*Net more data from client · Network \| SYNC Remote Write · Other$' "aas, example: the legend has one entry per event with its class, in the stack order of Enterprise Manager (CPU, User I/O, System I/O, Concurrency, Application, Commit, Configuration, Network, Other; SYNC Remote Write is class Other in v$event_name), the event with more samples lower within a class"
  has_l "$W/v2.cards" '^  AASCOLORS: ON CPU · CPU = var\(--wc-cpu\) \| db file sequential read · User I/O = var\(--wc-uio\) \| db file scattered read · User I/O = color-mix\(in srgb, var\(--wc-uio\) 72%, white\) \| log file parallel write · System I/O = var\(--wc-sio\) \| db file parallel write · System I/O = color-mix\(in srgb, var\(--wc-sio\) 72%, white\) \| ' "aas, example: an event takes the colour of its class, a second event of the same class a lighter shade of it"
  has_l "$W/v2.cards" 'log file sync · Commit = var\(--wc-commit\) \| log buffer space · Configuration = var\(--wc-conf\) \| SQL\*Net more data from client · Network = var\(--wc-net\) \| SYNC Remote Write · Other = var\(--wc-other\)$' "aas, example: Commit, Configuration, Network and Other have their colours too"
  has_l "$W/v2.cards" '^  AASFOOT: Colours: the wait class of each event, as in Enterprise Manager\.$' "aas, example: the footnote says where the colours come from, and nothing else when the source was not capped and holds the window"
  python3 - "$R/report/template.html" <<'PY' > "$W/wc.out" 2>&1 && pass "aas: the thirteen wait class colours of Enterprise Manager are custom properties of :root, the same in the light and the dark theme" || fail "aas: the wait class colours" "$(head -4 "$W/wc.out")"
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
want = {'cpu': '00CC00', 'sched': 'CCFFCC', 'uio': '004AE7', 'sio': '0094E7', 'conc': '8B1A00', 'app': 'C02800', 'commit': 'E46800', 'conf': '5C440B', 'adm': '717354', 'net': '989779', 'queue': 'C2B79B', 'clu': 'C9C2AF', 'other': 'F06EAA'}
css = t[:t.index('</style>')]
root = css[css.index(':root {'):css.index('}', css.index(':root {'))]
got = dict(re.findall(r'--wc-(\w+): #([0-9A-Fa-f]{6})', root))
bad = ['%s: %s, not %s' % (k, got.get(k), v) for k, v in want.items() if (got.get(k) or '').upper() != v]
dark = [x for x in re.findall(r'--wc-', css[css.index('@media (prefers-color-scheme: dark)'):])]
if dark: bad.append('a --wc-* property is set again for the dark theme')
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
  python3 "$T/extract.py" "$W/v2.dom" --aas > "$W/v2.aas"
  python3 - "$R/examples/sample_primary.jsonl" "$W/v2.aas" <<'PY' > "$W/aasfg.out" 2>&1 && pass "aas, example: for every minute the foreground samples of its aas records add up to its fg record, and the total of the tooltip is (foreground + background samples) / 6 samples a minute" || fail "aas, example: the aas records against fg, and the tooltips" "$(head -6 "$W/aasfg.out")"
import json, re, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
meta = next(o for o in recs if o['t'] == 'meta'); per = 60 if meta['ash'] == 'V' else 6
fg = {o['m']: o['lgwr'] + o['other'] + o['cpu'] for o in recs if o['t'] == 'fg'}
f, b = {}, {}
for o in recs:
    if o['t'] == 'aas':
        f[o['m']] = f.get(o['m'], 0) + o['fg']; b[o['m']] = b.get(o['m'], 0) + o['bg']
bad = []
if not fg: bad.append('no fg records')
for m in sorted(set(fg) | set(f)):
    if fg.get(m, 0) != f.get(m, 0): bad.append('%s: fg %s, aas foreground %s' % (m, fg.get(m), f.get(m)))
hov = {}
for l in open(sys.argv[2], encoding='utf-8'):
    mt = re.match(r'AASHOVER (\d\d:\d\d) \| .* \| Total (\S+)$', l)
    if mt: hov[mt.group(1)] = mt.group(2)
if sorted(hov) != sorted(m[11:] for m in f): bad.append('hovered minutes %s, minutes with records %s' % (sorted(hov), sorted(m[11:] for m in f)))
for m in f:
    want = (f[m] + b[m]) / per; got = hov.get(m[11:])
    if got is None or abs(float(got) - want) > (0.06 if want >= 10 else 0.006): bad.append('%s: tooltip total %s, expected %.3f' % (m, got, want))
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
  # the empty states: no records and no cov record (v1, bundles of the older collectors), a failed statement, a source that holds nothing, one that was skipped, a cov record that counts events without records
  for n in v1 pre3 g_two g_quiet g_noash g_drift g_lost g_tzoff g_rtpmode g_rac g_late g_waitcov; do has_l "$W/$n.cards" '^AAS: Not collected: no aas records in this bundle\.$' "aas, $n: no aas records and no cov record: not collected"; done
  has_l "$W/g_stfail.cards" '^AAS: Not checked: aas, the statement over ASH failed\.$' "aas, stfail: a failed statement is not checked, with the note of its cov record: no chart"
  has_l "$W/g_full.cards" '^AAS: 11 areas, 45 minutes with a hover mark$' "aas, full: the chart of the scenario is drawn over the 45 minutes of its window"
  has_l "$W/g_full.cards" '^  AASFOOT: Colours: the wait class of each event, as in Enterprise Manager\.$' "aas, full: the colour footnote only, when nothing was cut"
  has_l "$W/g_full.cards" '^  AASNOTE: Average active sessions per minute by wait event, foreground and background, ASH \(1 s samples\)\.$' "aas, full: the same caption with the 1 s wording"
  has_l "$W/g_capped.cards" '^AAS: 11 areas, 45 minutes with a hover mark$' "aas, capped: a bundle whose other sources were cut at their caps draws the chart as before"
  has_l "$W/g_hist.cards" '^AAS: 13 areas, 45 minutes with a hover mark$' "aas, hist: twelve events by name and the rest folded: thirteen areas"
  has_l "$W/g_hist.cards" '^  AASLEGEND: .* \| Other events \(6 folded\)$' "aas, hist: the folded rest is the last entry of the legend, with the number of events folded, and not named like a wait class"
  has_l "$W/g_hist.cards" '^  AASCOLORS: .* \| Other events \(6 folded\) = var\(--muted-fg\)$' "aas, hist: ... and grey"
  has_l "$W/g_hist.cards" 'direct path read · User I/O = color-mix\(in srgb, var\(--wc-uio\) 50%, white\) \| direct path write · User I/O = color-mix\(in srgb, var\(--wc-uio\) 35%, white\)' "aas, hist: the third and fourth event of one class take progressively lighter shades"
  has_l "$W/g_hist.cards" '^  AASFOOT: Colours: the wait class of each event, as in Enterprise Manager\. 18 events found: the 12 with the most samples are shown by name, the others are added up as Other events\.$' "aas, hist: a capped source says how many events were found and that the 12 with the most samples are shown by name, after the colour footnote (appended, not replacing it)"
  mkdir -p "$W/aasv"; AP=$W/gen/full_primary.jsonl
  grep -v '"t":"aas"' "$AP" | sed 's/"src":"aas","st":"ok","first":\("[^"]*"\),"last":\("[^"]*"\),"n":11,/"src":"aas","st":"empty","first":\1,"last":\2,"n":0,/' > "$W/aasv/empty_primary.jsonl"
  grep -v '"t":"aas"' "$AP" > "$W/aasv/noprec_primary.jsonl"
  sed 's/"src":"aas","st":"ok",/"src":"aas","st":"skipped",/' "$AP" > "$W/aasv/skip_primary.jsonl"
  grep -v '"t":"aas"' "$AP" | grep -v '"src":"aas"' > "$W/aasv/nocov_primary.jsonl"
  sed 's/"src":"aas","st":"ok","first":"2026-11-20 09:00:00"/"src":"aas","st":"ok","first":"2026-11-20 10:20:00"/' "$AP" > "$W/aasv/late_primary.jsonl"
  for v in empty noprec skip nocov late; do cp "$W/gen/full_standby.jsonl" "$W/aasv/${v}_standby.jsonl"; render g_aas$v "$W/aasv/${v}_primary.jsonl" "$W/aasv/${v}_standby.jsonl"; nojs g_aas$v "aas, $v"; python3 "$T/extract.py" "$W/g_aas$v.dom" --cards > "$W/g_aas$v.cards"; done
  has_l "$W/g_aasempty.cards" '^AAS: No ASH samples in the window \(or no Diagnostics Pack data\)\.$' "aas: a source that read fine and found no sample says so, not that it was not collected"
  has_l "$W/g_aasnoprec.cards" '^AAS: Not checked: aas, the coverage record found 11 events but the bundle holds no aas records\.$' "aas: a cov record that counted events with no records behind it is not checked, not none"
  has_l "$W/g_aasskip.cards" '^AAS: Not collected: the aas read was skipped' "aas: a skipped read is not collected, with its note"
  has_l "$W/g_aasnocov.cards" '^AAS: Not collected: no aas records in this bundle\.$' "aas: no records and no cov record (a bundle of an older collector): not collected"
  for v in empty noprec skip nocov late; do no_l "$W/g_aas$v.cards" 'NaN|undefined|Invalid Date' "aas, $v: no NaN, undefined or Invalid Date"; done
  has_l "$W/g_aaslate.cards" '^  AASFOOT: Colours: the wait class of each event, as in Enterprise Manager\. Not covered: primary active sessions by wait event holds nothing before 2026-11-20 10:20:00; the interval starts 2026-11-20 10:00:00\.$' "aas: a source that starts after the window says so in the footnote, after the colour sentence (appended, not replacing it)"
  for n in v1 pre3 g_stfail g_aasempty g_aasnoprec g_aasskip g_aasnocov; do has "$W/$n.dom" '<p class="fn" id="aasFoot"></p>' "aas, $n: an empty state leaves the footnote empty"; done
  # nothing of it is a signal, an explanation or part of the hand-over texts
  for n in v2 g_full g_hist g_stfail g_capped; do
    python3 "$T/extract.py" "$W/$n.dom" --net > "$W/$n.aasnn"; python3 "$T/extract.py" "$W/$n.dom" --ticket > "$W/$n.aastt"; python3 "$T/extract.py" "$W/$n.dom" > "$W/$n.aasclaims"; python3 "$T/extract.py" "$W/$n.dom" --parts > "$W/$n.aasparts"
    no_l "$W/$n.aasnn" 'active sessions|wait event|ON CPU|(^|[^a-z])aas([^a-z]|$)' "aas, $n: the network text holds nothing of the active sessions chart"; no_l "$W/$n.aastt" 'active sessions|wait event|ON CPU|(^|[^a-z])aas([^a-z]|$)' "aas, $n: nor does the ticket text"
    no_l "$W/$n.aasclaims" '^(SIGNAL|OBSERVED|READING|RULED|NONEFOUND|NOTCHECKED|  OBSERVED|  READING).*(active sessions|ON CPU|(^|[^a-z])aas([^a-z]|$))' "aas, $n: no signal, observation, reading or ruled-out entry mentions it"
    no_l "$W/$n.aasparts" '^(EXPL|  EXPL|NEXT|SEQ|  SEQ).*(active sessions|ON CPU|(^|[^a-z])aas([^a-z]|$))' "aas, $n: nor an explanation, a hint or the sequence of the incident"
  done
  # the full scenario: the standby is one hour behind; its RMAN commands are laid on the primary's clock; coverage decides between none and not covered
  has_l "$W/g_full.cards" '^  EPROW inc1 .*\| 10:10:20 / 5 min 20 s after the first line \| average 0.84 MB/s, largest 1 minute 3.3 MB/s / 10:00 to 11:00 \| RMAN \(primary\): BACKUP ARCHIVELOG, 09:57:40 to 10:02:02, COMPLETED / RMAN \(standby\): BACKUP ARCHIVELOG, 09:58:30 to 10:03:30, COMPLETED / job: none / log switch: thread 1 sequence [0-9]+, -8 s$' "full: the standby's RMAN command (08:58:30 on its own clock) is shown at 09:58:30 on the primary's clock"
  has_l "$W/g_full.cards" '^  EPROW h4 .*\| no return line in the history \| average 1.4 MB/s' "full: no return line in the history is said as such, not as 0 or a guess"
  has_l "$W/g_full.cards" '^  EPROW h0 .*\| not covered \| not covered \| RMAN \(primary\): not covered / RMAN \(standby\): not covered / job: none / log switch: not covered$' "full: an episode before what alsync, the AWR, the RMAN list and the log-switch history hold is not covered, while the job log (older) says none"
  has_l "$W/g_full.cards" '^  EPCOUNT: An RMAN command named BACKUP ARCHIVELOG started within 10 minutes before 5 of the 7 episodes that v\$rman_status covers on the primary\.$' "full: five of the seven episodes the RMAN list covers"
  has_l "$W/g_full.cards" '^  EPCOUNT: A line that ends the UNSYNCHRONIZED period follows 4 of the 6 episodes of the history that alsync covers\.$' "full: four of the six episodes alsync covers have a return line"
  has_l "$W/g_full.cards" '^  WHOWL: Per-minute workload \(wl\): no records in these bundles\.$' "full: without wl records the impact card says so instead of comparing"
  has_l "$W/g_full.cards" '^  EPROW h6 .*APP.EXPORT_REPORTS, 10:02:00 to 10:07:00, SUCCEEDED' "full: a job run that was running at the start of an episode is listed"
  # hist: capped, failed and not covered
  has_l "$W/g_hist.cards" '^  EPROW inc1 .*RMAN \(primary\): BACKUP ARCHIVELOG, 09:57:30 to 10:02:10, COMPLETED; BACKUP DB INCR, 09:58:00 to running, RUNNING / RMAN \(standby\): not checked \(statement failed\) / job: not checked \(statement failed\) / log switch: thread 1 sequence [0-9]+, -25 s$' "hist: a command with no end time started within the 10 minutes is \"running\"; a failed read is not checked"
  has_l "$W/g_hist.cards" '^  EPROW h1 .*RMAN \(primary\): not covered' "hist: a capped RMAN list holds only from its oldest kept record on: the episode before it is not covered"
  has_l "$W/g_hist.cards" '^  EPROW h0 .*\| not covered \| not covered \| RMAN \(primary\): not covered' "hist: the episode before the alsync history and the AWR is not covered"
  has_l "$W/g_hist.cards" '^  EPCOUNT: cdb_scheduler_job_run_details: not checked, the cdb_scheduler_job_run_details statement failed\.$' "hist: a failed job read counts no episode and says why"
  has_l "$W/g_hist.cards" '^  EPCOUNT: v\$rman_status on the standby: not checked, the statement failed \(ORA-00942: table or view does not exist\)\.$' "hist: a failed read whose note names no statement gets the words and the note"
  has_l "$W/g_hist.cards" '^  WHOCAP: .*Capped: 44 groups found, the 15 with the most samples kept per list\.$' "hist: the impact card states a capped lfs_by"
  # stfail: a statement that failed is "not checked", wherever its source is shown; never "none", never "not covered"
  no_l "$W/g_stfail.cards" '^  (EPROW|EPCOUNT).*(not covered|: none( /|$))' "stfail: no cell and no count says none or not covered for a source whose statement failed"
  [ "$(grep -o 'not checked (statement failed)' "$W/g_stfail.cards" | wc -l | tr -d ' ')" = 47 ] && pass "stfail: every cell of a failed source reads not checked (statement failed): five in the incident's row, six in each of the seven rows of the history" || fail "stfail: the cells that say not checked (statement failed)" "$(grep -c 'not checked (statement failed)' "$W/g_stfail.cards") lines"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: cdb_scheduler_job_run_details: not checked, the cdb_scheduler_job_run_details statement failed\.$' "stfail: the job count line says not checked and why (the note of the cov record), whatever the records say"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: v\$rman_status on the primary: not checked, the v\$rman_status statement failed\.$' "stfail: ... the same for the RMAN list of the primary"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: v\$rman_status on the standby: not checked, the v\$rman_status statement failed\.$' "stfail: ... and of the standby"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: v\$log_history: not checked, the v\$log_history statement failed\.$' "stfail: ... the log switches"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: wl_hist: not checked, the dba_hist_sysmetric_summary statement failed\.$' "stfail: ... the workload history"
  has_l "$W/g_stfail.cards" '^  EPCOUNT: alsync on the primary: not checked, the pass over v\$diag_alert_ext failed\.$' "stfail: ... the alsync pass"
  no_l "$W/g_stfail.cards" 'covers\.|covers on the|no episode lies inside' "stfail: no count line claims a coverage for a failed source"
  has_l "$W/g_stfail.cards" '^  WHOLISTS: Not checked: lfs_by, the statement over ASH failed\.$' "stfail: who waited says not checked and why when lfs_by failed"
  has_l "$W/g_stfail.cards" '^RECURBARS: 0 RMAN bars, 1 job bars;' "stfail: the job records that arrived are still drawn in the day-and-hour grid (a source whose cov record is an error, no records for the others)"
  python3 "$T/extract.py" "$W/g_stfail.dom" --parts > "$W/g_stfail.parts"; python3 "$T/extract.py" "$W/g_stfail.dom" > "$W/g_stfail.txt"
  for pair in 'primary/act/job' 'primary/act/rman' 'primary/act/logsw' 'standby/act/rman' 'primary/wl_hist' 'primary/alsync/sql' 'primary/lfs_by' 'primary/aas'; do
    has_l "$W/g_stfail.txt" "^COV: $pair \\| error \\| – – – \\| 0 / cap [0-9]+ \\| not checked, the .*(failed)" "stfail, coverage: $pair is an error row that says not checked and why"
    has_l "$W/g_stfail.parts" "^REACH: $pair \\| not checked$" "stfail, coverage: $pair does not say it reached the window or was read as collected"
  done
  # capped: a capped source holds from its oldest kept record on: before it not covered, inside it an answer, and the count line says it was cut
  has_l "$W/g_capped.cards" '^  EPROW h1 .*\| RMAN \(primary\): not covered / RMAN \(standby\): none / job: not covered / log switch: not covered$' "capped: an episode before the oldest kept job run, RMAN command and log switch is not covered by them (the standby's uncapped RMAN list answers)"
  has_l "$W/g_capped.cards" '^  EPROW h2 .*/ job: none / log switch: not covered$' "capped: ... the job list holds from 11-13 09:30: an episode after it with no job run in its ten minutes is none, not not covered"
  has_l "$W/g_capped.cards" '^  EPROW h6 .*\| RMAN \(primary\): BACKUP ARCHIVELOG, 09:57:40 to 10:02:02, COMPLETED / RMAN \(standby\): none / job: APP.EXPORT_REPORTS, 10:02:00 to 10:07:00, SUCCEEDED / log switch: none$' "capped: ... an episode inside every kept span gets its names"
  has_l "$W/g_capped.cards" '^  EPROW h5 .*\| not covered \| average 1.6 MB/s' "capped: alsync and wl_hist: an episode that starts before the oldest kept line (alsync) is not covered, one inside the kept AWR intervals has its redo rate"
  has_l "$W/g_capped.cards" '^  EPROW h2 .*\| not covered \| not covered \| ' "capped: wl_hist: an episode before the oldest kept interval is not covered"
  has_l "$W/g_capped.cards" 'started within 10 minutes before 2 of the 6 episodes that cdb_scheduler_job_run_details covers\. cdb_scheduler_job_run_details was cut at its cap of 2000 run records and holds from 2026-11-13 09:30 on\.$' "capped: the job count line counts the six episodes inside the kept span and says the source was cut at its cap"
  has_l "$W/g_capped.cards" '^  EPCOUNT: A log switch within 60 s of the start: 2 of 4 episodes that v\$log_history covers\. v\$log_history was cut at its cap of 5000 records and holds from 2026-11-16 00:17 on\.$' "capped: ... the log-switch count line too"
  has_l "$W/g_capped.cards" 'episodes that v\$rman_status covers on the primary\. v\$rman_status on the primary was cut at its cap of 500 records and holds from 2026-11-16 02:00 on\.$' "capped: ... and the RMAN count line of the primary"
  no_l "$W/g_capped.cards" 'covers on the standby\..*cut at' "capped: ... but not the standby's RMAN list, which was not cut"
  has_l "$W/g_capped.cards" 'alsync on the primary was cut at its cap of 300 lines and holds from 2026-11-18 10:09 on\.$' "capped: ... the alsync count line"
  has_l "$W/g_capped.cards" '^  EPCOUNT: wl_hist was cut at its cap of 1500 intervals and holds from 2026-11-17 00:00 on\.$' "capped: ... and one line for the workload history"
  python3 "$T/extract.py" "$W/g_capped.dom" > "$W/g_capped.txt"
  has_l "$W/g_capped.txt" '^COV: primary/act/job \| ok \| 10-21 14:46 – 11-20 14:30 kept from 11-13 09:30 \| 5400 / cap 2000 capped \|' "capped, coverage: a capped source shows the oldest record it kept beside what its view holds"
  no_l "$W/g_capped.txt" '^COV: standby/act/rman .*kept from' "capped, coverage: a source that was not cut has no such line"
  # records absent: the same bundles as before render as before, with a plain not collected
  for sc in two quiet noash drift lost tzoff rtpmode rac late waitcov; do
    has_l "$W/g_$sc.cards" '^EP: Not collected: no alsync, wl_hist or act records in these bundles' "episodes, scenario $sc: not collected, no table"
    no_l "$W/g_$sc.cards" '^  EPROW|^RECURBARS: [1-9]' "episodes, scenario $sc: no row, no activity bar without the records"
  done
  for n in v1 pre3; do has_l "$W/$n.cards" '^EP: Not collected' "episodes, $n: not collected"; has_l "$W/$n.cards" '^  WHOLISTS: Not collected: no lfs_by records in this bundle' "who waited, $n: the lists say not collected"; done
  has_l "$W/g_two.cards" '^WHOTABS: Incident 1 \| Incident 2$' "who waited, two incidents: a tab each"
  [ "$(grep -c '(hidden tab)' "$W/g_two.cards")" = 1 ] && pass "who waited, two incidents: the other incident's view is there, hidden (it prints)" || fail "who waited, two incidents: hidden view"
  has_l "$W/g_two.cards" '^  WHOWL: Per-minute workload \(wl\): no records in these bundles\.$' "who waited, scenario two: no wl records, said so"
  has_l "$W/g_quiet.cards" '^WHO: Whole window · ' "who waited, quiet window: the whole window, no incident tab"
  has_l "$W/g_quiet.cards" '^WHOTABS: Window$' "who waited, quiet window: one tab (hidden)"
  has_l "$W/v1.cards" '^  WHOWL txn \| ' "who waited, v1: the per-minute workload is compared (wl is in a v1 bundle)"
  # nothing of this reaches the hand-over texts
  for n in v2 g_full g_hist g_sbgap g_stfail g_capped; do python3 "$T/extract.py" "$W/$n.dom" --net > "$W/$n.nn"; python3 "$T/extract.py" "$W/$n.dom" --ticket > "$W/$n.tt"; no_l "$W/$n.nn" 'RMAN|lfs_by|alsync|wl_hist|log switch|Who waited|Episodes side by side|BACKUP' "hand-over, $n: the network text holds nothing from the new records"; no_l "$W/$n.tt" 'RMAN|lfs_by|alsync|wl_hist|log switch|Who waited|Episodes side by side|BACKUP|impact' "hand-over, $n: the ticket text holds nothing from the new records, and no impact"; done
else
  [ $HAVE_PY = 0 ] || skip "render tests: Chrome not found (set CHROME=/path/to/chrome)"
fi

# ---------------------------------------------------------------- collect.sh
cp "$T/fixtures/bin/sqlplus" "$W/sqlplus"; chmod +x "$W/sqlplus"
NOSQL=$W/no-such-sqlplus
bnorm() { sed -e 's/"host":"[^"]*"/"host":"HOST"/' -e 's/"collected":"[^"]*"/"collected":"NOW"/' -e "s#$D#DIR#g" "$1"; }   # the host name and the test directory (the golden files are the same under sh and dash)
expect() {   # name, got file, expected file under tests/expected
  bnorm "$2" > "$2.norm"
  if [ -n "$UPDATE" ]; then cp "$2.norm" "$T/expected/$3"; echo "updated tests/expected/$3"; else same "$1" "$2.norm" "$T/expected/$3"; fi
}
fmt() { if [ $HAVE_PY = 1 ]; then if out=$(python3 "$T/check_bundle.py" "$2" collector $3); then pass "format: $1"; else fail "format: $1" "$out"; fi; fi; }   # collect.sh output: the newer sources must all be there
has() { if grep -q "$2" "$1"; then pass "$3"; else fail "$3" "$(grep -E "${4:-$2}" "$1" | head -3)"; fi; }

SHBIN=$(command -v sh)
NOWT='2026-11-20T12:00:00'   # DGR_NOW; the T keeps it one word in an env command line
# mkhost NAME tool...: $W/host.NAME/bin holds links to the basic utilities and a stub (tests/fixtures/host/stub.sh) for each tool named; a tool not named is missing on that host
mkhost() {
  hb=$W/host.$1/bin; mkdir -p "$hb"; shift
  for u in awk sed grep cut tr sort uniq head tail wc cat date hostname find touch basename dirname ls rm mkdir cp mv; do p=$(command -v $u) && ln -sf "$p" "$hb/$u"; done
  for tl in "$@"; do printf '#!/bin/sh\nexec "%s" "%s" %s "$@"\n' "$SHBIN" "$T/fixtures/host/stub.sh" "$tl" > "$hb/$tl"; chmod +x "$hb/$tl"; done
}
mkhost bare uname
mkhost lin uname sar chronyc ntpq timedatectl getent netstat ping sysctl lsnrctl sleep
mkhost aix uname sar ntpq lssrc netstat ping no lsnrctl sleep
mkhost aixlssrc uname lssrc
mkhost chrony uname chronyc
mkhost chronyntp uname chronyc ntpq
mkhost ntponly uname ntpq
mkhost tdonly uname timedatectl
mkhost nosar uname netstat ping sleep
hasf() { if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3" "no line holds: $2"; fi; }          # file, fixed string, name
nof() { if grep -qF -- "$2" "$1"; then fail "$3" "$(grep -F -- "$2" "$1" | head -3 | cut -c1-200)"; else pass "$3"; fi; }
cnt() { n=$(grep -c "$2" "$1"); if [ "$n" = "$3" ]; then pass "$4"; else fail "$4" "$n lines match $2, want $3"; fi; }                  # file, regex, count, name
# covst FILE SRC [KIND]: the st of the cov record of that source (and kind), "-" when there is none or more than one; covis FILE SRC KIND WANT NAME
covst() { awk -v s="$2" -v k="$3" '/"t":"cov"/ && index($0, "\"src\":\"" s "\"") && (k == "" || index($0, "\"kind\":\"" k "\"")) { n++; if (match($0, /"st":"[a-z]+"/)) st = substr($0, RSTART + 6, RLENGTH - 7) } END { print (n == 1 ? st : "-") }' "$1"; }
covis() { got=$(covst "$1" "$2" "$3"); if [ "$got" = "$4" ]; then pass "$5"; else fail "$5" "cov $2${3:+/$3} is $got, want $4"; fi; }

collect_tests() {   # SHELL LABEL
  SH=$1; L=$2; D=$W/c.$L; mkdir -p "$D"; cp -R "$T/fixtures/logs/." "$D/"   # a fresh copy: the 45-day trace limit looks at file ages
  WIN1='2026-11-13 23:50'; WIN2='2026-11-14 00:10'
  cd "$D" || return

  # standby: text alert log, traces and listener log, nothing else; the window crosses midnight
  CB="env PATH=$W/host.bare/bin DGR_NOW=$NOWT"
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -l listener.log -o standby.jsonl 2> err1; echo $? > rc1
  expect "collect.sh ($L): standby from raw logs across midnight" standby.jsonl standby_logs.jsonl
  fmt "collect.sh ($L): standby bundle" standby.jsonl
  has err1 'database: sqlplus not found, skipped' "collect.sh ($L): says the database was skipped"
  if [ "$(cat rc1)" = 0 ]; then pass "collect.sh ($L): exit 0 without sqlplus"; else fail "collect.sh ($L): exit status without sqlplus is $(cat rc1)"; fi

  # primary: options after the positional arguments, refused CONNECTION_IDs of the standby looked up in its listener log
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -c standby.jsonl -o primary.jsonl 2> err2
  expect "collect.sh ($L): primary, CONNECTION_ID lookup, clock from the listener log" primary.jsonl primary_logs.jsonl
  fmt "collect.sh ($L): primary bundle" primary.jsonl

  # sqlplus fails to connect: visible, the log scans carry on, exit status 1
  STUB_MODE=fail SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -l listener.log -o dbfail.jsonl 2> err3; echo $? > rc3
  expect "collect.sh ($L): failed sqlplus, log scans carry on" dbfail.jsonl standby_dbfail.jsonl
  has err3 '^database: FAILED: ORA-01017' "collect.sh ($L): prints database: FAILED with the first error lines"
  if [ "$(cat rc3)" = 1 ]; then pass "collect.sh ($L): exits 1 after a failed sqlplus"; else fail "collect.sh ($L): exit status after a failed sqlplus is $(cat rc3)"; fi
  if grep -q 'database: done' err3; then fail "collect.sh ($L): printed 'database: done' after a failed sqlplus"; else pass "collect.sh ($L): no 'database: done' after a failed sqlplus"; fi
  fmt "collect.sh ($L): bundle after a failed sqlplus" dbfail.jsonl

  # sqlplus connects, writes meta and one cov record, a statement fails: the missing sources get an error record
  STUB_MODE=meta SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -a nosuch.log -l listener.log -o dbpart.jsonl 2> err4; echo $? > rc4
  expect "collect.sh ($L): partial sqlplus, error cov records for the sources it did not write" dbpart.jsonl primary_dbpartial.jsonl
  has err4 'database: done' "collect.sh ($L): says database: done when the meta line arrived"
  fmt "collect.sh ($L): bundle after a partial sqlplus" dbpart.jsonl allow-ora

  # the UTC offset changes inside the window (clock change)
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "2026-10-25 01:50" "2026-10-25 02:20" -a alert_dst.log -o dst.jsonl 2> err5
  has dst.jsonl '"t":"clock","side":"standby","utc_off":"+02:00","src":"alert log, offset changes inside the window"' "collect.sh ($L): clock record notes an offset change inside the window" '"t":"clock"'

  # the SQL wrote a clock record (alert log rows in the window): it wins over the listener log's ISO line, and there is only one
  STUB_MODE=clock SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener.log -o sqlclock.jsonl 2> err10
  n=$(grep -c '"t":"clock"' sqlclock.jsonl)
  if [ "$n" = 1 ] && grep -q '"t":"clock","side":"primary","utc_off":"+05:30","src":"alert log"' sqlclock.jsonl; then pass "collect.sh ($L): a clock record from SQL is kept, no second one added"
  else fail "collect.sh ($L): a clock record from SQL is kept, no second one added" "$(grep '"t":"clock"' sqlclock.jsonl)"; fi

  # the database was read but no log has an offset in the window: systimestamp from the meta line, flagged as collection time
  STUB_MODE=meta SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t nosuchdir -l nosuch.log -o sysclock.jsonl 2> err11
  has sysclock.jsonl '"t":"clock","side":"primary","utc_off":"+01:00","src":"systimestamp at collection time"' "collect.sh ($L): clock from systimestamp says it is the collection-time offset" '"t":"clock"'

  # no offset in any log: the clock record says it comes from collection time
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -o noclock.jsonl 2> err6
  has noclock.jsonl '"t":"clock","side":"primary","utc_off":.*at collection time' "collect.sh ($L): clock falls back to collection time and says so" '"t":"clock"'

  # the trace file age limit: a file from 2019 newer than the window start is not scanned, and that is recorded
  mkdir -p oldtr; touch -t 201903010930 oldtr/x_lgwr_1.trc; touch -t 201903011005 oldtr/y_lgwr_2.trc
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "2019-03-01 10:00" "2019-03-01 10:10" -t oldtr -a /nonexistent -o age.jsonl 2> err7
  has age.jsonl '"src":"trace","files":0,"st":"empty".*"capped":true.*older files were not scanned' "collect.sh ($L): trace age limit recorded as capped" '"src":"trace"'
  has age.jsonl '"src":"alert_text","st":"skipped".*not readable: /nonexistent' "collect.sh ($L): unreadable alert log is a skipped cov record" '"src":"alert_text"'
  hasf age.jsonl '"src":"alsync","kind":"text","st":"skipped","first":null,"last":null,"n":0,"cap":300,"capped":false,"note":"alert log not readable: /nonexistent"' "collect.sh ($L): ... and so is its alsync record, next to the alhist one"

  # the caps: each truncation is recorded with the number found before the cut
  mkdir -p cap; awk 'BEGIN { print "*** 2026-11-14T00:00:00.000000+01:00 (CDB$ROOT(1))"; for (i = 1; i <= 450; i++) printf "ORA-16198: line %03d\n", i }' > cap/x_lgwr_1.trc
  awk 'BEGIN { for (i = 1; i <= 305; i++) printf "2026-11-01T%02d:%02d:%02d.000000+01:00\nORA-16198 number %d\nLGWR (PID:4242): LAD:2 is SYNCHRONIZED\n", int(i / 3600), int(i / 60) % 60, i % 60, i }' > cap/alert.log
  awk 'BEGIN { for (i = 1; i <= 505; i++) printf "14-NOV-2026 00:01:%02d * (CONNECT_DATA=(SERVICE_NAME=A)(CONNECTION_ID=C%04d)) * (ADDRESS=(PROTOCOL=tcp)(HOST=192.0.2.9)(PORT=1)) * establish * A * 12514\n", i % 60, i }' > cap/standby_lsnr.log
  awk 'BEGIN { for (i = 1; i <= 2005; i++) printf "14-NOV-2026 00:02:%02d * (CONNECT_DATA=(SERVICE_NAME=A)(CONNECTION_ID=C%04d)) * (ADDRESS=(PROTOCOL=tcp)(HOST=192.0.2.9)(PORT=1)) * establish * A * 0\n", i % 60, i % 500 + 1 }' > cap/primary_lsnr.log
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t cap -a cap/alert.log -l cap/standby_lsnr.log -o capstby.jsonl 2> err8
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t cap -l cap/primary_lsnr.log -c capstby.jsonl -o capprim.jsonl 2> err9
  has capstby.jsonl '"src":"trace","files":1,"st":"ok","first":"2026-11-14 00:00:00","last":"2026-11-14 00:00:00","n":450,"cap":400,"capped":true' "collect.sh ($L): trace lines capped at 400, 450 found" '"src":"trace"'
  has capstby.jsonl '"src":"alhist","kind":"text","st":"ok".*"n":305,"cap":300,"capped":true' "collect.sh ($L): alhist capped at 300, 305 found" '"src":"alhist"'
  has capstby.jsonl '"src":"lsnr_ref","st":"ok".*"n":505,"cap":500,"capped":true' "collect.sh ($L): lsnr_ref capped at 500, 505 found" '"src":"lsnr_ref"'
  has capprim.jsonl '"src":"cid","st":"ok".*"n":2005,"cap":2000,"capped":true' "collect.sh ($L): cid_hit capped at 2000, 2005 found" '"src":"cid"'
  for pair in 'trace 400' 'alhist 300' 'lsnr_ref 500'; do
    set -- $pair; n=$(grep -c "\"t\":\"$1\"" capstby.jsonl)
    if [ "$n" = "$2" ]; then pass "collect.sh ($L): bundle holds $2 $1 records"; else fail "collect.sh ($L): bundle holds $n $1 records, want $2"; fi
  done
  n=$(grep -c '"t":"cid_hit"' capprim.jsonl); if [ "$n" = 2000 ]; then pass "collect.sh ($L): bundle holds 2000 cid_hit records"; else fail "collect.sh ($L): bundle holds $n cid_hit records, want 2000"; fi
  # the same file has a sync line under each of the 305 history lines (same second, own last-second variable): alsync is capped like alhist
  has capstby.jsonl '"src":"alsync","kind":"text","st":"ok".*"n":305,"cap":300,"capped":true' "collect.sh ($L): alsync capped at 300, 305 found" '"src":"alsync"'
  n=$(grep -c '"t":"alsync"' capstby.jsonl); if [ "$n" = 300 ]; then pass "collect.sh ($L): bundle holds 300 alsync records"; else fail "collect.sh ($L): bundle holds $n alsync records, want 300"; fi
  hasf capstby.jsonl '"t":"alsync","side":"standby","ts":"2026-11-01 00:00:06"' "collect.sh ($L): the newest 300 alsync records are kept: the 6th is the oldest"
  nof capstby.jsonl '"t":"alsync","side":"standby","ts":"2026-11-01 00:00:05"' "collect.sh ($L): ... and the first five were cut"
  hasf capstby.jsonl '"t":"alsync","side":"standby","ts":"2026-11-01 00:05:05"' "collect.sh ($L): ... and the newest is there"

  # ---------------------------------------------------------------- collector phase 3: hosts with stubbed tools
  mkdir -p sadir lsnrdiag/alert lsnrdiag/trace; : > sadir/sa13; : > sadir/sa14; cp listener.log lsnrdiag/trace/listener.log
  newstate() { rm -rf "$W/state"; mkdir -p "$W/state"; }
  CL="env PATH=$W/host.lin/bin DGR_NOW=$NOWT STUB_STATE=$W/state SA_DIR=$D/sadir TNS_ADMIN=$D/netadmin STUB_LSNR_LOG=$D/lsnrdiag/alert/log.xml"

  # Linux standby: peer derived from the PROGRAM=oracle connections in its listener log (the log is found with lsnrctl status), sar, chronyc, sysctl, sqlnet.ora, tnsnames.ora, sampler log
  newstate
  STUB_MODE=peer STUB_SIDE=standby SQLPLUS=$W/sqlplus $CL "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -n sampler.log -o lstby.jsonl 2> errL1
  expect "collect.sh ($L): Linux standby with every stubbed tool" lstby.jsonl standby_linux.jsonl
  fmt "collect.sh ($L): Linux standby bundle" lstby.jsonl allow-ora
  cnt lstby.jsonl '"t":"lsnr_srv"' 4 "collect.sh ($L): four server-to-server connections (PROGRAM=oracle) in the window"
  hasf lstby.jsonl '{"t":"lsnr_srv","side":"standby","ts":"2026-11-13 23:58:12","host":"prim-host.example","ip":"198.51.100.11","port":33001,"svc":"SID:cdb1","code":"0"}' "collect.sh ($L): a server-to-server record has time, client host, source IP and port, service and code"
  hasf lstby.jsonl '"ip":"198.51.100.11","port":33002,"svc":"SID:cdb1","code":"12518"' "collect.sh ($L): a refused server-to-server connection keeps its return code"
  hasf lstby.jsonl '"src":"lsnr_srv","st":"ok"' "collect.sh ($L): the server-to-server source has a cov record"
  nof lstby.jsonl '"ts":"2026-08-09' "collect.sh ($L): a PROGRAM=oracle line outside the window is not listed"
  hasf lstby.jsonl '"t":"net","side":"standby","peer":"198.51.100.11","port":"1526"' "collect.sh ($L): the network check runs against the address of the PROGRAM=oracle connections, on the standby's listener port"
  hasf lstby.jsonl 'the address of the PROGRAM=oracle connections in the window (3 of 4)' "collect.sh ($L): the net record says how the peer was derived"
  hasf lstby.jsonl '"rtt":"0.412","loss":"0%","retr":5,"secs":10,"sendq":2160' "collect.sh ($L): the check measured round trip, loss, retransmit difference and the largest Send-Q"
  hasf lstby.jsonl 'measured at collection time, not during the window' "collect.sh ($L): the net cov note says it was measured at collection time"
  cnt lstby.jsonl '"t":"conn"' 3 "collect.sh ($L): the existing connections to the peer on the listener port (the ::ffff: form counts)"
  hasf lstby.jsonl '{"t":"conn","side":"standby","lip":"198.51.100.12","lport":1526,"pip":"198.51.100.11","pport":33002,"state":"ESTABLISHED","sendq":2160,"recvq":0}' "collect.sh ($L): a connection record has both endpoints, state and queues"
  hasf lstby.jsonl '{"t":"sar","side":"standby","rpt":"ETCP","ts":"2026-11-13 23:50:01","if":null,"m":{"atmptf/s":0.01,"estres/s":0.03,"retrans/s":12.50,"isegerr/s":0.02,"orsts/s":0.05}}' "collect.sh ($L): sar ETCP row on the first day of a window across midnight"
  hasf lstby.jsonl '"rpt":"ETCP","ts":"2026-11-14 00:00:01","if":null,"m":{"atmptf/s":0.02,"estres/s":0.04,"retrans/s":48.30' "collect.sh ($L): sar ETCP row on the second day"
  hasf lstby.jsonl '"rpt":"ETCP","ts":"2026-11-14 00:10:01"' "collect.sh ($L): the first sar row after the window is kept (the interval that overlaps its end)"
  nof lstby.jsonl '"rpt":"ETCP","ts":"2026-11-14 00:20:01"' "collect.sh ($L): later sar rows are not kept"
  nof lstby.jsonl '"rpt":"ETCP","ts":"2026-11-13 23:40:01"' "collect.sh ($L): earlier sar rows are not kept"
  hasf lstby.jsonl '"src":"sar","kind":"ETCP","st":"ok","first":"2026-11-13 00:00:01","last":"2026-11-14 00:30:01","n":3' "collect.sh ($L): sar ETCP cov holds what the files hold and the rows found"
  hasf lstby.jsonl '"src":"sar","kind":"TCP","st":"ok"' "collect.sh ($L): sar TCP is read on its own"
  hasf lstby.jsonl '2026-11-14: 1 LINUX RESTART line(s) in the window: the host was restarted' "collect.sh ($L): a LINUX RESTART line inside the window is noted"
  hasf lstby.jsonl '"rpt":"DEV","ts":"2026-11-13 23:50:01","if":"eth0"' "collect.sh ($L): sar DEV rows carry the interface"
  hasf lstby.jsonl '2026-11-14: '"$D"'/sadir/sa14 is dated 2026-10-14, not 2026-11-14' "collect.sh ($L): a sysstat file of another month (saDD wraps) is not used, and the cov note says so"
  hasf lstby.jsonl '"src":"sar","kind":"EDEV","st":"error"' "collect.sh ($L): a report the file does not have degrades to an error cov record"
  hasf lstby.jsonl 'Requested activities not available in file /var/log/sa/sa13' "collect.sh ($L): ... that carries sar's exact message"
  nof lstby.jsonl '"rpt":"EDEV"' "collect.sh ($L): ... and no rows"
  hasf lstby.jsonl '"t":"ntp","side":"standby","tool":"chronyc tracking","ref":"server1a.example.net","stratum":3,"off":0.000041695,"synced":"yes"' "collect.sh ($L): chronyc tracking: source, stratum, offset (fast = positive) and synchronised"
  hasf lstby.jsonl '"name":"net.ipv4.tcp_keepalive_time","value":"7200","tool":"sysctl -n"' "collect.sh ($L): sysctl keepalive time"
  hasf lstby.jsonl '"name":"net.ipv4.tcp_retries2","value":"15","tool":"sysctl -n"' "collect.sh ($L): sysctl tcp_retries2"
  hasf lstby.jsonl '"name":"SQLNET.EXPIRE_TIME","set":true,"value":"10"' "collect.sh ($L): sqlnet.ora value that is set"
  hasf lstby.jsonl '"name":"SQLNET.OUTBOUND_CONNECT_TIMEOUT","set":true,"value":"5"' "collect.sh ($L): sqlnet.ora names are matched case-insensitively, no spaces needed around ="
  hasf lstby.jsonl '"name":"TCP.CONNECT_TIMEOUT","set":true,"value":"8"' "collect.sh ($L): a trailing comment is not part of the value"
  hasf lstby.jsonl '"name":"SQLNET.INBOUND_CONNECT_TIMEOUT","set":false,"value":null' "collect.sh ($L): a parameter that is not set is recorded as not set"
  cnt lstby.jsonl '"t":"sqlnet"' 6 "collect.sh ($L): six sqlnet.ora parameters, set or not"
  hasf lstby.jsonl '"t":"ep","side":"standby","from":"fal_server","dest":null,"alias":"proddb_p","file":"'"$D"'/netadmin/tnsnames.ora","host":"prim-host.example","port":1526,"addrs":2,"ip":"198.51.100.11","ip_how":"getent hosts prim-host.example"' "collect.sh ($L): a fal_server alias is resolved through tnsnames.ora (an alias with a domain, two ADDRESS entries) and getent"
  hasf lstby.jsonl '"alias":"lost_alias","file":"'"$D"'/netadmin/tnsnames.ora","host":"nosuch.example","port":1599,"addrs":1,"ip":null,"ip_how":null' "collect.sh ($L): a host name getent cannot resolve leaves the address empty"
  hasf lstby.jsonl 'getent hosts did not resolve nosuch.example' "collect.sh ($L): ... and says so"
  cnt lstby.jsonl '"t":"netsamp"' 4 "collect.sh ($L): sampler samples inside the window, from the log and its rotated .1 file"
  hasf lstby.jsonl '"t":"netsamp","side":"standby","ts":"2026-11-13 23:58:20","off":"+01:00","rtt":null,"loss":true,"retr":1004,"sendq":4320' "collect.sh ($L): a sampler line without a reply is loss with its counters"
  hasf lstby.jsonl '"src":"netsamp","st":"ok","first":"2026-11-13 23:49:50","last":"2026-11-14 00:10:05","n":4' "collect.sh ($L): sampler cov: first and last in the files, samples in the window"
  hasf lstby.jsonl '(peer=198.51.100.12 port=1526 interval=5 started=2026-11-13T23:50:00+0100)' "collect.sh ($L): the sampler's header line is quoted in the cov note"
  has errL1 'Next, on the PRIMARY host:' "collect.sh ($L): after a standby run it says what to do on the primary"
  has errL1 '1. Copy the standby bundle there:   lstby.jsonl' "collect.sh ($L): ... names this bundle and reminds to copy it"
  has errL1 '2. Run:   sh .*collect.sh -c lstby.jsonl primary "2026-11-13 23:50" "2026-11-14 00:10"' "collect.sh ($L): ... gives the exact primary command with the window and -c"

  # Linux primary: the peer comes from the destination alias in v$archive_dest (tnsnames.ora, getent); the descriptor's port is used
  newstate
  STUB_MODE=peer STUB_SIDE=primary SQLPLUS=$W/sqlplus $CL "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -c lstby.jsonl -o lprim.jsonl 2> errL2
  expect "collect.sh ($L): Linux primary with every stubbed tool" lprim.jsonl primary_linux.jsonl
  fmt "collect.sh ($L): Linux primary bundle" lprim.jsonl allow-ora
  hasf lprim.jsonl '"t":"ep","side":"primary","from":"v$archive_dest","dest":2,"alias":"proddb_s_dgmgrl","file":"'"$D"'/netadmin/tnsnames.ora","host":"stby-host.example","port":1526,"addrs":1,"ip":"198.51.100.12"' "collect.sh ($L): the destination alias resolves to host, port and address"
  hasf lprim.jsonl '"t":"net","side":"primary","peer":"198.51.100.12","port":"1526"' "collect.sh ($L): the primary checks the destination's address on the descriptor's port"
  hasf lprim.jsonl 'destination proddb_s_dgmgrl of v$archive_dest = stby-host.example:1526 in tnsnames.ora or the descriptor; address from getent hosts stby-host.example' "collect.sh ($L): the net record says how the peer was derived"
  hasf lprim.jsonl '{"t":"conn","side":"primary","lip":"198.51.100.11","lport":41000,"pip":"198.51.100.12","pport":1526,"state":"ESTABLISHED","sendq":4320,"recvq":0}' "collect.sh ($L): the primary's connection to the standby listener, with its Send-Q"
  cnt lprim.jsonl '"t":"conn"' 2 "collect.sh ($L): only connections to the peer on that port are listed"
  hasf lprim.jsonl '"t":"lsnr_srv","side":"primary","ts":"2026-11-14 00:05:55","host":"stby-host.example","ip":"198.51.100.12","port":50123,"svc":"proddb","code":"0"' "collect.sh ($L): the standby's connection to the primary listener"
  has errL2 'make_report.sh -o report.html lprim.jsonl lstby.jsonl' "collect.sh ($L): after a primary run it prints the make_report command with both bundles"
  has errL2 'Next, build the report' "collect.sh ($L): ... and says where to run it"

  # an explicit -p and -P win over what could be derived
  newstate
  STUB_MODE=peer STUB_SIDE=primary SQLPLUS=$W/sqlplus $CL "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -p 192.0.2.99 -P 1600 -o lprim2.jsonl 2> errL3
  hasf lprim2.jsonl '"t":"net","side":"primary","peer":"192.0.2.99","port":"1600"' "collect.sh ($L): -p and -P win"
  hasf lprim2.jsonl '"via":"option -p"' "collect.sh ($L): the net record says the peer came from -p"
  has errL3 'make_report.sh -o report.html lprim2.jsonl <the standby bundle>' "collect.sh ($L): without -c the make_report hint says the standby bundle is optional"

  newstate
  STUB_MODE=peer STUB_SIDE=primary SQLPLUS=$W/sqlplus $CL "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -p 192.0.2.99 -o lprim3.jsonl 2> /dev/null
  hasf lprim3.jsonl '"t":"net","side":"primary","peer":"192.0.2.99","port":"1526"' "collect.sh ($L): -p alone keeps the port of the destination descriptor"

  # -N: passive, no live network check: neither ping nor netstat runs, both cov records say why; sar is still read
  newstate; : > "$W/calls.N"
  STUB_CALLS=$W/calls.N STUB_MODE=peer STUB_SIDE=primary SQLPLUS=$W/sqlplus $CL "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -N -t trace -l listener_primary.log -p 192.0.2.99 -o lprimN.jsonl 2> /dev/null
  nof lprimN.jsonl '"t":"net"' "collect.sh ($L): -N writes no net record"
  nof lprimN.jsonl '"t":"conn"' "collect.sh ($L): -N writes no conn records"
  covis lprimN.jsonl net "" skipped "collect.sh ($L): -N: the net cov record is skipped"
  covis lprimN.jsonl conn "" skipped "collect.sh ($L): -N: the conn cov record is skipped"
  hasf lprimN.jsonl 'not requested: -N' "collect.sh ($L): -N: the cov records give the reason"
  if grep -qE '^(ping|netstat) ' "$W/calls.N"; then fail "collect.sh ($L): -N runs no ping or netstat" "$(grep -E '^(ping|netstat) ' "$W/calls.N" | head -3)"; else pass "collect.sh ($L): -N runs no ping or netstat"; fi
  hasf "$W/calls.N" 'sar -n' "collect.sh ($L): -N still reads the sysstat history"

  # AIX: no sar history, no getent; ntpq -p and `no -a` instead; the AIX netstat format
  newstate
  STUB_OS=AIX STUB_MODE=peer STUB_SIDE=standby SQLPLUS=$W/sqlplus env PATH=$W/host.aix/bin DGR_NOW=$NOWT STUB_STATE=$W/state TNS_ADMIN=$D/netadmin STUB_LSNR_LOG=$D/lsnrdiag/alert/log.xml "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -o astby.jsonl 2> errA1
  fmt "collect.sh ($L): AIX standby bundle" astby.jsonl allow-ora
  hasf astby.jsonl '"src":"sar","kind":"ETCP","st":"skipped"' "collect.sh ($L): AIX: sar reports are skipped, one record each"
  hasf astby.jsonl 'AIX has no network history by default' "collect.sh ($L): ... with the reason"
  nof astby.jsonl '"t":"sar"' "collect.sh ($L): AIX: no sar rows"
  hasf astby.jsonl '"t":"ntp","side":"standby","tool":"ntpq -p","ref":"ntp1.example.net","stratum":1,"off":-0.000034000,"synced":"yes"' "collect.sh ($L): ntpq -p: the system peer (*), stratum and the offset with the sign turned to system minus reference"
  hasf astby.jsonl '"name":"tcp_keepidle","value":"14400","tool":"no -a"' "collect.sh ($L): AIX: no -a tunables"
  cnt astby.jsonl '"t":"ostcp"' 8 "collect.sh ($L): AIX: the same tunables os_net_check.sh reads, nothing else"
  hasf astby.jsonl '"t":"conn","side":"standby","lip":"198.51.100.12","lport":1526,"pip":"198.51.100.11","pport":33001,"state":"ESTABLISHED"' "collect.sh ($L): AIX netstat -an: addresses with the port after the last dot"
  hasf astby.jsonl '"ip":null,"ip_how":null' "collect.sh ($L): AIX: no getent, the host name stays unresolved"
  hasf astby.jsonl 'getent not found: host name not resolved' "collect.sh ($L): ... and the endpoint note says so"
  hasf astby.jsonl '"rtt":"0","loss":"0%"' "collect.sh ($L): AIX ping output"
  newstate
  STUB_OS=AIX STUB_NTPQ=none SQLPLUS=$NOSQL env PATH=$W/host.aix/bin DGR_NOW=$NOWT STUB_STATE=$W/state "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -a /nonexistent -t nodir -l nosuch.log -o antp.jsonl 2> errA2
  hasf antp.jsonl '"tool":"ntpq -p","ref":null,"stratum":null,"off":null,"synced":"no"' "collect.sh ($L): ntpq with no system peer (no *) is not synchronised"
  SQLPLUS=$NOSQL STUB_OS=AIX env PATH=$W/host.aixlssrc/bin DGR_NOW=$NOWT "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -a /nonexistent -t nodir -l nosuch.log -o alssrc.jsonl 2> errA3
  hasf alssrc.jsonl '"tool":"lssrc -s xntpd","ref":null,"stratum":null,"off":null,"synced":null' "collect.sh ($L): AIX without ntpq: lssrc gives the service state only, synchronisation unknown"

  # clock state: the order of the tools, a failing one, nothing at all
  for v in "chrony STUB_CHRONY=unsync" "chronyntp STUB_CHRONY=down" "ntponly STUB_NTPQ=ok" "tdonly STUB_NTPQ=ok" "bare STUB_NTPQ=ok" "chrony STUB_CHRONY=down"; do
    set -- $v; hn=$1; shift
    SQLPLUS=$NOSQL env PATH=$W/host.$hn/bin DGR_NOW=$NOWT "$@" "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -a /nonexistent -t nodir -l nosuch.log -o ntp_$hn.$1.jsonl 2> /dev/null
  done
  hasf ntp_chrony.STUB_CHRONY=unsync.jsonl '"tool":"chronyc tracking","ref":null,"stratum":0,"off":null,"synced":"no"' "collect.sh ($L): chronyc: not synchronised (leap status), no source"
  hasf ntp_chronyntp.STUB_CHRONY=down.jsonl '"tool":"ntpq -p","ref":"ntp1.example.net"' "collect.sh ($L): chronyc that cannot talk to its daemon: falls back to ntpq"
  hasf ntp_ntponly.STUB_NTPQ=ok.jsonl '"tool":"ntpq -p"' "collect.sh ($L): a host with only ntpq"
  hasf ntp_tdonly.STUB_NTPQ=ok.jsonl '"tool":"timedatectl","ref":null,"stratum":null,"off":null,"synced":"yes"' "collect.sh ($L): a host with only timedatectl: the synchronized flag only"
  hasf ntp_bare.STUB_NTPQ=ok.jsonl '"src":"ntp","st":"skipped"' "collect.sh ($L): a host with no clock tool: the ntp cov record is skipped"
  hasf ntp_bare.STUB_NTPQ=ok.jsonl 'chronyc not found; ntpq not found; timedatectl not found' "collect.sh ($L): ... and names what was tried"
  hasf ntp_chrony.STUB_CHRONY=down.jsonl 'chronyc gave no tracking data; ntpq not found; timedatectl not found' "collect.sh ($L): a failing chronyc and nothing else: the note says both"
  nof ntp_bare.STUB_NTPQ=ok.jsonl '"t":"ntp"' "collect.sh ($L): ... and no ntp record"

  # tools missing: everything degrades to a skipped cov record, nothing fails
  hasf standby.jsonl '"src":"ep","st":"skipped"' "collect.sh ($L): bare host: no endpoint aliases known"
  hasf standby.jsonl '"src":"conn","st":"skipped"' "collect.sh ($L): bare host: no peer, no connection list"
  hasf standby.jsonl '"src":"ostcp","st":"skipped"' "collect.sh ($L): bare host: no tunables (no sysctl)"
  hasf standby.jsonl '"src":"sar","kind":"DEV","st":"skipped"' "collect.sh ($L): bare host: sar not found"
  hasf standby.jsonl 'sar not found (sysstat is not installed)' "collect.sh ($L): ... says why"
  hasf standby.jsonl '"src":"sqlnet","st":"skipped"' "collect.sh ($L): neither TNS_ADMIN nor ORACLE_HOME: sqlnet.ora not located"
  hasf standby.jsonl '"src":"netsamp","st":"skipped","first":null,"last":null,"n":0,"cap":5000,"capped":false,"note":"option -n not given"' "collect.sh ($L): no sampler log given"
  newstate
  SQLPLUS=$NOSQL env PATH=$W/host.nosar/bin DGR_NOW=$NOWT STUB_STATE=$W/state STUB_SIDE=standby "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -p 198.51.100.11 -P 1526 -a /nonexistent -t nodir -l nosuch.log -o nosar.jsonl 2> errN
  hasf nosar.jsonl '"t":"net","side":"standby","peer":"198.51.100.11","port":"1526"' "collect.sh ($L): ping and netstat alone are enough for the network check (-p given)"
  hasf nosar.jsonl '"src":"ntp","st":"skipped"' "collect.sh ($L): ... without a clock tool the rest still runs"

  # the arguments of the SQL: from, to, history days, baseline days, then the bundle file last
  STUB_ARGS=$D/sqlargs STUB_MODE=meta SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -d 12 -b 3 -t nodir -a /nonexistent -l nosuch.log -o args.jsonl 2> /dev/null
  has sqlargs '@.*json_primary.sql 2026-11-13 23:50:00 2026-11-14 00:10:00 12 3 args.jsonl$' "collect.sh ($L): the primary SQL gets the window, -d, -b and the bundle file last"
  STUB_ARGS=$D/sqlargs2 STUB_MODE=meta SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t nodir -a /nonexistent -l nosuch.log -o args2.jsonl 2> /dev/null
  has sqlargs2 '@.*json_standby.sql 2026-11-13 23:50:00 2026-11-14 00:10:00 30 7 args2.jsonl$' "collect.sh ($L): defaults: 30 days of history and a 7 day baseline"
  for bad in "-b 40" "-b x" "-d abc" "-P 80x"; do
    $CB "$SH" "$R/sh/collect.sh" $bad primary "$WIN1" "$WIN2" -o /dev/null > /dev/null 2> badopt.err; rc=$?
    if [ $rc = 1 ] && [ -s badopt.err ]; then pass "collect.sh ($L): $bad is refused with a message"; else fail "collect.sh ($L): $bad: exit $rc"; fi
  done

  # the text-file history honours -d: with DGR_NOW 2026-11-20 12:00 and -d 9 the cutoff is 2026-11-11 12:00
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -l listener.log -d 9 -o dgd.jsonl 2> /dev/null
  hasf dgd.jsonl '"src":"alhist","kind":"text","st":"ok","first":"2026-11-12 10:00:00"' "collect.sh ($L): -d 9: the history starts at the first line inside the lookback"
  cnt dgd.jsonl '"t":"alhist"' 4 "collect.sh ($L): -d 9: older lines are left out of the history"
  hasf dgd.jsonl 'last 9 days (since 2026-11-11 12:00:00)' "collect.sh ($L): the cov note names the lookback"
  cnt standby.jsonl '"t":"alhist"' 6 "collect.sh ($L): the default lookback (30 days) keeps all six"

  # the routine RT_PMODE lines are not history in the text scan either
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "2026-11-06 20:00" "2026-11-06 21:00" -t nodir -a alert_list.log -l nosuch.log -d 60 -o hist.jsonl 2> /dev/null
  grep '"t":"alhist"' hist.jsonl > hist.alhist
  nof hist.alhist 'RT_PMODE: PRIMARY' "collect.sh ($L): RT_PMODE PRIMARY lines are not in the history"
  nof hist.alhist 'RT_PMODE: PHYSICAL' "collect.sh ($L): RT_PMODE PHYSICAL lines are not in the history"
  nof hist.alhist 'reason ASYNC configuration' "collect.sh ($L): \"reason ASYNC configuration\" is not in the history"
  hasf hist.alhist 'ORA-16198: Timeout incurred on internal channel' "collect.sh ($L): an incident line is"

  # ---------------------------------------------------------------- the newer statements: lfs_by, wl_hist, alsync (and alhist) and act (rman, job, logsw) with their coverage records
  # no sqlplus, or a sqlplus that cannot connect: every source the SQL would have written is skipped, with the reason and its cap (the files of the first tests above)
  covis primary.jsonl lfs_by "" skipped "collect.sh ($L): no sqlplus: lfs_by is skipped on the primary"
  covis primary.jsonl aas "" skipped "collect.sh ($L): no sqlplus: aas is skipped on the primary"
  covis primary.jsonl wl_hist "" skipped "collect.sh ($L): no sqlplus: wl_hist is skipped on the primary"
  covis primary.jsonl alsync sql skipped "collect.sh ($L): no sqlplus: alsync (sql) is skipped on the primary"
  for k in rman job logsw; do covis primary.jsonl act $k skipped "collect.sh ($L): no sqlplus: act $k is skipped on the primary"; done
  hasf primary.jsonl '"src":"lfs_by","st":"skipped","first":null,"last":null,"n":0,"cap":15,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... lfs_by with cap 15 and the reason"
  hasf primary.jsonl '"src":"aas","st":"skipped","first":null,"last":null,"n":0,"cap":12,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... aas with cap 12 and the reason"
  hasf primary.jsonl '"src":"wl_hist","st":"skipped","first":null,"last":null,"n":0,"cap":1500,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... wl_hist with cap 1500"
  hasf primary.jsonl '"src":"alsync","kind":"sql","st":"skipped","first":null,"last":null,"n":0,"cap":300,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... alsync with cap 300 and kind sql"
  hasf primary.jsonl '"src":"act","kind":"rman","st":"skipped","first":null,"last":null,"n":0,"cap":500,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... act rman with cap 500"
  hasf primary.jsonl '"src":"act","kind":"job","st":"skipped","first":null,"last":null,"n":0,"cap":2000,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... act job with cap 2000"
  hasf primary.jsonl '"src":"act","kind":"logsw","st":"skipped","first":null,"last":null,"n":0,"cap":5000,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): ... act logsw with cap 5000"
  cnt primary.jsonl '"src":"alsync"' 1 "collect.sh ($L): a primary without -a has the sql kind of alsync only"
  hasf standby.jsonl '"src":"act","kind":"rman","st":"skipped","first":null,"last":null,"n":0,"cap":500,"capped":false,"note":"sqlplus not found"' "collect.sh ($L): no sqlplus on the standby: act rman is skipped with the reason"
  for k in job logsw; do hasf standby.jsonl "\"src\":\"act\",\"kind\":\"$k\",\"st\":\"skipped\",\"first\":null,\"last\":null,\"n\":0,\"cap\":null,\"capped\":false,\"note\":\"not collected on the standby\"" "collect.sh ($L): standby: act $k is never collected there"; done
  for src in lfs_by aas wl_hist; do hasf standby.jsonl "\"src\":\"$src\",\"st\":\"skipped\",\"first\":null,\"last\":null,\"n\":0,\"cap\":null,\"capped\":false,\"note\":\"not collected on the standby\"" "collect.sh ($L): standby: $src is never collected there"; done
  cnt standby.jsonl '"src":"alsync"' 1 "collect.sh ($L): the standby has alsync as kind text only"
  covis standby.jsonl alsync text ok "collect.sh ($L): ... read from the text alert log"
  cnt standby.jsonl '"t":"alsync"' 1 "collect.sh ($L): the sync line of the fixture alert log is an alsync record"
  hasf standby.jsonl '{"t":"alsync","side":"standby","ts":"2026-11-14 00:09:59","msg":"LGWR (PID:4242): LAD:2 is SYNCHRONIZED"}' "collect.sh ($L): ... with its time and the line"
  hasf standby.jsonl '"src":"alsync","kind":"text","st":"ok","first":"2026-11-06 20:38:07","last":"2026-11-14 00:10:01","n":1,"cap":300,"capped":false,"note":"text alert log, last 30 days (since 2026-10-21 12:00:00), newest 300 kept; lines that end an UNSYNCHRONIZED period (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)"' "collect.sh ($L): alsync cov: first, last and note like alhist"
  hasf dbfail.jsonl '"src":"act","kind":"rman","st":"skipped","first":null,"last":null,"n":0,"cap":500,"capped":false,"note":"database: FAILED"' "collect.sh ($L): failed sqlplus: act rman is skipped with 'database: FAILED'"
  covis dbfail.jsonl alsync text ok "collect.sh ($L): ... the text alsync is still read"
  # a statement that wrote nothing (STUB_MODE=meta writes the meta line and one cov record, then ORA-00942): error cov records with the first Oracle error, the meta line stays
  hasf dbpart.jsonl '"src":"lfs_by","st":"error","first":null,"last":null,"n":0,"cap":15,"capped":false,"note":"no coverage record: ORA-00942: table or view does not exist"' "collect.sh ($L): a statement that failed: lfs_by is an error cov record with the Oracle error"
  hasf dbpart.jsonl '"src":"aas","st":"error","first":null,"last":null,"n":0,"cap":12,"capped":false,"note":"no coverage record: ORA-00942: table or view does not exist"' "collect.sh ($L): ... aas, with its cap of 12"
  hasf dbpart.jsonl '"src":"wl_hist","st":"error","first":null,"last":null,"n":0,"cap":1500,"capped":false,"note":"no coverage record: ORA-00942' "collect.sh ($L): ... wl_hist"
  hasf dbpart.jsonl '"src":"alsync","kind":"sql","st":"error","first":null,"last":null,"n":0,"cap":300,"capped":false,"note":"no coverage record: ORA-00942' "collect.sh ($L): ... alsync (sql)"
  for pair in 'rman 500' 'job 2000' 'logsw 5000'; do
    set -- $pair; hasf dbpart.jsonl "\"src\":\"act\",\"kind\":\"$1\",\"st\":\"error\",\"first\":null,\"last\":null,\"n\":0,\"cap\":$2,\"capped\":false,\"note\":\"no coverage record: ORA-00942" "collect.sh ($L): ... act $1 (looked up by source and kind)"
  done
  hasf dbpart.jsonl '"src":"alsync","kind":"text","st":"skipped","first":null,"last":null,"n":0,"cap":300,"capped":false,"note":"alert log not readable: nosuch.log"' "collect.sh ($L): an unreadable alert log skips the text alsync as it does alhist"
  cnt dbpart.jsonl '"t":"meta"' 1 "collect.sh ($L): ... and the meta line is still there"
  covis dbpart.jsonl database "" ok "collect.sh ($L): ... and the database cov record says ok"

  # STUB_MODE=full: the stub writes what the new statements write (shapes of sql/json_primary.sql and sql/json_standby.sql); collect.sh keeps it and adds nothing for those sources
  STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -o fullp.jsonl 2> errF1
  has errF1 'database: done' "collect.sh ($L): the full stub: database: done"
  # the Coverage list the run prints: one line per cov record, src/kind where the record has a kind (the three act sources and the four sar sources are not the same line four times)
  for k in act/rman act/job act/logsw ash/V alhist/sql alsync/sql sar/ETCP sar/TCP sar/DEV sar/EDEV; do has errF1 "^  $k  *[a-z]*  *[0-9]*" "collect.sh ($L): the coverage list at the end has a line for $k"; done
  for k in lfs_by aas wl_hist database trace; do has errF1 "^  $k  *[a-z]*  *[0-9]*" "collect.sh ($L): ... and a line for $k, which has no kind, under its own name"; done
  [ "$(grep -c '^  act/' errF1)" = 3 ] && pass "collect.sh ($L): ... three act lines, told apart" || fail "collect.sh ($L): the act lines of the coverage list" "$(grep '^  act' errF1)"
  fmt "collect.sh ($L): primary bundle with the records of every newer statement" fullp.jsonl allow-ora
  cnt fullp.jsonl '"t":"meta"' 1 "collect.sh ($L): the full stub: one meta line"
  cnt fullp.jsonl '"t":"lfs_by"' 7 "collect.sh ($L): the seven lfs_by records of the statement are kept"
  for d in service module machine; do hasf fullp.jsonl "\"t\":\"lfs_by\",\"side\":\"primary\",\"dim\":\"$d\"" "collect.sh ($L): lfs_by: the $d list is there"; done
  hasf fullp.jsonl '"dim":"module","name":null,' "collect.sh ($L): lfs_by: a module that is null is kept as null"
  hasf fullp.jsonl '"src":"lfs_by","st":"ok","first":"2026-11-13 20:00:00","last":"2026-11-14 00:40:00","n":7,"cap":15,"capped":false' "collect.sh ($L): lfs_by cov record: what ASH holds, groups found, cap 15"
  cnt fullp.jsonl '"t":"aas"' 6 "collect.sh ($L): the six aas records of the statement are kept"
  hasf fullp.jsonl '{"t":"aas","m":"2026-11-13 23:51","ev":"log file sync","wc":"Commit","fg":87,"bg":0}' "collect.sh ($L): aas: minute, event, wait class, foreground and background samples"
  hasf fullp.jsonl '{"t":"aas","m":"2026-11-13 23:51","ev":null,"wc":null,"fg":6,"bg":2}' "collect.sh ($L): aas: the events beyond the twelfth are one record per minute with ev and wc null, kept as null"
  hasf fullp.jsonl '"src":"aas","st":"ok","first":"2026-11-13 20:00:00","last":"2026-11-14 00:40:00","n":14,"cap":12,"capped":true' "collect.sh ($L): aas cov record: what ASH holds, events found, cap 12, capped when more were found"
  cnt fullp.jsonl '"t":"wl_hist"' 3 "collect.sh ($L): the three wl_hist records are kept"
  hasf fullp.jsonl '{"t":"wl_hist","side":"primary","b":"2026-11-13 21:00","e":"2026-11-13 22:00","redo":0.812,"redo_max":3.455,"txn":41.5}' "collect.sh ($L): wl_hist: interval to the minute, redo, largest minute, transactions"
  hasf fullp.jsonl '"redo":null,"redo_max":null,"txn":null}' "collect.sh ($L): wl_hist: an interval without values keeps its nulls"
  hasf fullp.jsonl '"src":"wl_hist","st":"ok","first":"2026-10-21 10:00:00","last":"2026-11-14 00:00:00","n":3,"cap":1500,"capped":false' "collect.sh ($L): wl_hist cov record: the span the view holds, intervals in the lookback, cap 1500"
  cnt fullp.jsonl '"t":"alsync"' 2 "collect.sh ($L): the two alsync records of the statement are kept"
  hasf fullp.jsonl '{"t":"alsync","side":"primary","ts":"2026-11-14 00:09:59","msg":"LGWR (PID:4242): LAD:2 is SYNCHRONIZED"}' "collect.sh ($L): alsync: time and line"
  hasf fullp.jsonl '"src":"alsync","kind":"sql","st":"ok","first":"2026-10-21 12:00:01","last":"2026-11-19 09:00:00","n":2,"cap":300,"capped":false' "collect.sh ($L): alsync cov record: kind sql, cap 300"
  cnt fullp.jsonl '"src":"alsync"' 1 "collect.sh ($L): a primary without -a has no text kind of alsync"
  cnt fullp.jsonl '"t":"act","side":"primary","kind":"rman"' 2 "collect.sh ($L): the two act rman records are kept"
  hasf fullp.jsonl '"name":"DELETE OBSOLETE","a":"2026-11-14 00:02:15","z":null,"st":"RUNNING"}' "collect.sh ($L): act rman: a command that is still running has no end"
  hasf fullp.jsonl '"src":"act","kind":"rman","st":"ok","first":"2026-10-21 22:00:00","last":"2026-11-14 00:02:15","n":2,"cap":500,"capped":false' "collect.sh ($L): act rman cov record, cap 500"
  cnt fullp.jsonl '"t":"act","side":"primary","kind":"job"' 2 "collect.sh ($L): the two act job records are kept"
  hasf fullp.jsonl '"name":"APP.QUEUE_POLL","con":3,"a":"2026-10-21 12:00:05","z":"2026-11-20 11:59:05","st":null,"freq":true,"n":43200}' "collect.sh ($L): act job: a frequent job is one summary record (freq true, n runs)"
  hasf fullp.jsonl '"src":"act","kind":"job","st":"ok","first":"2026-10-21 12:00:05","last":"2026-11-20 11:59:05","n":43201,"cap":2000,"capped":false' "collect.sh ($L): act job cov record, cap 2000"
  cnt fullp.jsonl '"t":"act","side":"primary","kind":"logsw"' 3 "collect.sh ($L): the three act logsw records are kept"
  hasf fullp.jsonl '{"t":"act","side":"primary","kind":"logsw","a":"2026-11-13 23:41:02","thr":1,"seq":114489}' "collect.sh ($L): act logsw: time, thread and sequence"
  hasf fullp.jsonl '"src":"act","kind":"logsw","st":"ok","first":"2026-10-21 12:30:00","last":"2026-11-14 00:00:30","n":3,"cap":5000,"capped":false' "collect.sh ($L): act logsw cov record, cap 5000"
  for src in lfs_by aas wl_hist; do cnt fullp.jsonl "\"src\":\"$src\"" 1 "collect.sh ($L): one cov record for $src, the stub's"; done
  for k in rman job logsw; do cnt fullp.jsonl "\"src\":\"act\",\"kind\":\"$k\"" 1 "collect.sh ($L): one cov record for act $k, the stub's"; done

  # the statement of one act kind failed before its cov statement: only that kind is an error, the other kinds and all other records stay
  STUB_OMIT=act:job STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -o fullo1.jsonl 2> /dev/null
  covis fullo1.jsonl act job error "collect.sh ($L): act:job missing: its cov record is an error one"
  covis fullo1.jsonl act rman ok "collect.sh ($L): ... act rman is still ok"
  covis fullo1.jsonl act logsw ok "collect.sh ($L): ... and act logsw"
  hasf fullo1.jsonl '"src":"act","kind":"job","st":"error","first":null,"last":null,"n":0,"cap":2000,"capped":false,"note":"no coverage record: ORA-00942: table or view does not exist"' "collect.sh ($L): ... the error record has the cap and the first Oracle error"
  cnt fullo1.jsonl '"t":"act","side":"primary","kind":"job"' 0 "collect.sh ($L): ... no act job records"
  cnt fullo1.jsonl '"t":"act","side":"primary","kind":"rman"' 2 "collect.sh ($L): ... the act rman records are kept"
  cnt fullo1.jsonl '"t":"lfs_by"' 7 "collect.sh ($L): ... and the other new records"
  cnt fullo1.jsonl '"t":"aas"' 6 "collect.sh ($L): ... aas among them"
  cnt fullo1.jsonl '"t":"meta"' 1 "collect.sh ($L): ... and the meta line"
  fmt "collect.sh ($L): bundle with act job missing" fullo1.jsonl allow-ora
  # the other sources, omitted together
  STUB_OMIT="lfs_by aas wl_hist alsync alhist act:rman act:logsw" STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -o fullo2.jsonl 2> /dev/null
  for pair in 'lfs_by 15' 'aas 12' 'wl_hist 1500'; do
    set -- $pair; hasf fullo2.jsonl "\"src\":\"$1\",\"st\":\"error\",\"first\":null,\"last\":null,\"n\":0,\"cap\":$2,\"capped\":false,\"note\":\"no coverage record: ORA-00942" "collect.sh ($L): $1 missing: an error cov record with its cap"
  done
  hasf fullo2.jsonl '"src":"alsync","kind":"sql","st":"error","first":null,"last":null,"n":0,"cap":300,"capped":false,"note":"no coverage record: ORA-00942' "collect.sh ($L): alsync missing: an error cov record of kind sql"
  hasf fullo2.jsonl '"src":"alhist","kind":"sql","st":"error"' "collect.sh ($L): alhist missing: an error cov record of kind sql"
  covis fullo2.jsonl act rman error "collect.sh ($L): act rman missing: error"
  covis fullo2.jsonl act logsw error "collect.sh ($L): act logsw missing: error"
  covis fullo2.jsonl act job ok "collect.sh ($L): ... act job, which the stub wrote, stays ok"
  n=$(grep -cE '"t":"(lfs_by|aas|wl_hist|alsync|alhist)"' fullo2.jsonl); if [ "$n" = 0 ]; then pass "collect.sh ($L): the omitted sources have no records"; else fail "collect.sh ($L): $n records of omitted sources"; fi
  fmt "collect.sh ($L): bundle with six sources missing" fullo2.jsonl allow-ora
  # the count statement failed: the SQL writes the error cov record itself (n 0, no first or last, the statement named in the note) and no records
  STUB_ERR="wl_hist aas act:rman" STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t trace -l listener_primary.log -o fullerr.jsonl 2> errF2
  has errF2 '^  act/rman  *error  *0' "collect.sh ($L): the coverage list at the end shows which act source failed: act/rman error"
  has errF2 '^  act/job  *ok  *43201' "collect.sh ($L): ... while act/job, which did not, is ok"
  has errF2 '^  ORA-00942: table or view does not exist' "collect.sh ($L): the queries that reported errors are listed by their ORA- line"
  nof errF2 'ERROR at line' "collect.sh ($L): ... without the ERROR at line N: lines that only say where"
  cnt fullerr.jsonl '"src":"wl_hist"' 1 "collect.sh ($L): a failed count statement: one wl_hist cov record, the SQL's; collect.sh adds none"
  cnt fullerr.jsonl '"src":"aas"' 1 "collect.sh ($L): ... one aas cov record, the SQL's, and no records"
  hasf fullerr.jsonl '"src":"aas","st":"error","first":null,"last":null,"n":0,"cap":12,"capped":false,"note":"the statement over ASH failed"' "collect.sh ($L): ... the aas error record has its cap of 12 and the note of the SQL"
  cnt fullerr.jsonl '"t":"aas"' 0 "collect.sh ($L): ... no aas records"
  cnt fullerr.jsonl '"src":"act","kind":"rman"' 1 "collect.sh ($L): ... and one for act rman"
  hasf fullerr.jsonl '"src":"wl_hist","st":"error","first":null,"last":null,"n":0,"cap":1500,"capped":false,"note":"the dba_hist_sysmetric_summary statement failed"' "collect.sh ($L): ... the wl_hist error record keeps the note of the SQL"
  hasf fullerr.jsonl '"src":"act","kind":"rman","st":"error","first":null,"last":null,"n":0,"cap":500,"capped":false,"note":"the v$rman_status statement failed"' "collect.sh ($L): ... and so does act rman"
  cnt fullerr.jsonl '"t":"wl_hist"' 0 "collect.sh ($L): ... no wl_hist records"
  cnt fullerr.jsonl '"t":"act","side":"primary","kind":"rman"' 0 "collect.sh ($L): ... no act rman records"
  cnt fullerr.jsonl '"t":"act","side":"primary","kind":"job"' 2 "collect.sh ($L): ... the other act kinds are kept"
  fmt "collect.sh ($L): bundle with failed count statements" fullerr.jsonl allow-ora

  # the standby: act rman is read (v$rman_status works on a mounted database), the rest of the new sources are skipped
  STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -l listener.log -o fulls.jsonl 2> /dev/null
  fmt "collect.sh ($L): standby bundle with the full stub" fulls.jsonl allow-ora
  covis fulls.jsonl act rman ok "collect.sh ($L): standby: act rman is collected"
  cnt fulls.jsonl '"t":"act","side":"standby","kind":"rman"' 1 "collect.sh ($L): ... its record is kept"
  hasf fulls.jsonl '"src":"act","kind":"rman","st":"ok","first":"2026-11-01 23:30:00","last":"2026-11-13 23:30:00","n":1,"cap":500,"capped":false' "collect.sh ($L): ... with its cov record"
  for k in job logsw; do covis fulls.jsonl act $k skipped "collect.sh ($L): standby: act $k is skipped"; done
  for src in lfs_by aas wl_hist; do covis fulls.jsonl $src "" skipped "collect.sh ($L): standby: $src is skipped"; done
  n=$(grep -cE '"t":"(lfs_by|aas|wl_hist)"|"t":"act","side":"standby","kind":"(job|logsw)"' fulls.jsonl); if [ "$n" = 0 ]; then pass "collect.sh ($L): standby: no records of the primary-only sources"; else fail "collect.sh ($L): standby: $n records of the primary-only sources"; fi
  cnt fulls.jsonl '"src":"alsync"' 1 "collect.sh ($L): standby: one alsync cov record"
  cnt fulls.jsonl '"src":"alhist"' 1 "collect.sh ($L): standby: one alhist cov record"
  covis fulls.jsonl alsync text ok "collect.sh ($L): ... of kind text"
  STUB_OMIT=act:rman STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t trace -a alert_cdb1.log -l listener.log -o fullso.jsonl 2> /dev/null
  hasf fullso.jsonl '"src":"act","kind":"rman","st":"error","first":null,"last":null,"n":0,"cap":500,"capped":false,"note":"no coverage record: ORA-00942' "collect.sh ($L): standby: act rman missing is an error cov record"
  covis fullso.jsonl act job skipped "collect.sh ($L): ... and act job stays skipped"

  # the text alert log (the standby always, the primary with -a): alsync records are written in the pass that writes alhist
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t nodir -a alert_sync.log -l nosuch.log -o sync.jsonl 2> /dev/null
  cnt sync.jsonl '"t":"alsync"' 3 "collect.sh ($L): text alert log: three lines end an UNSYNCHRONIZED period"
  hasf sync.jsonl '{"t":"alsync","side":"standby","ts":"2026-11-06 20:53:27","msg":"LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level SYNCHRONIZED  "}' "collect.sh ($L): alsync: LAD:n ... level SYNCHRONIZED is one"
  nof sync.jsonl 'LAD:3 is SYNCHRONIZED' "collect.sh ($L): alsync: a second sync line in the same second is not a record of its own"
  nof sync.jsonl 'RT_PMODE: PRIMARY' "collect.sh ($L): alsync: the PRIMARY ... level SYNCHRONIZED line is not one"
  nof sync.jsonl '"ts":"2026-10-05' "collect.sh ($L): alsync: a line before the lookback is left out"
  hasf sync.jsonl '{"t":"alsync","side":"standby","ts":"2026-11-12 10:00:00","msg":"LGWR (PID:4242): LAD:2 is SYNCHRONIZED"}' "collect.sh ($L): alsync: a sync line in the same second as a history line is kept (its own last-second variable)"
  hasf sync.jsonl '{"t":"alhist","side":"standby","ts":"2026-11-12 10:00:00","msg":"ORA-03135: connection lost contact"}' "collect.sh ($L): ... and so is the history line"
  cnt sync.jsonl '"t":"alhist"' 2 "collect.sh ($L): alhist: two history lines, the one with a sync pattern among them"
  hasf sync.jsonl '{"t":"alhist","side":"standby","ts":"2026-11-10 03:00:00","msg":"LGWR (PID:4242): ORA-16198 while LAD:2 is SYNCHRONIZED again"}' "collect.sh ($L): a line that is both a history line and a sync line is an alhist record"
  nof sync.jsonl '"t":"alsync","side":"standby","ts":"2026-11-10 03:00:00"' "collect.sh ($L): ... and not an alsync record"
  l=$(grep '"t":"alsync"' sync.jsonl | awk -F'"msg":"' 'NR == 3 { s = $2; sub(/"}$/, "", s); print length(s) }')
  if [ "$l" = 200 ]; then pass "collect.sh ($L): an alsync message is cut to 200 characters"; else fail "collect.sh ($L): the long alsync message has $l characters, want 200"; fi
  hasf sync.jsonl '"src":"alsync","kind":"text","st":"ok","first":"2026-11-06 20:53:27","last":"2026-11-14 00:00:00","n":3,"cap":300,"capped":false,"note":"text alert log, last 30 days (since 2026-10-21 12:00:00), newest 300 kept; lines that end an UNSYNCHRONIZED period (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)"' "collect.sh ($L): alsync cov record: the history's first line, the last line of the file, three found"
  hasf sync.jsonl '"src":"alhist","kind":"text","st":"ok","first":"2026-11-06 20:53:27","last":"2026-11-14 00:00:00","n":2,"cap":300,"capped":false' "collect.sh ($L): ... the alhist cov record has the same span"
  fmt "collect.sh ($L): bundle of the text alert log with sync lines" sync.jsonl allow-ora
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" standby "$WIN1" "$WIN2" -t nodir -a alert_sync.log -l nosuch.log -d 9 -o sync9.jsonl 2> /dev/null
  cnt sync9.jsonl '"t":"alsync"' 2 "collect.sh ($L): -d 9: only the sync lines inside the lookback are kept"
  nof sync9.jsonl '"t":"alsync","side":"standby","ts":"2026-11-06' "collect.sh ($L): ... the one of 2026-11-06 is left out"
  hasf sync9.jsonl 'last 9 days (since 2026-11-11 12:00:00), newest 300 kept; lines that end an UNSYNCHRONIZED period' "collect.sh ($L): ... and the alsync note names the lookback"
  # a primary with -a: the history and the sync lines come from both, SQL and text alert log, each with its own cov record
  STUB_MODE=full SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" primary "$WIN1" "$WIN2" -t nodir -a alert_sync.log -l nosuch.log -o fullpa.jsonl 2> /dev/null
  for src in alhist alsync; do for k in sql text; do covis fullpa.jsonl $src $k ok "collect.sh ($L): primary with -a: $src has a cov record of kind $k"; done; done
  cnt fullpa.jsonl '"t":"alsync"' 5 "collect.sh ($L): ... two alsync records from the SQL and three from the text log"
  cnt fullpa.jsonl '"t":"alhist"' 4 "collect.sh ($L): ... two alhist records from the SQL and two from the text log"
  fmt "collect.sh ($L): primary bundle with -a and the full stub" fullpa.jsonl allow-ora

  # ---------------------------------------------------------------- collect.sh list
  printf '2026-11-06 20:38:07\tI\tLGWR (PID:4242): ORA-16198: Received timed out error from KSR\n2026-11-06 20:38:07\tI\tLGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED reason no connection\n2026-11-06 20:43:12\tI\tORA-16198: Timeout incurred on internal channel during remote archival\n2026-11-06 20:53:27\tS\tLGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level SYNCHRONIZED\n2026-11-13 23:58:19\tI\tLGWR (PID:4242): ORA-16198: Received timed out error from KSR\n2026-11-13 23:58:19\tI\tLGWR (PID:4242): LAD:2 is UNSYNCHRONIZED\n2026-11-14 00:09:59\tS\tLGWR (PID:4242): LAD:2 is SYNCHRONIZED\n2026-11-18 14:00:00\tI\tORA-03135: connection lost contact\n2026-11-18 14:02:10\tI\trfs (PID:4400): Possible network disconnect with primary database\n' > list_sql.txt
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log > list1.out 2> list1.err; echo $? > listrc
  if [ "$(cat listrc)" = 0 ]; then pass "collect.sh list ($L): exit 0"; else fail "collect.sh list ($L): exit $(cat listrc)" "$(cat list1.err)"; fi
  cnt list1.out '^Episode' 3 "collect.sh list ($L): three episodes in the last 30 days (older ones and routine lines are left out)"
  hasf list1.out 'Episode 1: 2026-11-06 20:38:07 to 2026-11-06 20:53:27, 3 lines: ORA-16198; LAD:2 UNSYNCHRONIZED (no connection)' "collect.sh list ($L): an episode: first line, return to synchronized, the lines it holds, what they say"
  hasf list1.out 'back to SYNCHRONIZED at 2026-11-06 20:53:27' "collect.sh list ($L): ... and when the destination came back"
  hasf list1.out 'suggested window: 2026-11-06 20:33 to 2026-11-06 20:59' "collect.sh list ($L): five minutes before the first line, five minutes after the return"
  hasf list1.out "  standby host: sh $R/sh/collect.sh -o dgr_standby_20261106_2033.jsonl standby \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list ($L): the command for the standby"
  hasf list1.out "  primary host: sh $R/sh/collect.sh -c dgr_standby_20261106_2033.jsonl -o dgr_primary_20261106_2033.jsonl primary \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list ($L): the command for the primary names the standby bundle of the first"
  hasf list1.out 'Episode 2: 2026-11-13 23:58:19 to 2026-11-14 00:09:59, 2 lines: ORA-16198; LAD:2 UNSYNCHRONIZED' "collect.sh list ($L): an episode across midnight (the older LAD:n is ... family)"
  hasf list1.out 'suggested window: 2026-11-13 23:53 to 2026-11-14 00:15' "collect.sh list ($L): ... with a window across midnight"
  hasf list1.out 'Episode 3: 2026-11-18 14:00:00 to 2026-11-18 14:02:10, 2 lines: ORA-03135; possible network disconnect (standby)' "collect.sh list ($L): an episode with no return"
  hasf list1.out 'no return to SYNCHRONIZED found in the log' "collect.sh list ($L): ... says so"
  hasf list1.out 'suggested window: 2026-11-18 13:55 to 2026-11-18 14:18' "collect.sh list ($L): ... and ends 15 minutes after the last line"
  grep -E '^Episode|suggested|standby host|primary host' list1.out > list1.eps
  nof list1.eps '2026-11-10' "collect.sh list ($L): a day with only routine RT_PMODE lines is not an incident"
  nof list1.eps '2026-10-21' "collect.sh list ($L): ... neither the routine lines of an older day"
  nof list1.eps '2026-10-05' "collect.sh list ($L): an incident older than -d 30 days is not listed"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log -d 60 > list2.out 2> /dev/null
  cnt list2.out '^Episode' 4 "collect.sh list ($L): -d 60 reaches the October incident"
  hasf list2.out 'Episode 1: 2026-10-05 22:11:05 to 2026-10-05 22:15:40, 2 lines' "collect.sh list ($L): ... as the first episode"
  grep -E '^Episode|suggested' list2.out > list2.eps
  nof list2.eps '2026-10-21' "collect.sh list ($L): ... and still no routine lines"
  STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > list3.out 2> list3.err
  hasf list3.out 'Incidents in the v$diag_alert_ext' "collect.sh list ($L): without -a it reads v\$diag_alert_ext"
  hasf list3.out 'Episode 1: 2026-11-06 20:38:07 to 2026-11-06 20:53:27, 3 lines: ORA-16198; LAD:2 UNSYNCHRONIZED (no connection)' "collect.sh list ($L): ... and groups the rows the same way"
  cnt list3.out '^Episode' 3 "collect.sh list ($L): ... into the same three episodes"
  STUB_MODE=list1219 SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > /dev/null 2> list4.err; echo $? > listrc4
  if [ "$(cat listrc4)" = 1 ]; then pass "collect.sh list ($L): a mounted standby (ORA-01219) exits 1"; else fail "collect.sh list ($L): ORA-01219 exit $(cat listrc4)"; fi
  has list4.err 'ORA-01219' "collect.sh list ($L): ... shows the Oracle error"
  has list4.err '^list: could not read v.diag_alert_ext: ORA-01219: database or pluggable database not open' "collect.sh list ($L): ... the first ORA- line, not the ERROR at line N: line before it"
  nof list4.err 'ERROR at line' "collect.sh list ($L): ... and no ERROR at line N: line"
  has list4.err 'give the text alert log with -a' "collect.sh list ($L): ... and points to -a"
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" list > /dev/null 2> list5.err; echo $? > listrc5
  has list5.err 'sqlplus not found; give the text alert log with -a' "collect.sh list ($L): neither sqlplus nor -a: says what to do"
  printf '2026-11-10T03:00:00.000000+01:00\nLGWR (PID:1): RT_PMODE: PRIMARY            changing to   mode MAXIMUM AVAILABILITY level UNSYNCHRONIZED\n' > routine.log
  $CB "$SH" "$R/sh/collect.sh" list -a routine.log > list6.out 2> /dev/null
  hasf list6.out 'No incidents found.' "collect.sh list ($L): a log with routine lines only: no incidents"
  # a return days after the first line: real return time on its own line, window capped at 30 minutes after the first line, and the next lines are a new episode
  $CB "$SH" "$R/sh/collect.sh" list -a alert_late.log > list7.out 2> /dev/null
  cnt list7.out '^Episode' 2 "collect.sh list ($L): a return days later does not merge the next incident into the episode"
  hasf list7.out 'Episode 1: 2026-11-12 10:11:21 to 2026-11-18 22:53:00, 3 lines: ORA-16198; LAD:2 UNSYNCHRONIZED (no connection)' "collect.sh list ($L): the episode holds the lines close in time"
  hasf list7.out '  back to SYNCHRONIZED at 2026-11-18 22:53:00' "collect.sh list ($L): the real return time is printed on its own line"
  hasf list7.out 'note: 6 d 12 h after the first line; the suggested window was shortened to end 30 minutes after it. Widen its end by hand to cover the whole period.' "collect.sh list ($L): ... with a note that the window was shortened and how late the return was"
  hasf list7.out 'suggested window: 2026-11-12 10:06 to 2026-11-12 10:42' "collect.sh list ($L): the window ends 30 minutes after the first line, not at the return"
  hasf list7.out "  standby host: sh $R/sh/collect.sh -o dgr_standby_20261112_1006.jsonl standby \"2026-11-12 10:06\" \"2026-11-12 10:42\"" "collect.sh list ($L): the commands use the capped window"
  hasf list7.out 'Episode 2: 2026-11-18 22:55:00 to 2026-11-18 22:55:00, 1 line: ORA-03135' "collect.sh list ($L): an incident two minutes after a late return starts its own episode"
  nof list7.out '"2026-11-12 10:06" "2026-11-18' "collect.sh list ($L): no command spans the days up to the late return"
  nof list1.out 'shortened' "collect.sh list ($L): a normal return (within 60 minutes) is not shortened"
  # which sources on this host still hold each episode: one added line per episode (the in-memory ASH, AWR, the sysstat daily file of each day, the alert log); a source that cannot be read is "not checked" with the reason
  mkdir -p sadir_list; : > sadir_list/sa20261106
  env SA_DIR=$D/sadir_list $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log > list8.out 2> /dev/null
  cnt list8.out '^  still held on this host:' 3 "collect.sh list ($L): one line per episode that says which sources on this host still hold it"
  hasf list8.out '  still held on this host: ASH (in memory): not checked (sqlplus not found); AWR: not checked (sqlplus not found); sysstat: 2026-11-06 '"$D"'/sadir_list/sa20261106; alert log: holds the episode (read from text alert log alert_list.log)' "collect.sh list -a ($L): without sqlplus the database sources are 'not checked (sqlplus not found)'; the sysstat file of the day and the alert log are reported"
  hasf list8.out 'sysstat: 2026-11-13 no file in '"$D"'/sadir_list, 2026-11-14 no file in '"$D"'/sadir_list; alert log' "collect.sh list -a ($L): an episode across midnight names each day, and a day with no sysstat file says so"
  grep -v '^  still held on this host' list8.out > list8.base; grep -v '^  still held on this host' list1.out > list1.base
  same "collect.sh list ($L): every other line of the output is unchanged by the added line" list8.base list1.base
  nof list8.out 'ASH (in memory): holds' "collect.sh list -a ($L): without sqlplus it never says what the database sources hold"
  cnt list8.out 'ASH (in memory): not checked (sqlplus not found); AWR: not checked (sqlplus not found);' 3 "collect.sh list -a ($L): without sqlplus the reason is sqlplus not found, not a guess about the connection"
  nof list8.out 'no database connection' "collect.sh list -a ($L): ... and no line claims there is no database connection"
  # -a with sqlplus: the ASH and AWR query runs as without -a (it needs sqlplus, not v$diag_alert_ext); a mounted standby answers ASH and raises ORA-01219 for AWR
  STUB_MODE=listsrcfail SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log > list8c.out 2> /dev/null; echo $? > list8c.rc
  cnt list8c.out 'AWR: not checked (ORA-01219: database or pluggable database not open: queries allowed on fixed tables or views only);' 3 "collect.sh list -a ($L): sqlplus is there: AWR is not checked with the ORA-01219 line (not the ERROR at line N: line above it), in every episode"
  hasf list8c.out 'ASH (in memory): holds none of the window (oldest sample 2026-11-14 03:51:20); AWR: not checked (ORA-01219' "collect.sh list -a ($L): ... and ASH, which answers on a mounted standby, is reported"
  cnt list8c.out '^Episode' 3 "collect.sh list -a ($L): ... the episodes come from the text alert log as before"
  hasf list8c.out 'alert log: holds the episode (read from text alert log alert_list.log)' "collect.sh list -a ($L): ... and the alert log source is still the text file"
  if [ "$(cat list8c.rc)" = 0 ]; then pass "collect.sh list -a ($L): a failed source query does not change the exit status"; else fail "collect.sh list -a ($L): exit $(cat list8c.rc) after a failed source query"; fi
  STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log > list8d.out 2> /dev/null
  hasf list8d.out 'ASH (in memory): holds none of the window (oldest sample 2026-11-14 03:51:20); AWR: holds the whole window (oldest snapshot 2026-10-21 10:00:00);' "collect.sh list -a ($L): both queries answer: the same wording as without -a"
  STUB_MODE=listsrcdown SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log > list8e.out 2> /dev/null
  cnt list8e.out 'ASH (in memory): not checked (ORA-01017: invalid username/password; logon denied); AWR: not checked (ORA-01017: invalid username/password; logon denied);' 3 "collect.sh list -a ($L): sqlplus that cannot connect: the first ORA- line is the reason of both"
  cnt list8e.out '^Episode' 3 "collect.sh list -a ($L): ... and the episodes are still listed"
  grep -v '^  still held on this host' list8c.out > list8c.base
  same "collect.sh list -a ($L): every other line of the output is the same with or without sqlplus" list8c.base list1.base
  newstate
  $CL "$SH" "$R/sh/collect.sh" list -a alert_list.log > list8b.out 2> /dev/null
  hasf list8b.out 'sysstat: 2026-11-13 '"$D"'/sadir/sa13, 2026-11-14 '"$D"'/sadir/sa14 is dated 2026-10-14;' "collect.sh list ($L): a reused saDD file is checked against the date in its banner (sa14 holds 2026-10-14, not 2026-11-14)"
  STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus env SA_DIR=$D/sadir_list $CB "$SH" "$R/sh/collect.sh" list > list9.out 2> /dev/null
  hasf list9.out '  still held on this host: ASH (in memory): holds none of the window (oldest sample 2026-11-14 03:51:20); AWR: holds the whole window (oldest snapshot 2026-10-21 10:00:00); sysstat: 2026-11-06 '"$D"'/sadir_list/sa20261106; alert log: holds the episode (read from v$diag_alert_ext)' "collect.sh list ($L): with sqlplus the oldest ASH sample and AWR snapshot are compared with the window of the episode"
  printf 'SRC:ASH\nASH\t2026-11-06 20:45:00\nSRC:AWR\nAWR\t-\n' > src_part.txt
  STUB_SRC=$D/src_part.txt STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > list10.out 2> /dev/null
  hasf list10.out 'ASH (in memory): holds only the end of the window (oldest sample 2026-11-06 20:45:00); AWR: holds no snapshot;' "collect.sh list ($L): a source that starts inside the window holds only the end of it; an empty AWR holds no snapshot"
  STUB_LIST=$D/list_sql.txt STUB_MODE=listsrcfail SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > list11.out 2> /dev/null; echo $? > list11.rc
  hasf list11.out 'ASH (in memory): holds none of the window (oldest sample 2026-11-14 03:51:20); AWR: not checked (ORA-01219: database or pluggable database not open: queries allowed on fixed tables or views only);' "collect.sh list ($L): a statement that fails is 'not checked' with its Oracle error; the one before it is still reported"
  STUB_LIST=$D/list_sql.txt STUB_MODE=listsrcdown SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > list12.out 2> /dev/null
  hasf list12.out 'ASH (in memory): not checked (ORA-01017: invalid username/password; logon denied); AWR: not checked (ORA-01017: invalid username/password; logon denied);' "collect.sh list ($L): sqlplus that cannot connect for the source query: both are 'not checked' with the error, never a guess"
  cnt list12.out '^Episode' 3 "collect.sh list ($L): ... and the episodes are still listed"
  if [ "$(cat list11.rc)" = 0 ]; then pass "collect.sh list ($L): a failed source query does not change the exit status"; else fail "collect.sh list ($L): exit $(cat list11.rc) after a failed source query"; fi
  STUB_MODE=fail SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > list13.out 2> list13.err; echo $? > list13.rc
  if [ "$(cat list13.rc)" = 1 ] && ! grep -q 'still held' list13.out; then pass "collect.sh list ($L): a failing sqlplus exits 1 as before and prints no sources line"; else fail "collect.sh list ($L): failing sqlplus: exit $(cat list13.rc)" "$(cat list13.out list13.err | head -3)"; fi
  nof list9.out 'sh sh/collect' "collect.sh list ($L): the added line does not look like a command line"
  grep -E '^Episode|suggested|standby host|primary host' list9.out > list9.eps
  nof list9.eps 'still held' "collect.sh list ($L): the added line cannot be taken for one of the existing line kinds"

  # ---- collect.sh list [from [to]]: a period instead of "-d days back from now" (the clock is 2026-11-20 12:00:00)
  hasl() { if grep -qxF -- "$2" "$1"; then pass "$3"; else fail "$3" "no line is: $2"; fi; }   # file, whole line, name
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log "2026-11-13 20:00" "2026-11-14 01:00" > lp1.out 2> lp1.err; echo $? > lp1.rc
  if [ "$(cat lp1.rc)" = 0 ]; then pass "collect.sh list period ($L): exit 0"; else fail "collect.sh list period ($L): exit $(cat lp1.rc)" "$(cat lp1.err)"; fi
  cnt lp1.out '^Episode' 1 "collect.sh list period ($L): a period that holds only the 13 November episode lists exactly that one"
  hasf lp1.out 'Episode 1: 2026-11-13 23:58:19 to 2026-11-14 00:09:59, 2 lines: ORA-16198; LAD:2 UNSYNCHRONIZED' "collect.sh list period ($L): ... the same episode text as without a period"
  hasl lp1.out 'Incidents in the text alert log alert_list.log, 2026-11-13 20:00:00 to 2026-11-14 01:00:00 (times are the clock time of the host that wrote that log).' "collect.sh list period ($L): the first line names the period, both ends to the second, not a number of days"
  nof lp1.out 'last 30 days' "collect.sh list period ($L): ... and no lookback in days"
  hasf lp1.out "  standby host: sh $R/sh/collect.sh -o dgr_standby_20261113_2353.jsonl standby \"2026-11-13 23:53\" \"2026-11-14 00:15\"" "collect.sh list period ($L): the commands are the ones of the list without a period (no -d without -s)"
  nof lp1.out ' -d ' "collect.sh list period ($L): ... and carry no -d"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-18 2026-11-18 > lp2.out 2> /dev/null
  cnt lp2.out '^Episode' 1 "collect.sh list period ($L): one date twice is that whole day"
  hasf lp2.out 'Episode 1: 2026-11-18 14:00:00 to 2026-11-18 14:02:10, 2 lines' "collect.sh list period ($L): ... the episode of that day"
  hasl lp2.out 'Incidents in the text alert log alert_list.log, 2026-11-18 00:00:00 to 2026-11-18 23:59:59 (times are the clock time of the host that wrote that log).' "collect.sh list period ($L): a date alone is 00:00:00 for from and 23:59:59 for to"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-06 2026-11-13 > lp2b.out 2> /dev/null
  cnt lp2b.out '^Episode' 2 "collect.sh list period ($L): a date-only to includes its whole day (the episode of 13 November starts at 23:58)"
  hasf lp2b.out 'Episode 2: 2026-11-13 23:58:19 to 2026-11-14 00:09:59' "collect.sh list period ($L): ... as the second episode"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-07 2026-11-12 > lp2c.out 2> /dev/null
  hasf lp2c.out 'No incidents found.' "collect.sh list period ($L): a period with no episode says so"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-10-01 2026-10-31 > lp3.out 2> /dev/null
  cnt lp3.out '^Episode' 1 "collect.sh list period ($L): a period reaching back to October lists the 5 October episode without -d"
  hasf lp3.out 'Episode 1: 2026-10-05 22:11:05 to 2026-10-05 22:15:40, 2 lines' "collect.sh list period ($L): ... and only it (the routine lines of 21 October are no incident)"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log -d 3 2026-10-01 > lp3b.out 2> /dev/null
  cnt lp3b.out '^Episode' 4 "collect.sh list period ($L): a from time alone runs to now, and -d is not used for the cutoff"
  hasl lp3b.out 'Incidents in the text alert log alert_list.log, 2026-10-01 00:00:00 to 2026-11-20 12:00:00 (times are the clock time of the host that wrote that log).' "collect.sh list period ($L): ... the end is the clock (DGR_NOW)"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log "2026-11-13 23:00" "2026-11-13 23:59" > lp4.out 2> /dev/null
  cnt lp4.out '^Episode' 1 "collect.sh list period ($L): an episode that starts inside the period..."
  hasf lp4.out 'Episode 1: 2026-11-13 23:58:19 to 2026-11-14 00:09:59, 2 lines' "collect.sh list period ($L): ... still ends at its return line, which is after the end of the period"
  hasf lp4.out '  back to SYNCHRONIZED at 2026-11-14 00:09:59' "collect.sh list period ($L): ... and says when the destination came back"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log "2026-11-06 20:00" "2026-11-06 20:40" > lp4b.out 2> /dev/null
  cnt lp4b.out '^Episode' 1 "collect.sh list period ($L): no episode starts after the end of the period"
  hasf lp4b.out 'Episode 1: 2026-11-06 20:38:07 to 2026-11-06 20:53:27, 3 lines' "collect.sh list period ($L): a line after the end of the period still belongs to the open episode"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log "2026-11-06 20:40" 2026-11-07 > lp5.out 2> /dev/null
  hasf lp5.out 'Episode 1: 2026-11-06 20:43:12 to 2026-11-06 20:53:27, 1 line: ORA-16198' "collect.sh list period ($L): lines before from are not read: the episode starts at the first line after it"
  for bad in "2026-13-45" "2026-11-13 25:00" "next week" "2026-02-31" "2026-11-13 20:00:61" "2026-11-13T20:00"; do
    $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log "$bad" > lpb.out 2> lpb.err; echo $? > lpb.rc
    if [ "$(cat lpb.rc)" = 1 ] && [ ! -s lpb.out ] && grep -qF "list: \"$bad\" is not a time: use YYYY-MM-DD, \"YYYY-MM-DD HH:MI\" or \"YYYY-MM-DD HH:MI:SS\"" lpb.err; then pass "collect.sh list period ($L): \"$bad\" is refused with a message and exit 1"; else fail "collect.sh list period ($L): \"$bad\": exit $(cat lpb.rc)" "$(cat lpb.out lpb.err | head -3)"; fi
  done
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-06 "later" > lpb.out 2> lpb.err; echo $? > lpb.rc
  if [ "$(cat lpb.rc)" = 1 ] && grep -qF 'list: "later" is not a time' lpb.err; then pass "collect.sh list period ($L): a bad to is refused as well"; else fail "collect.sh list period ($L): bad to: exit $(cat lpb.rc)" "$(cat lpb.err)"; fi
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-14 2026-11-13 > lpb.out 2> lpb.err; echo $? > lpb.rc
  if [ "$(cat lpb.rc)" = 1 ] && [ ! -s lpb.out ]; then pass "collect.sh list period ($L): to before from: exit 1, nothing on stdout"; else fail "collect.sh list period ($L): to before from: exit $(cat lpb.rc)" "$(cat lpb.out lpb.err | head -3)"; fi
  hasl lpb.err 'list: the end of the period (2026-11-13 23:59:59) is before its start (2026-11-14 00:00:00)' "collect.sh list period ($L): ... with a message that names both ends"
  $CB "$SH" "$R/sh/collect.sh" list -a alert_list.log 2026-11-25 > lpb.out 2> lpb.err; echo $? > lpb.rc
  if [ "$(cat lpb.rc)" = 1 ] && [ ! -s lpb.out ]; then pass "collect.sh list period ($L): a from after now (to left out) is a to before from"; else fail "collect.sh list period ($L): from in the future: exit $(cat lpb.rc)" "$(cat lpb.out lpb.err | head -3)"; fi
  # the SQL path: list_alerts.sql gets the whole days from from to now, rounded up, plus 1; the rows before from are dropped here
  rm -f lq1.calls lq1b.calls lq1c.calls
  STUB_ARGS_ALL=$D/lq1.calls STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list 2026-11-10 > lq1.out 2> lq1.err; echo $? > lq1.rc
  hasl lq1.out 'Incidents in the v$diag_alert_ext, 2026-11-10 00:00:00 to 2026-11-20 12:00:00 (times are the clock time of the host that wrote that log).' "collect.sh list period ($L): without -a the period reads v\$diag_alert_ext"
  hasf lq1.calls 'sql/list_alerts.sql 12' "collect.sh list period ($L): ... asking for 12 days (10.5 days from 2026-11-10 to now, rounded up, plus 1)"
  cnt lq1.out '^Episode' 2 "collect.sh list period ($L): ... and the rows of 6 November, which the SQL reaches, are dropped"
  hasf lq1.out 'Episode 1: 2026-11-13 23:58:19 to 2026-11-14 00:09:59, 2 lines' "collect.sh list period ($L): ... the first episode is the one of 13 November"
  STUB_ARGS_ALL=$D/lq1b.calls STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list > /dev/null 2> /dev/null
  STUB_ARGS_ALL=$D/lq1c.calls STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -d 7 > /dev/null 2> /dev/null
  hasf lq1b.calls 'sql/list_alerts.sql 30' "collect.sh list ($L): without a period list_alerts.sql gets -d (30)"
  hasf lq1c.calls 'sql/list_alerts.sql 7' "collect.sh list ($L): ... and -d 7 gives 7"
  STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list 2026-11-19 > lq2.out 2> lq2.err; echo $? > lq2.rc
  if [ "$(cat lq2.rc)" = 0 ] && [ ! -s lq2.err ] && grep -qxF 'No incidents found.' lq2.out; then pass "collect.sh list period ($L): rows that all lie before from are no failed read of v\$diag_alert_ext (they hold ORA- text)"; else fail "collect.sh list period ($L): all rows before from: exit $(cat lq2.rc)" "$(cat lq2.err lq2.out | head -3)"; fi

  # ---- collect.sh list -s: only the commands, as a script
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log > ls1.out 2> ls1.err; echo $? > ls1.rc
  if [ "$(cat ls1.rc)" = 0 ] && [ ! -s ls1.err ]; then pass "collect.sh list -s ($L): exit 0, nothing on stderr"; else fail "collect.sh list -s ($L): exit $(cat ls1.rc)" "$(cat ls1.err)"; fi
  n=$(grep -v -e '^$' -e '^#' -e '^sh ' ls1.out | wc -l | tr -d ' ')
  if [ "$n" = 0 ]; then pass "collect.sh list -s ($L): every line of the output is empty, a # line or a command (sh ...)"; else fail "collect.sh list -s ($L): $n lines are none of these" "$(grep -v -e '^$' -e '^#' -e '^sh ' ls1.out | head -3)"; fi
  grep '^sh ' ls1.out > ls1.cmd
  nof ls1.cmd '#' "collect.sh list -s ($L): no command line carries a # comment (an interactive zsh would pass it as arguments)"
  if "$SH" -n ls1.out 2> /dev/null; then pass "collect.sh list -s ($L): the output parses as a shell script (save it and run it with sh)"; else fail "collect.sh list -s ($L): the output does not parse as a shell script" "$("$SH" -n ls1.out 2>&1 | head -3)"; fi
  cnt ls1.out '^sh ' 10 "collect.sh list -s ($L): three episodes: 3 standby, 3 primary, 3 report commands and the combined one"
  nof ls1.out 'still held' "collect.sh list -s ($L): no \"still held\" line"
  cnt ls1.out '^Episode' 0 "collect.sh list -s ($L): none of the normal output (no Episode line, no header)"
  cnt ls1.out '^  ' 0 "collect.sh list -s ($L): no indented line of the normal output"
  hasl ls1.out '# dgstallscripts: commands for the 3 episodes found in the text alert log alert_list.log, last 30 days (since 2026-10-21 12:00:00).' "collect.sh list -s ($L): the first line says what was found and where"
  hasl ls1.out '# Times are the clock time of the host that wrote that log. Routine lines are left out.' "collect.sh list -s ($L): ... and whose clock the times are"
  hasl ls1.out '# Episode 1: 2026-11-06 20:38:07 to 2026-11-06 20:53:27, 3 lines: ORA-16198; LAD:2 UNSYNCHRONIZED (no connection); window 2026-11-06 20:33 to 2026-11-06 20:59' "collect.sh list -s ($L): one comment line per episode with its lines and window"
  hasl ls1.out '# Episode 3: 2026-11-18 14:00:00 to 2026-11-18 14:02:10, 2 lines: ORA-03135; possible network disconnect (standby); window 2026-11-18 13:55 to 2026-11-18 14:18; no return to SYNCHRONIZED found in the log' "collect.sh list -s ($L): ... an episode without a return says so"
  hasl ls1.out "sh $R/sh/collect.sh -o dgr_standby_20261106_2033.jsonl standby \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list -s ($L): the standby command of episode 1"
  hasl ls1.out "sh $R/sh/collect.sh -c dgr_standby_20261106_2033.jsonl -o dgr_primary_20261106_2033.jsonl primary \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list -s ($L): the primary command of episode 1 names its standby bundle"
  hasl ls1.out "sh $R/sh/make_report.sh -o dgr_report_20261106_2033.html dgr_primary_20261106_2033.jsonl dgr_standby_20261106_2033.jsonl" "collect.sh list -s ($L): the report command of episode 1"
  hasl ls1.out "sh $R/sh/collect.sh -o dgr_standby_20261113_2353.jsonl standby \"2026-11-13 23:53\" \"2026-11-14 00:15\"" "collect.sh list -s ($L): the standby command of the episode across midnight"
  hasl ls1.out "sh $R/sh/make_report.sh -o dgr_report_all.html dgr_primary_20261106_2033.jsonl dgr_standby_20261106_2033.jsonl dgr_primary_20261113_2353.jsonl dgr_standby_20261113_2353.jsonl dgr_primary_20261118_1355.jsonl dgr_standby_20261118_1355.jsonl" "collect.sh list -s ($L): the combined report names every bundle, in the order of the episodes"
  cnt ls1.out '^# \.\.\. or one report that holds every episode' 1 "collect.sh list -s ($L): ... after a line that says what it is"
  if awk '/^# 1\. On the STANDBY host/ { a = NR } /^# 2\. / { b = NR } /^# 3\. / { c = NR }
          /^sh .* standby "/ { if (!s1) s1 = NR; s2 = NR } /^sh .* primary "/ { if (!p1) p1 = NR; p2 = NR }
          /^sh .*make_report.sh -o dgr_report_2/ { if (!r1) r1 = NR; r2 = NR } /^sh .*dgr_report_all/ { ra = NR }
          END { exit !(a && a < s1 && s2 < b && b < p1 && p2 < c && c < r1 && r2 < ra) }' ls1.out; then pass "collect.sh list -s ($L): the standby commands, then the primary commands, then the reports, then the combined report"; else fail "collect.sh list -s ($L): the blocks are not in that order" "$(grep -n -e '^# [123]\.' -e '^sh ' ls1.out | cut -c1-60)"; fi
  # a single episode: no combined report
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log 2026-11-13 2026-11-13 > ls2.out 2> /dev/null
  cnt ls2.out '^sh ' 3 "collect.sh list -s ($L): one episode: its standby, primary and report command"
  nof ls2.out 'dgr_report_all' "collect.sh list -s ($L): ... and no combined report"
  nof ls2.out 'one report that holds every episode' "collect.sh list -s ($L): ... and no line about one"
  hasl ls2.out '# dgstallscripts: commands for the 1 episode found in the text alert log alert_list.log, 2026-11-13 00:00:00 to 2026-11-13 23:59:59.' "collect.sh list -s ($L): with a period the first line names it (and says 1 episode)"
  # -d: carried to every collect command when it is not the default
  nof ls1.out ' -d ' "collect.sh list -s ($L): the default lookback (30 days) adds no -d"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log -d 60 > ls3.out 2> /dev/null
  cnt ls3.out '^sh .*collect.sh -d 60 ' 8 "collect.sh list -s ($L): -d 60 -s adds -d 60 to the 4 standby and the 4 primary commands (it reaches the October episode)"
  hasl ls3.out "sh $R/sh/collect.sh -d 60 -o dgr_standby_20261005_2206.jsonl standby \"2026-10-05 22:06\" \"2026-10-05 22:21\"" "collect.sh list -s ($L): ... in front of -o"
  hasl ls3.out "sh $R/sh/collect.sh -d 60 -c dgr_standby_20261005_2206.jsonl -o dgr_primary_20261005_2206.jsonl primary \"2026-10-05 22:06\" \"2026-10-05 22:21\"" "collect.sh list -s ($L): ... and in front of -c"
  cnt ls3.out '^sh .*make_report.sh.* -d ' 0 "collect.sh list -s ($L): the report commands carry no -d"
  hasl ls3.out '# dgstallscripts: commands for the 4 episodes found in the text alert log alert_list.log, last 60 days (since 2026-09-21 12:00:00).' "collect.sh list -s ($L): the first line names the lookback"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log -d 30 > ls3b.out 2> /dev/null
  nof ls3b.out ' -d ' "collect.sh list -s ($L): -d 30 is the default: no -d"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log 2026-11-06 2026-11-07 > ls4.out 2> /dev/null
  hasl ls4.out "sh $R/sh/collect.sh -o dgr_standby_20261106_2033.jsonl standby \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list -s ($L): a recent period (14.5 days back: 16 derived days) carries no -d: the default 30 already reaches its start"
  nof ls4.out ' -d ' "collect.sh list -s ($L): ... on none of the commands"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log -d 60 "2026-10-22 12:00" 2026-11-14 > ls4c.out 2> /dev/null
  cnt ls4c.out '^sh ' 7 "collect.sh list -s ($L): a period from 29 days ago lists 2 episodes"
  nof ls4c.out ' -d ' "collect.sh list -s ($L): ... 29 + 1 = 30 derived days: no -d, and -d 60 is not used"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log "2026-10-21 12:00" 2026-11-07 > ls4b.out 2> /dev/null
  hasl ls4b.out "sh $R/sh/collect.sh -d 31 -o dgr_standby_20261106_2033.jsonl standby \"2026-11-06 20:33\" \"2026-11-06 20:59\"" "collect.sh list -s ($L): exactly 30 days from from to now: 30 + 1 = 31 derived days, more than 30, so -d 31"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log 2026-10-01 2026-10-31 > ls4d.out 2> /dev/null
  hasl ls4d.out "sh $R/sh/collect.sh -d 52 -o dgr_standby_20261005_2206.jsonl standby \"2026-10-05 22:06\" \"2026-10-05 22:21\"" "collect.sh list -s ($L): a period reaching back to 1 October (50.5 days: 52 derived days) adds -d 52 to the standby command"
  hasl ls4d.out "sh $R/sh/collect.sh -d 52 -c dgr_standby_20261005_2206.jsonl -o dgr_primary_20261005_2206.jsonl primary \"2026-10-05 22:06\" \"2026-10-05 22:21\"" "collect.sh list -s ($L): ... and to the primary command"
  cnt ls4d.out '^sh .*make_report.sh.* -d ' 0 "collect.sh list -s ($L): ... and none to the report command"
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log -d 7 > ls4e.out 2> /dev/null
  cnt ls4e.out '^sh .*collect.sh -d 7 ' 4 "collect.sh list -s ($L): without a period an explicit -d 7 (less than 30) is passed on as it is: -d 7 on the 2 standby and the 2 primary commands"
  # nothing found: one # line, exit 0
  $CB "$SH" "$R/sh/collect.sh" list -s -a routine.log > ls5.out 2> /dev/null; echo $? > ls5.rc
  if [ "$(cat ls5.rc)" = 0 ] && [ "$(cat ls5.out)" = '# No incidents found in the text alert log routine.log, last 30 days (since 2026-10-21 12:00:00).' ]; then pass "collect.sh list -s ($L): no incident: the one # line and exit 0"; else fail "collect.sh list -s ($L): no incident: exit $(cat ls5.rc)" "$(cat ls5.out)"; fi
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log 2026-11-01 2026-11-02 > ls5b.out 2> /dev/null; echo $? > ls5b.rc
  if [ "$(cat ls5b.rc)" = 0 ] && [ "$(cat ls5b.out)" = '# No incidents found in the text alert log alert_list.log, 2026-11-01 00:00:00 to 2026-11-02 23:59:59.' ]; then pass "collect.sh list -s ($L): ... with a period the line names it"; else fail "collect.sh list -s ($L): no incident in a period: exit $(cat ls5b.rc)" "$(cat ls5b.out)"; fi
  # the notes of the shortened windows stay on the comment line of the episode
  $CB "$SH" "$R/sh/collect.sh" list -s -a alert_late.log > ls6.out 2> /dev/null
  hasl ls6.out '# Episode 1: 2026-11-12 10:11:21 to 2026-11-18 22:53:00, 3 lines: ORA-16198; LAD:2 UNSYNCHRONIZED (no connection); window 2026-11-12 10:06 to 2026-11-12 10:42; window shortened to end 30 minutes after the first line (6 d 12 h after it the destination returned)' "collect.sh list -s ($L): a late return: the comment line says the window was shortened and how late the destination returned"
  printf '2026-11-18T10:00:00.000000+01:00\nORA-03135: connection lost contact\n2026-11-18T10:10:00.000000+01:00\nORA-03135: connection lost contact\n2026-11-18T10:20:00.000000+01:00\nORA-03135: connection lost contact\n2026-11-18T10:30:00.000000+01:00\nORA-03135: connection lost contact\n2026-11-18T10:40:00.000000+01:00\nORA-03135: connection lost contact\n2026-11-18T10:50:00.000000+01:00\nORA-03135: connection lost contact\n' > chain.log
  $CB "$SH" "$R/sh/collect.sh" list -s -a chain.log > ls7.out 2> /dev/null
  hasl ls7.out '# Episode 1: 2026-11-18 10:00:00 to 2026-11-18 10:50:00, 6 lines: ORA-03135; window 2026-11-18 09:55 to 2026-11-18 10:30; no return to SYNCHRONIZED found in the log; window shortened to end 30 minutes after the first line (50 min after it the last line was logged)' "collect.sh list -s ($L): lines chained for 50 minutes without a return: both notes on the comment line"
  # the SQL path asks list_alerts.sql only, with the days of the period; list_sources.sql is not run (with -a sqlplus is not called at all)
  rm -f lq3.calls lq4.calls
  STUB_ARGS_ALL=$D/lq3.calls STUB_LIST=$D/list_sql.txt STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -s 2026-11-06 2026-11-13 > lq3.out 2> /dev/null
  cnt lq3.calls '.' 1 "collect.sh list -s ($L): the SQL path calls sqlplus once"
  hasf lq3.calls 'sql/list_alerts.sql 16' "collect.sh list -s ($L): ... for list_alerts.sql with the days of the period"
  nof lq3.calls 'list_sources' "collect.sh list -s ($L): ... and never for sql/list_sources.sql"
  hasl lq3.out '# dgstallscripts: commands for the 2 episodes found in the v$diag_alert_ext, 2026-11-06 00:00:00 to 2026-11-13 23:59:59.' "collect.sh list -s ($L): the source is v\$diag_alert_ext"
  nof lq3.out 'still held' "collect.sh list -s ($L): ... and no \"still held\" line"
  STUB_ARGS_ALL=$D/lq4.calls STUB_MODE=list SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -s -a alert_list.log > /dev/null 2> /dev/null
  if [ ! -s lq4.calls ]; then pass "collect.sh list -s -a ($L): sqlplus is not called at all"; else fail "collect.sh list -s -a ($L): sqlplus was called" "$(cat lq4.calls)"; fi
  # failures stay failures: nothing on stdout
  $CB "$SH" "$R/sh/collect.sh" list -s -a nosuch.log > ls8.out 2> ls8.err; echo $? > ls8.rc
  if [ "$(cat ls8.rc)" = 1 ] && [ ! -s ls8.out ]; then pass "collect.sh list -s ($L): an alert log that cannot be read: exit 1, nothing on stdout"; else fail "collect.sh list -s ($L): unreadable alert log: exit $(cat ls8.rc)" "$(cat ls8.out ls8.err | head -3)"; fi
  has ls8.err '^list: cannot read nosuch.log' "collect.sh list -s ($L): ... with the message on stderr"
  STUB_MODE=list1219 SQLPLUS=$W/sqlplus $CB "$SH" "$R/sh/collect.sh" list -s > ls9.out 2> ls9.err; echo $? > ls9.rc
  if [ "$(cat ls9.rc)" = 1 ] && [ ! -s ls9.out ]; then pass "collect.sh list -s ($L): a mounted standby (ORA-01219): exit 1, nothing on stdout"; else fail "collect.sh list -s ($L): ORA-01219: exit $(cat ls9.rc)" "$(cat ls9.out ls9.err | head -3)"; fi
  has ls9.err '^list: could not read v.diag_alert_ext: ORA-01219' "collect.sh list -s ($L): ... with the message on stderr"
  SQLPLUS=$NOSQL $CB "$SH" "$R/sh/collect.sh" list -s > ls10.out 2> ls10.err; echo $? > ls10.rc
  if [ "$(cat ls10.rc)" = 1 ] && [ ! -s ls10.out ]; then pass "collect.sh list -s ($L): neither sqlplus nor -a: exit 1, nothing on stdout"; else fail "collect.sh list -s ($L): no sqlplus: exit $(cat ls10.rc)" "$(cat ls10.out ls10.err | head -3)"; fi
  # -s belongs to list
  for side in standby primary; do
    $CB "$SH" "$R/sh/collect.sh" -s $side "$WIN1" "$WIN2" -t nodir -a alert_cdb1.log -l nosuch.log -o sopt.jsonl > sopt.out 2> sopt.err; echo $? > sopt.rc
    if [ "$(cat sopt.rc)" = 1 ] && [ ! -e sopt.jsonl ] && grep -qxF -- '-s only applies to list' sopt.err; then pass "collect.sh list -s ($L): with $side it is refused with \"-s only applies to list\", exit 1, no bundle written"; else fail "collect.sh list -s ($L): with $side: exit $(cat sopt.rc)" "$(cat sopt.err | head -3)"; fi
  done
  cd "$R" || return
}
collect_tests "$SHBIN" sh
if [ -n "$DASH" ]; then collect_tests "$DASH" dash; else skip "collect.sh under dash: /bin/dash not found"; fi

# ---------------------------------------------------------------- make_report.sh without bundle arguments
mkdir -p "$W/mr" "$W/mr0"
cp "$R/examples/sample_primary.jsonl" "$W/mr/dgr_primary_x.jsonl"; cp "$R/examples/sample_standby.jsonl" "$W/mr/dgr_standby_x.jsonl"; echo '{"t":"x"}' > "$W/mr/other.jsonl"
(cd "$W/mr" && sh "$R/sh/make_report.sh" -o default.html 2> ../mr.err; sh "$R/sh/make_report.sh" -o explicit.html dgr_primary_x.jsonl dgr_standby_x.jsonl 2> /dev/null)
same "make_report.sh: no bundle arguments = every ./dgr_*.jsonl (other files are left alone)" "$W/mr/default.html" "$W/mr/explicit.html"
has "$W/mr.err" '2 file(s) matching ./dgr_\*.jsonl' "make_report.sh: says how many files it took"
has "$W/mr.err" '  ./dgr_primary_x.jsonl' "make_report.sh: ... and which"
nof "$W/mr.err" 'other.jsonl' "make_report.sh: a file that does not match is not taken"
(cd "$W/mr0" && sh "$R/sh/make_report.sh" -o none.html > /dev/null 2> ../mr0.err; echo $? > ../mr0.rc)
if [ "$(cat "$W/mr0.rc")" = 1 ] && [ ! -e "$W/mr0/none.html" ]; then pass "make_report.sh: no bundles anywhere: exit 1, no report"; else fail "make_report.sh: no bundles: exit $(cat "$W/mr0.rc")"; fi
has "$W/mr0.err" 'No bundle given and no ./dgr_\*.jsonl in' "make_report.sh: ... with a clear message"
has "$W/mr0.err" 'Run sh/collect.sh on each database host first' "make_report.sh: ... that says what to do"

# ---------------------------------------------------------------- net_sampler.sh
mkdir -p "$W/ns"
NSP="env PATH=$W/host.lin/bin STUB_STATE=$W/state"
rm -rf "$W/state"; mkdir -p "$W/state"
COUNT=3 STUB_SIDE=primary $NSP "$SHBIN" "$R/sh/net_sampler.sh" 198.51.100.12 1526 5 "$W/ns/a.log" 2> "$W/ns/a.err"
if [ -n "$DASH" ]; then
  COUNT=2 STUB_SIDE=primary $NSP "$DASH" "$R/sh/net_sampler.sh" 198.51.100.12 1526 5 "$W/ns/dash.log" 2> /dev/null
  if [ "$(grep -c ' rtt=0.412 retr=[0-9]* sendq=4320$' "$W/ns/dash.log")" = 2 ]; then pass "net_sampler.sh runs under dash"; else fail "net_sampler.sh under dash" "$(cat "$W/ns/dash.log")"; fi
fi
if [ "$(wc -l < "$W/ns/a.log" | tr -d ' ')" = 4 ]; then pass "net_sampler.sh: a header line and one line per sample (COUNT=3)"; else fail "net_sampler.sh: lines in the log" "$(cat "$W/ns/a.log")"; fi
has "$W/ns/a.log" '^# net_sampler peer=198.51.100.12 port=1526 interval=5 started=' "net_sampler.sh: the header names peer, port and interval"
n=$(grep -cE '^20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9][+-][0-9][0-9][0-9][0-9] rtt=0\.412 retr=[0-9]+ sendq=4320$' "$W/ns/a.log")
if [ "$n" = 3 ]; then pass "net_sampler.sh: each line has a time with its UTC offset, the round trip, the retransmit counter and the largest Send-Q to the peer"; else fail "net_sampler.sh: sample lines" "$(cat "$W/ns/a.log")"; fi
r=$(grep -o 'retr=[0-9]*' "$W/ns/a.log" | tr '\n' ' ')
if [ "$r" = "retr=1005 retr=1010 retr=1015 " ]; then pass "net_sampler.sh: the retransmit counter is the cumulative one (subtract two lines)"; else fail "net_sampler.sh: retransmit counters: $r"; fi
STUB_PING=loss COUNT=1 STUB_SIDE=primary $NSP "$SHBIN" "$R/sh/net_sampler.sh" 198.51.100.12 1526 5 "$W/ns/b.log" 2> /dev/null
has "$W/ns/b.log" ' rtt=loss retr=' "net_sampler.sh: a ping without a reply is rtt=loss"
COUNT=3 MAXKB=0 STUB_SIDE=primary $NSP "$SHBIN" "$R/sh/net_sampler.sh" 198.51.100.12 1526 1 "$W/ns/c.log" 2> /dev/null
if [ -s "$W/ns/c.log.1" ] && [ "$(wc -l < "$W/ns/c.log" | tr -d ' ')" -le 2 ]; then pass "net_sampler.sh: size-based rotation keeps one .1 file and a small current log"; else fail "net_sampler.sh: rotation" "$(ls "$W/ns")"; fi
COUNT=2 STUB_SIDE=primary $NSP "$SHBIN" "$R/sh/net_sampler.sh" 198.51.100.12 1526 1 "$W/ns/d.log" 2> /dev/null
if [ ! -e "$W/ns/d.log.1" ]; then pass "net_sampler.sh: no rotation below the size limit"; else fail "net_sampler.sh: rotated a small log"; fi
for a in "" "198.51.100.12 abc"; do
  sh "$R/sh/net_sampler.sh" $a > "$W/ns/e.err" 2>&1; rc=$?
  if [ "$rc" = 1 ] && [ -s "$W/ns/e.err" ]; then pass "net_sampler.sh: bad arguments ($a): usage and exit 1"; else fail "net_sampler.sh: bad arguments ($a): exit $rc"; fi
done
# a log written by the sampler is read back by collect.sh -n
( cd "$W/ns" && SQLPLUS=$W/no-such env PATH=$W/host.bare/bin DGR_NOW=$NOWT "$SHBIN" "$R/sh/collect.sh" standby "2000-01-01 00:00" "2100-01-01 00:00" -a /nonexistent -t nodir -l nosuch.log -n a.log -o back.jsonl 2> /dev/null )
cnt "$W/ns/back.jsonl" '"t":"netsamp"' 3 "net_sampler.sh: collect.sh -n reads the lines the sampler wrote"
hasf "$W/ns/back.jsonl" '"rtt":0.412,"loss":false,"retr":1005,"sendq":4320' "net_sampler.sh: ... with their values"
hasf "$W/ns/back.jsonl" '(peer=198.51.100.12 port=1526 interval=5 started=' "net_sampler.sh: ... and the header"

# ---------------------------------------------------------------- the one list of history patterns (item: routine lines are not incidents)
( . "$R/sh/dglib.sh"
  hl() { printf '%s\n' "$1" | awk "$HISTAWK"'{ print dghist($0) ? "I" : (dgsync($0) ? "S" : "-") }'; }
  chk() { got=$(hl "$2"); if [ "$got" = "$1" ]; then echo "ok    $3"; else echo "FAIL  $3 (got $got, want $1)"; fi; }
  chk - 'LGWR (PID:4242): RT_PMODE: PRIMARY            changing to   mode MAXIMUM AVAILABILITY level UNSYNCHRONIZED' "history pattern: RT_PMODE PRIMARY ... UNSYNCHRONIZED is routine"
  chk - ' rfs (PID:4400): RT_PMODE: PHYSICAL           changing to   mode MAXIMUM AVAILABILITY level UNSYNCHRONIZED' "history pattern: RT_PMODE PHYSICAL ... UNSYNCHRONIZED is routine"
  chk - 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED reason ASYNC configuration' "history pattern: reason ASYNC configuration is routine"
  chk I 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED reason no connection' "history pattern: LAD level UNSYNCHRONIZED reason no connection is an incident"
  chk I 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED reason destination has a gap' "history pattern: reason destination has a gap"
  chk I 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED reason no available SRLs' "history pattern: reason no available SRLs"
  chk I 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED' "history pattern: no reason"
  chk I 'LGWR (PID:4242): LAD:2 is UNSYNCHRONIZED' "history pattern: the older family LAD:n is UNSYNCHRONIZED"
  chk I 'x RT_PMODE: PRIMARY changing to mode M level UNSYNCHRONIZED and ORA-16198 on the same line' "history pattern: a routine line that also names an ORA- code still matches"
  for t in ORA-16198 ORA-03135 ORA-03113 ORA-16055 ORA-16191 TNS-12535 TNS-12170 TNS-12609 'Possible network disconnect with primary database'; do chk I "lead $t trail" "history pattern: $t"; done
  chk - 'Thread 1 advanced to log sequence 114490 (LGWR switch)' "history pattern: an ordinary line"
  chk S 'LGWR (PID:4242): RT_PMODE: LAD:2              changing to                             level SYNCHRONIZED  ' "synchronized: LAD level SYNCHRONIZED ends the period"
  chk S 'LGWR (PID:4242): LAD:2 is SYNCHRONIZED' "synchronized: LAD:n is SYNCHRONIZED"
  chk - 'LGWR (PID:4242): RT_PMODE: PRIMARY            changing to   mode MAXIMUM AVAILABILITY level SYNCHRONIZED' "synchronized: the PRIMARY line does not end it" ) > "$W/pat.out"
while IFS= read -r l; do case $l in ok*) pass "${l#ok    }" ;; *) fail "${l#FAIL  }" ;; esac; done < "$W/pat.out"
# a WITH subquery that is used more than once is materialised in a temporary table, which a MOUNTED database cannot create (ORA-01219): json_standby.sql must not have one
# without an inline hint. cte_lint prints a line per CTE that is referenced (from/join) more than once and whose statement has no /*+ inline */ hint.
cte_lint() { awk '
  function stmt(s,   t, u, nm, n, c) {
    t = tolower(s); if (t !~ /^[ \t]*with[ \t]/) return
    u = t
    while (match(u, /[a-z_][a-z0-9_]*[ \t]+as[ \t]*\(/)) {
      nm = substr(u, RSTART, RLENGTH); sub(/[ \t].*$/, "", nm); u = substr(u, RSTART + RLENGTH)
      c = 0; v = t; while (match(v, "(from|join)[ \t]+" nm "([^a-z0-9_$#]|$)")) { c++; v = substr(v, RSTART + RLENGTH) }
      if (c > 1 && index(t, "/*+ inline") == 0) print FILENAME ": CTE " nm " is used " c " times without an inline hint: " substr(s, 1, 60) }
  }
  { sub(/--.*$/, ""); buf = buf " " $0 }
  /;[ \t]*$/ { stmt(buf); buf = "" }' "$1"; }
printf 'with s as (select 1 a from dual), d as (select a from s)\nselect (select count(*) from s) n from d;\n' > "$W/cte_bad.sql"
printf 'with s as (select /*+ inline */ 1 a from dual), d as (select a from s)\nselect (select count(*) from s) n from d;\n' > "$W/cte_hint.sql"
printf 'with s as (select 1 a from dual), d as (select a from s)\nselect a from d;\n' > "$W/cte_once.sql"
[ -n "$(cte_lint "$W/cte_bad.sql")" ] && [ -z "$(cte_lint "$W/cte_hint.sql")" ] && [ -z "$(cte_lint "$W/cte_once.sql")" ] && pass "sql lint: the CTE check finds a subquery used twice, and accepts an inline hint or a single use" || fail "sql lint: the CTE check itself is wrong" "$(cte_lint "$W/cte_bad.sql")"
out=$(cte_lint "$R/sql/json_standby.sql")
if [ -z "$out" ]; then pass "sql lint: json_standby.sql has no WITH subquery used more than once without an inline hint (a mounted standby cannot materialise it)"; else fail "sql lint: json_standby.sql: a WITH subquery that a mounted database would materialise" "$out"; fi
if [ "$(awk '{ sub(/--.*$/, "") } tolower($0) ~ /^[ \t]*with[ \t]/ { n++ } END { print n + 0 }' "$R/sql/json_standby.sql")" = 0 ]; then pass "sql lint: json_standby.sql uses no WITH clause at all (nested inline views)"; else fail "sql lint: json_standby.sql has a WITH clause"; fi
# the substitution variables of the two collector scripts: SQL*Plus replaces every &name, in code, comments and strings alike, and prompts for one it does not know (stdin is /dev/null there).
# var_lint prints a line per &name that has no define before its first use, no `column name new_value name noprint` (unless it is a plain argument: define name = "&1".."&5"), and per & that is not a variable.
var_lint() { awk '
  /^[ \t]*define[ \t]/ { s = $0; sub(/^[ \t]*define[ \t]+/, "", s); v = s; sub(/[ \t]*=.*$/, "", s); sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      if (!(s in defl)) defl[s] = NR; plain[s] = (v ~ /^"&[1-5]"$/) }
  /^[ \t]*column[ \t]/ && $3 == "new_value" && $4 == $2 { iscol[$2] = 1 }
  { s = $0
    while (match(s, /&/)) {
      rest = substr(s, RSTART + 1)
      if (match(rest, /^[A-Za-z0-9_]+/)) { nm = substr(rest, RSTART, RLENGTH)
        if (nm !~ /^[1-5]$/ && !(nm in firstl)) firstl[nm] = NR
        s = substr(rest, RLENGTH + 1) }
      else { print FILENAME ":" NR ": a & that is not a substitution variable: " substr($0, 1, 80); s = rest } } }
  END { for (nm in firstl) {
          if (!(nm in defl)) print FILENAME ": &" nm " (line " firstl[nm] ") has no define"
          else if (defl[nm] > firstl[nm]) print FILENAME ": &" nm " is used at line " firstl[nm] " before its define at line " defl[nm]
          else if (!plain[nm] && !(nm in iscol)) print FILENAME ": &" nm " has no column " nm " new_value " nm " noprint" } }' "$1"; }
# SQL*Plus ends a statement at a blank line (sqlblanklines is off). blank_lint prints a line per blank line between the first line of a statement (select or with at the start of a line)
# and its terminating ; (comment-only lines inside a statement are fine: that is where the pattern markers sit).
blank_lint() { awk '
  !ins && tolower($0) ~ /^[ \t]*(select|with)[ \t]/ { ins = 1; first = NR }
  ins && $0 ~ /^[ \t]*$/ { print FILENAME ":" NR ": blank line inside the statement that starts at line " first; ins = 0; next }
  ins && $0 ~ /;[ \t]*$/ && $0 !~ /^[ \t]*--/ { ins = 0 }' "$1"; }
# newsrc_lint FILE [list]: each record statement of the newer sources (t lfs_by, aas, wl_hist, act; act by kind) has a cov statement of the same src (and kind) in the file, and every cov statement of
# lfs_by, aas, wl_hist, alsync and act has an st case that says 'error' for a count variable that is defined as a negative number. With "list" it prints the record keys it found instead (a lint that finds nothing proves nothing).
newsrc_lint() { awk -v q="'" -v list="$2" '
  function field(s, name,   re) {   # the literal in  name value literal  of the statement, "" when there is none
    re = q name q " value " q "[A-Za-z_0-9]+" q
    if (!match(s, re)) return ""
    re = substr(s, RSTART, RLENGTH); sub(".* value " q, "", re); sub(q "$", "", re); return re }
  function stmt(s,   t, k, re, v) {
    t = field(s, "t")
    if (t == "cov") {
      k = field(s, "src"); if (k !~ /^(lfs_by|aas|wl_hist|alsync|act)$/) return
      if (k == "act") k = "act:" field(s, "kind")
      cov[k] = 1
      re = q "st" q " value case when &[A-Za-z_0-9]+ < 0 then " q "error" q
      if (!match(s, re)) { bad[k] = "no st case with error on a negative count variable"; return }
      v = substr(s, RSTART, RLENGTH); sub(/.*when &/, "", v); sub(/ < 0.*/, "", v); var[k] = v }
    else if (t ~ /^(lfs_by|aas|wl_hist|act)$/) { k = t; if (t == "act") k = "act:" field(s, "kind"); rec[k] = 1 } }
  /^define[ \t]/ { nm = $0; sub(/^define[ \t]+/, "", nm); val = nm; sub(/[ \t]*=.*/, "", nm); sub(/^[^=]*=[ \t]*/, "", val); sub(/[ \t]+$/, "", val); defv[nm] = val }
  !ins && tolower($0) ~ /^[ \t]*(select|with)[ \t]/ { ins = 1; buf = "" }
  ins && $0 !~ /^[ \t]*--/ { buf = buf " " $0 }
  ins && $0 ~ /;[ \t]*$/ && $0 !~ /^[ \t]*--/ { stmt(buf); ins = 0 }
  END { for (k in rec) { if (list != "") print k; else if (!(k in cov)) print FILENAME ": records of " k " are written but there is no cov statement for them" }
        if (list == "") for (k in cov) { if (k in bad) print FILENAME ": the cov statement of " k " has " bad[k]
                            else if (!(var[k] in defv) || defv[var[k]] !~ /^-[0-9]/) print FILENAME ": the cov statement of " k " tests &" var[k] ", which is not defined as a negative number" } }' "$1"; }
says() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
printf 'define t_from = "&1"\ndefine n = -1\ncolumn n new_value n noprint\n-- all fine: &t_from and &n\nselect &t_from, &n from dual;\n' > "$W/v_good.sql"
printf 'define t_from = "&1"\nselect &x from dual where &t_from = 1;\n' > "$W/v_undef.sql"
printf 'define y = -1\nselect &y from dual;\n' > "$W/v_nocol.sql"
printf 'select &z from dual;\ndefine z = 1\ncolumn z new_value z noprint\n' > "$W/v_late.sql"
printf 'define t_from = "&1"\n-- tom & jerry\nselect 1 from dual;\n' > "$W/v_stray.sql"
printf "define t_from = \"&1\"\nselect 'a & b' from dual;\n" > "$W/v_stray2.sql"
vb1=$(var_lint "$W/v_undef.sql"); vb2=$(var_lint "$W/v_nocol.sql"); vb3=$(var_lint "$W/v_late.sql"); vb4=$(var_lint "$W/v_stray.sql"); vb5=$(var_lint "$W/v_stray2.sql")
if [ -z "$(var_lint "$W/v_good.sql")" ] && says "$vb1" '&x (line 2) has no define' && ! says "$vb1" '&t_from' && says "$vb2" 'has no column y new_value y noprint' && says "$vb3" 'before its define' \
   && says "$vb4" 'a & that is not a substitution variable' && says "$vb5" 'a & that is not a substitution variable'; then
  pass "sql lint: the substitution variable check finds an undefined name, a name without its column, a use before the define and a stray &, and accepts the plain arguments"
else fail "sql lint: the substitution variable check itself is wrong" "$(var_lint "$W/v_good.sql"; echo "$vb1"; echo "$vb2"; echo "$vb3"; echo "$vb4"; echo "$vb5")"; fi
for f in json_primary json_standby list_alerts; do
  out=$(var_lint "$R/sql/$f.sql")
  if [ -z "$out" ]; then pass "sql lint: every &name of $f.sql has a define before its first use and a column new_value (the plain arguments excepted), and no & stands for anything else"; else fail "sql lint: substitution variables of $f.sql" "$out"; fi
done
printf 'select 1\n-- a comment inside the statement\nfrom dual;\n\nselect 2 from dual;\n\n-- between\nwith a as (select 1 x from dual)\nselect x from a;\n' > "$W/b_good.sql"
printf 'select 1\n\nfrom dual;\n' > "$W/b_bad.sql"
printf 'with a as (select 1 x from dual)\n\nselect x from a;\n' > "$W/b_bad2.sql"
if [ -z "$(blank_lint "$W/b_good.sql")" ] && says "$(blank_lint "$W/b_bad.sql")" 'blank line inside the statement that starts at line 1' && says "$(blank_lint "$W/b_bad2.sql")" 'blank line inside the statement that starts at line 1'; then
  pass "sql lint: the blank line check finds a blank line inside a statement and accepts blank lines between statements and comments inside one"
else fail "sql lint: the blank line check itself is wrong" "$(blank_lint "$W/b_good.sql"; blank_lint "$W/b_bad.sql"; blank_lint "$W/b_bad2.sql")"; fi
for f in json_primary json_standby list_alerts list_sources; do
  out=$(blank_lint "$R/sql/$f.sql")
  if [ -z "$out" ]; then pass "sql lint: no blank line inside a statement of $f.sql (SQL*Plus would end the statement there)"; else fail "sql lint: blank line inside a statement of $f.sql" "$out"; fi
done
for f in json_primary json_standby; do
  out=$(grep -nE '^[[:space:]]*--.*;[[:space:]]*$' "$R/sql/$f.sql" | cut -c1-120)
  if [ -z "$out" ]; then pass "sql lint: no comment line of $f.sql ends with a semicolon (SQL*Plus could take it for the end of a statement)"; else fail "sql lint: a comment line of $f.sql ends with a semicolon" "$out"; fi
done
# A select list with an aggregate and a bare scalar subquery and no GROUP BY is ORA-00937 (not a single-group group function). The stub does not run SQL, only a database finds it: tests/sql_lint.py does.
if [ $HAVE_PY = 1 ]; then
  printf 'select count(*) n,\n       (select max(x) from t) m\nfrom   (select 1 x from dual);\n' > "$W/a_bad.sql"
  printf 'select count(*) n,\n       max((select max(x) from t)) m\nfrom   (select 1 x from dual);\nselect (select 1 from dual) a, count(*) over () c from dual;\nselect d, count(*), (select 1 from dual) q from t group by d;\nselect json_object(%s value (select count(*) from t)) j, (select count(*) from t) n from dual;\n' "'t'" > "$W/a_good.sql"
  ab1=$(python3 "$T/sql_lint.py" "$W/a_bad.sql")
  if [ -z "$(python3 "$T/sql_lint.py" "$W/a_good.sql")" ] && says "$ab1" 'a_bad.sql:1: aggregate beside a scalar subquery with no GROUP BY (ORA-00937)'; then
    pass "sql lint: the aggregate check finds a scalar subquery beside count() with no GROUP BY, and accepts max((select ...)), an analytic count, a GROUP BY and subqueries beside no aggregate"
  else fail "sql lint: the aggregate check itself is wrong" "$(python3 "$T/sql_lint.py" "$W/a_good.sql"; echo "$ab1")"; fi
  for f in json_primary json_standby list_alerts list_sources; do
    out=$(python3 "$T/sql_lint.py" "$R/sql/$f.sql")
    if [ -z "$out" ]; then pass "sql lint: no select of $f.sql has an aggregate beside a bare scalar subquery without GROUP BY (ORA-00937)"; else fail "sql lint: ORA-00937 pattern in $f.sql" "$out"; fi
  done
fi
NS_OK="define n = -1\ncolumn n new_value n noprint\nselect json_object('t' value 'lfs_by', 'x' value 1) from dual;\nselect json_object('t' value 'cov', 'side' value 'primary', 'src' value 'lfs_by',\n  'st' value case when &n < 0 then 'error' when &n > 0 then 'ok' else 'empty' end) from dual;\nselect json_object('t' value 'act', 'kind' value 'job') from dual;\nselect json_object('t' value 'cov', 'src' value 'act', 'kind' value 'job',\n  'st' value case when &n < 0 then 'error' else 'ok' end) from dual;\n"
printf "$NS_OK" > "$W/n_good.sql"
printf "$NS_OK" | sed "s/'kind' value 'job',\$/'kind' value 'rman',/" > "$W/n_kind.sql"
printf "$NS_OK" | sed "s/'src' value 'lfs_by'/'src' value 'lfs'/" > "$W/n_nocov.sql"
printf "$NS_OK" | sed "s/then 'error' when/then 'bad' when/" > "$W/n_noerr.sql"
printf "$NS_OK" | sed "s/define n = -1/define n = 0/" > "$W/n_pos.sql"
nb1=$(newsrc_lint "$W/n_kind.sql"); nb2=$(newsrc_lint "$W/n_nocov.sql"); nb3=$(newsrc_lint "$W/n_noerr.sql"); nb4=$(newsrc_lint "$W/n_pos.sql")
if [ -z "$(newsrc_lint "$W/n_good.sql")" ] && [ "$(newsrc_lint "$W/n_good.sql" list | sort | tr '\n' ' ')" = "act:job lfs_by " ] && says "$nb1" 'records of act:job are written but there is no cov statement' \
   && says "$nb2" 'records of lfs_by are written but there is no cov statement' && says "$nb3" 'the cov statement of lfs_by has no st case with error on a negative count variable' && says "$nb4" 'tests &n, which is not defined as a negative number'; then
  pass "sql lint: the check of the newer sources finds a record without a cov statement (by kind for act), a cov statement without the error case, a count variable that is not negative, and accepts the right form"
else fail "sql lint: the check of the newer sources itself is wrong" "$(newsrc_lint "$W/n_good.sql"; echo "$nb1"; echo "$nb2"; echo "$nb3"; echo "$nb4")"; fi
# the same for aas: a record of that type needs a cov statement with src aas and the error case on a negative count variable
printf "$NS_OK" | sed "s/'t' value 'lfs_by'/'t' value 'aas'/; s/'src' value 'lfs_by'/'src' value 'aas'/" > "$W/n_aas.sql"
printf "$NS_OK" | sed "s/'t' value 'lfs_by'/'t' value 'aas'/" > "$W/n_aasnocov.sql"
printf "$NS_OK" | sed "s/'t' value 'lfs_by'/'t' value 'aas'/; s/'src' value 'lfs_by'/'src' value 'aas'/; s/then 'error' when/then 'bad' when/" > "$W/n_aasnoerr.sql"
na1=$(newsrc_lint "$W/n_aasnocov.sql"); na2=$(newsrc_lint "$W/n_aasnoerr.sql")
if [ -z "$(newsrc_lint "$W/n_aas.sql")" ] && [ "$(newsrc_lint "$W/n_aas.sql" list | sort | tr '\n' ' ')" = "aas act:job " ] && says "$na1" 'records of aas are written but there is no cov statement' && says "$na2" 'the cov statement of aas has no st case with error on a negative count variable'; then
  pass "sql lint: the check of the newer sources covers aas: a record without a cov statement of src aas, and a cov statement without the error case, are found"
else fail "sql lint: the check of the newer sources does not cover aas" "$(newsrc_lint "$W/n_aas.sql"; echo "$na1"; echo "$na2")"; fi
for spec in "json_primary aas act:job act:logsw act:rman lfs_by wl_hist" "json_standby act:rman"; do
  set -- $spec; f=$1; shift; out=$(newsrc_lint "$R/sql/$f.sql")
  if [ -z "$out" ] && [ "$(newsrc_lint "$R/sql/$f.sql" list | sort | tr '\n' ' ')" = "$* " ]; then
    pass "sql lint: $f.sql: every record statement of $* has a cov statement with the same src (and kind), an st case with 'error' on a count variable that defaults to a negative number"
  else fail "sql lint: the newer sources of $f.sql" "$out
found: $(newsrc_lint "$R/sql/$f.sql" list | sort | tr '\n' ' ')"; fi
done
# the SQL files carry the same list between "hist-pattern" markers: every block is identical (whitespace aside) and holds every token of the awk function
blk() { awk -v n="$2" '/-- hist-pattern: begin/ { c++; on = (c == n); next } /-- hist-pattern: end/ { on = 0 } on' "$1" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//'; }
B0=$(blk "$R/sql/20_alert_log.sql" 1); ok=1; nb=0
for spec in "$R/sql/json_primary.sql 1" "$R/sql/json_primary.sql 2" "$R/sql/20_alert_log.sql 1" "$R/sql/list_alerts.sql 1"; do
  set -- $spec; nb=$((nb + 1)); [ "$(blk "$1" "$2")" = "$B0" ] || { ok=0; fail "history pattern: block $2 of $(basename "$1") differs from sql/20_alert_log.sql" "$(blk "$1" "$2")"; }
done
[ -n "$B0" ] && [ $ok = 1 ] && pass "history pattern: the $nb SQL blocks (json_primary.sql twice, 20_alert_log.sql, list_alerts.sql) are the same list"
. "$R/sh/dglib.sh"; AW=$(printf '%s' "$HISTAWK" | tr -s ' \t\n' ' ')
for t in UNSYNCHRONIZED ORA-16198 ORA-03135 ORA-03113 ORA-16055 ORA-16191 TNS-12535 TNS-12170 TNS-12609 'Possible network disconnect' 'RT_PMODE' 'PRIMARY|PHYSICAL' 'ASYNC configuration'; do
  case $B0 in *"$t"*) ;; *) fail "history pattern: sql blocks lack $t" ;; esac
  case $AW in *"$t"*) ;; *) fail "history pattern: sh/dglib.sh lacks $t" ;; esac
done
pass "history pattern: every token is in the SQL blocks and in sh/dglib.sh"
# the condition that ends an UNSYNCHRONIZED period: json_primary.sql (twice) and list_alerts.sql carry it between "sync-pattern" markers, sh/dglib.sh has it as dgsync() in awk. The blocks are identical (whitespace aside)
# and dgsync() has the same three tokens, checked on its own line (the whole of HISTAWK would match SYNCHRONIZED inside UNSYNCHRONIZED).
sblk() { awk -v n="$2" '/-- sync-pattern: begin/ { c++; on = (c == n); next } /-- sync-pattern: end/ { on = 0 } on' "$1" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//'; }
S0=$(sblk "$R/sql/json_primary.sql" 1); ok=1; nb=0
if [ "$(grep -c -- '-- sync-pattern: begin' "$R/sql/json_primary.sql")" != 2 ] || [ "$(grep -c -- '-- sync-pattern: begin' "$R/sql/list_alerts.sql")" != 1 ]; then ok=0; fail "history pattern: json_primary.sql needs two sync-pattern blocks and list_alerts.sql one"; fi
for spec in "$R/sql/json_primary.sql 1" "$R/sql/json_primary.sql 2" "$R/sql/list_alerts.sql 1"; do
  set -- $spec; nb=$((nb + 1)); [ "$(sblk "$1" "$2")" = "$S0" ] || { ok=0; fail "history pattern: sync block $2 of $(basename "$1") differs from the first one of sql/json_primary.sql" "$(sblk "$1" "$2")"; }
done
[ -n "$S0" ] && [ $ok = 1 ] && pass "history pattern: the $nb sync-pattern blocks (json_primary.sql twice, list_alerts.sql) are the same condition"
DS=$(grep 'function dgsync' "$R/sh/dglib.sh" | tr -s ' \t' ' '); ok=1
# the blocks are compared with their whitespace squeezed, so the literals are checked as written: one space, as in the log
sraw() { awk -v n="$2" '/-- sync-pattern: begin/ { c++; on = (c == n); next } /-- sync-pattern: end/ { on = 0 } on' "$1"; }
for spec in "$R/sql/json_primary.sql 1" "$R/sql/json_primary.sql 2" "$R/sql/list_alerts.sql 1"; do
  set -- $spec; B=$(sraw "$1" "$2")
  for t in "'%LAD:%'" "'%level SYNCHRONIZED%'" "'%is SYNCHRONIZED%'"; do case $B in *"$t"*) ;; *) ok=0; fail "history pattern: sync block $2 of $(basename "$1") lacks $t" ;; esac; done
done
for t in 'LAD:[0-9]+' 'level[ \t]+SYNCHRONIZED' 'is[ \t]+SYNCHRONIZED'; do case $DS in *"$t"*) ;; *) ok=0; fail "history pattern: dgsync() in sh/dglib.sh lacks $t" ;; esac; done
[ -n "$DS" ] && [ $ok = 1 ] && pass "history pattern: every token of dgsync() (LAD:, level, is, SYNCHRONIZED) is in the SQL sync blocks and the other way round"
nof "$R/sh/collect.sh" 'level[ \t]+SYNCHRONIZED' "history pattern: collect.sh carries no sync pattern of its own"
hasf "$R/sh/collect.sh" 'dgsync($0)' "history pattern: ... it calls dgsync() from sh/dglib.sh"
# alert_log_scan.sh and collect.sh use the awk list from dglib.sh, not their own
nof "$R/sh/alert_log_scan.sh" 'TNS-12535' "history pattern: alert_log_scan.sh carries no list of its own"
nof "$R/sh/collect.sh" 'ORA-03135' "history pattern: collect.sh carries no list of its own"
sh "$R/sh/alert_log_scan.sh" "$T/fixtures/logs/alert_list.log" 2026-11-06 20:30 21:00 > "$W/als.out" 2>&1
sed -n '/== 2\./,$p' "$W/als.out" > "$W/als2.out"
nof "$W/als2.out" 'RT_PMODE: PRIMARY' "alert_log_scan.sh: part 2 leaves out the routine PRIMARY lines"
nof "$W/als2.out" 'RT_PMODE: PHYSICAL' "alert_log_scan.sh: ... and PHYSICAL"
nof "$W/als2.out" 'reason ASYNC configuration' "alert_log_scan.sh: ... and reason ASYNC configuration"
hasf "$W/als2.out" '2026-11-06T20:38:07 LGWR (PID:4242): ORA-16198' "alert_log_scan.sh: ... and keeps the incidents"

# ---------------------------------------------------------------- lint
LB=
for f in "$R"/sh/*.sh "$T/run.sh" "$T/gate.sh" "$T/fixtures/bin/sqlplus"; do
  if sh -n "$f" 2>/dev/null && { [ -z "$DASH" ] || "$DASH" -n "$f" 2>/dev/null; }; then :; else LB=1; fail "lint: $(basename "$f") does not parse under sh${DASH:+ and dash}"; fi
done
[ -n "$LB" ] || pass "lint: every script parses under sh${DASH:+ and dash}"
# gawk and bash extensions that AIX or a minimal system lacks (comment lines are skipped)
hits=$(grep -nE 'gensub|strftime|mktime|systime\(|asorti?\(|PROCINFO|IGNORECASE|BEGINFILE|nextfile|\[\[ |<<<|date -d|readarray|mapfile|local |\$\{[A-Za-z_]+(,,|\^\^|//)' "$R"/sh/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
if [ -z "$hits" ]; then pass "lint: sh/*.sh use no gawk or bash extensions"; else fail "lint: gawk or bash extensions in sh/*.sh" "$hits"; fi
# an awk regex literal that starts with = (/=/, /=.*/) lexes as the /= operator on AIX awk: write [=] instead
hits=$(grep -nE '(^|[(,~!&|[:space:]])/=' "$R"/sh/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
if [ -z "$hits" ]; then pass "lint: no awk regex starts with = (AIX awk reads /= as an operator)"; else fail "lint: awk regex starting with = in sh/*.sh (use [=])" "$hits"; fi

# ---------------------------------------------------------------- episodes: several collection windows in one report (tests/sets.sh; its ok / FAIL / skip lines are counted here)
sh "$T/sets.sh" > "$W/sets.out" 2>&1; src=$?
sed '/^$/d; /^[0-9]* passed, /d' "$W/sets.out"
sf=$(grep -c '^FAIL  ' "$W/sets.out"); PASS=$((PASS + $(grep -c '^ok  ' "$W/sets.out"))); NFAIL=$((NFAIL + sf)); NSKIP=$((NSKIP + $(grep -c '^skip  ' "$W/sets.out")))
[ "$src" -eq 0 ] || [ "$sf" -gt 0 ] || fail "episodes: tests/sets.sh exited with status $src and no FAIL line"

echo
echo "$PASS passed, $NFAIL failed, $NSKIP skipped"
[ "$NFAIL" -eq 0 ]

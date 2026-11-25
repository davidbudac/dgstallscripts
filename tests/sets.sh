#!/bin/sh
# Tests for several collection windows in one report ("episodes"). Usage: sh tests/sets.sh      (tests/run.sh runs it too and counts its lines)
#
#   The report page splits the bundles it holds into sets (one per primary bundle; a standby bundle joins the primary with the same header window, else the one it overlaps most)
#   and analyses one set, chosen by ?ep=<n> in the address. Rendered in headless Chrome with gate.sh (GATE_HASH carries the query):
#   - three pairs with different windows, given in a mixed order: every ?ep=n gives exactly the claims and hand-over texts of that pair alone (the golden files of run.sh)
#   - no query shows the oldest window; ?ep=99, ?ep=x, ?ep=2x and ?ep=0 fall back to it; no JavaScript error; ?ep=2#handover opens the hand-over pane of episode 2
#   - extract.py --sets: the rows in chronological order, the shown row marked, the others linked, the bundles and what the alert lines hold; no selector for one pair
#   - a pair whose windows differ by a minute is one set; two pairs with overlapping windows are two sets; a standby bundle joins the primary with the same window, also
#     when another primary overlaps it as much; hosts with different UTC offsets still pair by their instants
#   - make_report.sh says on stderr that it holds several windows, and nothing for one pair; the same report under sh and dash
# Output as in run.sh: "ok", "FAIL" or "skip" and the name; the exit status is 0 only when nothing failed. Skipped as a whole when there is no Chrome or python3.

T=$(cd "$(dirname "$0")" && pwd); R=$(dirname "$T")
W=${TMPDIR:-/tmp}/dgr-sets.$$; mkdir -p "$W" || exit 1
trap 'rm -rf "$W"' 0 1 2 15
PASS=0 NFAIL=0 NSKIP=0
pass() { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { NFAIL=$((NFAIL + 1)); echo "FAIL  $1"; [ -z "$2" ] || echo "$2" | sed 's/^/          /'; }
skip() { NSKIP=$((NSKIP + 1)); echo "skip  $1"; }
same() { if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$(diff "$2" "$3" | head -12)"; fi; }   # name, got, expected
has_l() { if grep -Eq "$2" "$1"; then pass "$3"; else fail "$3" "no line matches: $2"; fi; }          # file, regex, name
no_l() { if grep -Eq "$2" "$1"; then fail "$3" "$(grep -E "$2" "$1" | head -3 | cut -c1-240)"; else pass "$3"; fi; }
summary() { echo; echo "$PASS passed, $NFAIL failed, $NSKIP skipped"; [ "$NFAIL" -eq 0 ]; }
DASH=; [ -x /bin/dash ] && DASH=/bin/dash

if ! sh "$T/gate.sh" --have-chrome; then skip "episodes: no Chrome or python3 found, nothing rendered"; summary; exit; fi

for SH in sh $DASH; do if "$SH" -n "$0" 2>/dev/null; then :; else fail "episodes: tests/sets.sh does not parse under $SH"; fi; done

python3 "$T/bundle_tool.py" gen "$W/gen" > /dev/null
G=$W/gen; E=$R/examples
rend() { r_n=$1; r_h=$2; shift 2; GATE_HASH=$r_h sh "$T/gate.sh" "$W/$r_n" "$@" || fail "episodes: render $r_n failed"; python3 "$T/extract.py" "$W/$r_n.dom" --sets > "$W/$r_n.sets"; }   # name, address suffix, bundles
nojs() { if [ -s "$W/$1.js" ]; then fail "$2: JavaScript console errors" "$(head -5 "$W/$1.js")"; else pass "$2: no JavaScript console errors"; fi; }
# a copy of a bundle with the from and to of its header and meta records replaced (the times of its records stay): file, from, to
win() { sed -e "/^{\"t\":\"bundle\"/s/\"from\":\"[^\"]*\"/\"from\":\"$2\"/" -e "/^{\"t\":\"bundle\"/s/\"to\":\"[^\"]*\"/\"to\":\"$3\"/" \
             -e "/^{\"t\":\"meta\"/s/\"from\":\"[^\"]*\"/\"from\":\"$2\"/" -e "/^{\"t\":\"meta\"/s/\"to\":\"[^\"]*\"/\"to\":\"$3\"/" "$1"; }
# the texts of one render: the claims against a golden file, the two hand-over texts against theirs. name, claims golden, hand-over golden name, label
alone() {
  python3 "$T/extract.py" "$W/$1.dom" --net > "$W/$1.net"; python3 "$T/extract.py" "$W/$1.dom" --ticket > "$W/$1.ticket"
  same "$4: the claims are those of the pair alone" "$W/$1.txt" "$T/expected/$2"
  same "$4: the hand-over text for the network team is that of the pair alone" "$W/$1.net" "$T/expected/handover_$3.net.txt"
  same "$4: the hand-over text for the ticket is that of the pair alone" "$W/$1.ticket" "$T/expected/handover_$3.ticket.txt"
}

# ---------------------------------------------------------------- three pairs with different windows, the files in a mixed order: 1 = example (11-13), 2 = quiet (11-20 09:20), 3 = two (11-20 10:00)
ALL3="$G/two_primary.jsonl $E/sample_primary.jsonl $G/quiet_primary.jsonl $G/two_standby.jsonl $E/sample_standby.jsonl $G/quiet_standby.jsonl"
rend k1 '?ep=1' $ALL3; rend k2 '?ep=2' $ALL3; rend k3 '?ep=3' $ALL3
for k in 1 2 3; do nojs k$k "three pairs, ?ep=$k"; done
alone k1 baseline.txt sample "three pairs, ?ep=1 (the example)"
alone k2 scenario_quiet.txt quiet "three pairs, ?ep=2 (quiet)"
alone k3 scenario_two.txt two "three pairs, ?ep=3 (two incidents)"
# the footer lists the bundles the page was built from: those of the episode shown
for k in 1 2 3; do grep -o '<footer id="foot">[^<]*' "$W/k$k.dom" | sed 's/^<footer id="foot">//' > "$W/k$k.foot"; done
has_l "$W/k1.foot" '^Built from sample_primary.jsonl \(Primary, prim-host, collected [^)]*\); sample_standby.jsonl \(Standby, stby-host, collected [^)]*\)\. ' "three pairs, ?ep=1: the footer lists the two bundles of the example"
no_l "$W/k1.foot" 'quiet_|two_' "three pairs, ?ep=1: the footer lists nothing of the other pairs"
has_l "$W/k3.foot" '^Built from two_primary.jsonl \(Primary, prim-host, collected [^)]*\); two_standby.jsonl \(Standby, stby-host, collected [^)]*\)\. ' "three pairs, ?ep=3: the footer lists the two bundles of that pair"
no_l "$W/k3.foot" 'sample_|quiet_' "three pairs, ?ep=3: the footer lists nothing of the other pairs"

# no query, and queries that are not an episode: the oldest window
rend q0 '' $ALL3; rend q99 '?ep=99' $ALL3; rend qx '?ep=x' $ALL3; rend q2x '?ep=2x' $ALL3; rend q00 '?ep=0' $ALL3
for q in q0 q99 qx q2x q00; do nojs $q "three pairs, $q"; done
same "three pairs, no query: the page shows episode 1, the oldest window" "$W/q0.txt" "$W/k1.txt"
same "three pairs, ?ep=99: falls back to episode 1" "$W/q99.txt" "$W/k1.txt"
same "three pairs, ?ep=x: falls back to episode 1" "$W/qx.txt" "$W/k1.txt"
same "three pairs, ?ep=2x: not a number, falls back to episode 1" "$W/q2x.txt" "$W/k1.txt"
same "three pairs, ?ep=0: falls back to episode 1" "$W/q00.txt" "$W/k1.txt"
for q in q0 q99 qx q2x q00; do has_l "$W/$q.sets" '^SETS: Episode 1 of 3 in this report$' "three pairs, $q: the selector says episode 1 of 3"; done

# the selector
has_l "$W/k2.sets" '^SETS: Episode 2 of 3 in this report$' "selector: the heading says which episode of how many"
has_l "$W/k2.sets" '^SETNAV: Previous \?ep=1 \| Next \?ep=3$' "selector: Previous and Next link to the neighbours"
has_l "$W/k1.sets" '^SETNAV: Next \?ep=2 \| Previous none$' "selector: the first episode has a Next link and no Previous link"
has_l "$W/k3.sets" '^SETNAV: Previous \?ep=2 \| Next none$' "selector: the last episode has a Previous link and no Next link"
[ "$(grep -c '^SET [0-9]' "$W/k2.sets")" = 3 ] && pass "selector: one row per set (3)" || fail "selector: rows" "$(cat "$W/k2.sets")"
awk -F' [|] ' '/^SET [0-9]/ { if (prev != "" && $2 <= prev) bad = 1; prev = $2 } END { exit bad }' "$W/k2.sets" && pass "selector: the windows are in chronological order" || fail "selector: windows not in order" "$(cat "$W/k2.sets")"
has_l "$W/k2.sets" '^SET 1 \| 2026-11-13 20:35:00 – 2026-11-13 20:58:00 \| Primary prim-host sample_primary.jsonl ; Standby stby-host sample_standby.jsonl \| ' "selector: row 1 is the example: window as in the header, both bundles with side, host and file"
has_l "$W/k2.sets" '^SET 2 \| 2026-11-20 09:20:00 – 2026-11-20 09:45:00 \| Primary prim-host quiet_primary.jsonl ; Standby stby-host quiet_standby.jsonl \| ' "selector: row 2 is the quiet pair"
has_l "$W/k2.sets" '^SET 3 \| 2026-11-20 10:00:00 – 2026-11-20 10:45:00 \| Primary prim-host two_primary.jsonl ; Standby stby-host two_standby.jsonl \| ' "selector: row 3 is the pair with two incidents"
has_l "$W/k2.sets" '^SET 2 \| .* \| shown$' "selector: the row of the episode on the page is marked shown"
has_l "$W/k2.sets" '^SET 1 \| .* \| link \?ep=1$' "selector: row 1 links to ?ep=1"
has_l "$W/k2.sets" '^SET 3 \| .* \| link \?ep=3$' "selector: row 3 links to ?ep=3"
[ "$(grep -c ' | shown$' "$W/k2.sets")" = 1 ] && pass "selector: exactly one row is marked" || fail "selector: marked rows" "$(cat "$W/k2.sets")"
has_l "$W/k2.sets" '^SET 1 \| .* \| first line 20:38:58 \(primary\): ORA-16198, LAD:2 UNSYNCHRONIZED, .*TNS-12535.* \| link' "selector: row 1 gives the time of the first Data Guard line and its labels, in the order found"
has_l "$W/k2.sets" '^SET 2 \| .* \| no Data Guard error line in the window \| shown$' "selector: a set whose alert lines hold no Data Guard error says so"
has_l "$W/k2.sets" '^SET 3 \| .* \| first line 10:05:30 \(primary\): ORA-16198, LAD:2 UNSYNCHRONIZED, .*ORA-03135' "selector: row 3 gives its first line and its labels"
no_l "$W/k2.sets" 'reason ASYNC|NaN|undefined' "selector: no stray text in the rows"
has_l "$W/k2.dom" '<title>[^<]* · episode 2 of 3</title>' "selector: the document title says which episode it shows"

# ?ep=2#handover: episode 2 on the hand-over pane
rend ho '?ep=2#handover' $ALL3; nojs ho "three pairs, ?ep=2#handover"
python3 "$T/extract.py" "$W/ho.dom" --ui > "$W/ho.ui"
has_l "$W/ho.ui" '^panes at start: report:hidden handover:shown; tab handover; address #handover$' "?ep=2#handover: opens the hand-over pane"
alone ho scenario_quiet.txt quiet "?ep=2#handover"
has_l "$W/ho.sets" '^SETS: Episode 2 of 3 in this report$' "?ep=2#handover: the selector says episode 2 of 3"

# ---------------------------------------------------------------- one pair: no selector
rend one '' "$G/two_primary.jsonl" "$G/two_standby.jsonl"; nojs one "one pair"
[ ! -s "$W/one.sets" ] && pass "one pair: no selector (--sets prints nothing)" || fail "one pair: a selector on the page" "$(cat "$W/one.sets")"
no_l "$W/one.dom" 'episode [0-9]+ of [0-9]+</title>' "one pair: the document title has no episode"
same "one pair: the claims are the golden ones" "$W/one.txt" "$T/expected/scenario_two.txt"
# a primary and a standby bundle whose windows differ by a minute (hand-collected): still one set
mkdir -p "$W/d1"; cp "$G/two_primary.jsonl" "$W/d1/"; win "$G/two_standby.jsonl" "2026-11-20 10:01:00" "2026-11-20 10:46:00" > "$W/d1/two_standby.jsonl"
rend d1 '' "$W/d1/two_primary.jsonl" "$W/d1/two_standby.jsonl"; nojs d1 "windows a minute apart"
[ ! -s "$W/d1.sets" ] && pass "windows a minute apart: one primary and one standby bundle are one set, no selector" || fail "windows a minute apart: a selector on the page" "$(cat "$W/d1.sets")"
same "windows a minute apart: analysed as before, the claims are those of the pair" "$W/d1.txt" "$T/expected/scenario_two.txt"

# ---------------------------------------------------------------- overlapping windows are two sets, never pooled
mkdir -p "$W/ov"; cp "$G/two_primary.jsonl" "$G/two_standby.jsonl" "$W/ov/"
win "$G/two_primary.jsonl" "2026-11-20 10:30:00" "2026-11-20 11:15:00" > "$W/ov/b_primary.jsonl"; win "$G/two_standby.jsonl" "2026-11-20 10:30:00" "2026-11-20 11:15:00" > "$W/ov/b_standby.jsonl"
OV="$W/ov/b_standby.jsonl $W/ov/two_primary.jsonl $W/ov/b_primary.jsonl $W/ov/two_standby.jsonl"
rend ov '?ep=1' $OV; nojs ov "overlapping windows"
[ "$(grep -c '^SET [0-9]' "$W/ov.sets")" = 2 ] && pass "overlapping windows: two sets" || fail "overlapping windows: rows" "$(cat "$W/ov.sets")"
has_l "$W/ov.sets" '^SET 1 \| 2026-11-20 10:00:00 – 2026-11-20 10:45:00 \| Primary prim-host two_primary.jsonl ; Standby stby-host two_standby.jsonl \| ' "overlapping windows: set 1 holds its own two bundles only"
has_l "$W/ov.sets" '^SET 2 \| 2026-11-20 10:30:00 – 2026-11-20 11:15:00 \| Primary prim-host b_primary.jsonl ; Standby stby-host b_standby.jsonl \| ' "overlapping windows: set 2 holds its own two bundles only"
same "overlapping windows: episode 1 is analysed as its pair alone, nothing pooled from the overlapping one" "$W/ov.txt" "$T/expected/scenario_two.txt"
# no identical window: the standby bundle joins the primary it overlaps most (10:31-11:16: 44 minutes with set 2, 14 with set 1)
mkdir -p "$W/ov2"; win "$G/two_standby.jsonl" "2026-11-20 10:31:00" "2026-11-20 11:16:00" > "$W/ov2/c_standby.jsonl"
rend ov2 '' "$W/ov/two_primary.jsonl" "$W/ov/b_primary.jsonl" "$W/ov2/c_standby.jsonl"; nojs ov2 "a standby bundle that overlaps two primary bundles"
has_l "$W/ov2.sets" '^SET 1 \| 2026-11-20 10:00:00 – 2026-11-20 10:45:00 \| Primary prim-host two_primary.jsonl ; no standby bundle \| ' "overlap rule: the standby bundle does not join the earlier primary bundle that it overlaps less"
has_l "$W/ov2.sets" '^SET 2 \| 2026-11-20 10:30:00 – 2026-11-20 11:15:00 \| Primary prim-host b_primary.jsonl ; Standby stby-host c_standby.jsonl \| ' "overlap rule: ... it joins the one it overlaps most"
# identical header window beats overlap: 10:50-10:55 overlaps both primary bundles by 5 minutes (a tie, which would go to the earlier set), and is the window of the second
mkdir -p "$W/id"; win "$G/two_primary.jsonl" "2026-11-20 10:00:00" "2026-11-20 11:00:00" > "$W/id/a_primary.jsonl"; win "$G/two_primary.jsonl" "2026-11-20 10:50:00" "2026-11-20 10:55:00" > "$W/id/b_primary.jsonl"
win "$G/two_standby.jsonl" "2026-11-20 10:50:00" "2026-11-20 10:55:00" > "$W/id/b_standby.jsonl"
rend id '' "$W/id/b_standby.jsonl" "$W/id/a_primary.jsonl" "$W/id/b_primary.jsonl"; nojs id "a standby bundle with the window of the later primary bundle"
has_l "$W/id.sets" '^SET 1 \| 2026-11-20 10:00:00 – 2026-11-20 11:00:00 \| Primary prim-host a_primary.jsonl ; no standby bundle \| ' "identical window: the earlier primary bundle gets no standby bundle"
has_l "$W/id.sets" '^SET 2 \| 2026-11-20 10:50:00 – 2026-11-20 10:55:00 \| Primary prim-host b_primary.jsonl ; Standby stby-host b_standby.jsonl \| ' "identical window: the standby bundle joins the primary bundle with the same header window"
# a standby bundle that overlaps no primary bundle is a set of its own, in its place by window (09:20 is before the 10:00 of the pair)
rend lone '' "$G/two_primary.jsonl" "$G/two_standby.jsonl" "$G/quiet_standby.jsonl"; nojs lone "a standby bundle with no primary bundle of its window"
has_l "$W/lone.sets" '^SET 1 \| 2026-11-20 09:20:00 – 2026-11-20 09:45:00 \| no primary bundle ; Standby stby-host quiet_standby.jsonl \| ' "a standby bundle that overlaps no primary bundle is a set of its own, marked no primary bundle"
has_l "$W/lone.sets" '^SET 2 \| 2026-11-20 10:00:00 – 2026-11-20 10:45:00 \| Primary prim-host two_primary.jsonl ; Standby stby-host two_standby.jsonl \| ' "... and the pair of the primary bundle is the next set"

# ---------------------------------------------------------------- hosts with different UTC offsets: the tzoff pair next to the drift pair (both 10:00-10:30 or 10:00-10:45 UTC)
# tzoff: primary 11:00-11:45 at +01:00, standby 10:00-10:45 at +00:00. The standby's own strings equal no primary window here; by instants it overlaps its own primary for 45 minutes and the drift primary for 30
rend tz0 '' "$G/tzoff_primary.jsonl" "$G/tzoff_standby.jsonl" "$G/drift_primary.jsonl" "$G/drift_standby.jsonl"
n=$(awk -F' [|] ' '/^SET [0-9]/ && $3 ~ /tzoff_primary.jsonl ; Standby stby-host tzoff_standby.jsonl/ { sub(/^SET /, "", $1); print $1 }' "$W/tz0.sets")
if [ -n "$n" ]; then pass "different UTC offsets: the tzoff standby bundle sits in the set of the tzoff primary bundle (set $n)"; else fail "different UTC offsets: tzoff bundles not paired" "$(cat "$W/tz0.sets")"; n=2; fi
nojs tz0 "tzoff next to drift"
has_l "$W/tz0.sets" 'drift_primary.jsonl ; Standby stby-host drift_standby.jsonl' "different UTC offsets: the drift pair is a set of its own, with its own standby bundle"
rend tz "?ep=$n" "$G/tzoff_primary.jsonl" "$G/tzoff_standby.jsonl" "$G/drift_primary.jsonl" "$G/drift_standby.jsonl"; nojs tz "tzoff next to drift, ?ep=$n"
alone tz scenario_tzoff.txt tzoff "tzoff next to drift, ?ep=$n"

# ---------------------------------------------------------------- more than eight episodes: the table is in a disclosure, the heading says which one is shown
mkdir -p "$W/nine"; NINE=
for i in 1 2 3 4 5 6 7 8 9; do
  win "$G/quiet_primary.jsonl" "2026-10-0$i 10:00:00" "2026-10-0$i 10:30:00" > "$W/nine/e${i}_primary.jsonl"; win "$G/quiet_standby.jsonl" "2026-10-0$i 10:00:00" "2026-10-0$i 10:30:00" > "$W/nine/e${i}_standby.jsonl"
  NINE="$NINE $W/nine/e${i}_standby.jsonl $W/nine/e${i}_primary.jsonl"
done
rend nine '?ep=5' $NINE; nojs nine "nine episodes, ?ep=5"
has_l "$W/nine.sets" '^SETS: Episode 5 of 9 in this report$' "nine episodes: the heading says episode 5 of 9"
[ "$(grep -c '^SET [0-9]' "$W/nine.sets")" = 9 ] && pass "nine episodes: one row per set (9)" || fail "nine episodes: rows" "$(cat "$W/nine.sets")"
has_l "$W/nine.sets" '^SET 5 \| 2026-10-05 10:00:00 – 2026-10-05 10:30:00 \| Primary prim-host e5_primary.jsonl ; Standby stby-host e5_standby.jsonl \| .* \| shown$' "nine episodes: row 5 is the fifth window, marked shown"
[ "$(grep -c ' | shown$' "$W/nine.sets")" = 1 ] && pass "nine episodes: exactly one row is marked" || fail "nine episodes: marked rows" "$(grep -c ' | shown$' "$W/nine.sets")"
for r in nine k2; do python3 "$T/extract.py" "$W/$r.dom" --strip > "$W/$r.stripped"; done   # the page without its script text, which holds the selector's template
has_l "$W/nine.stripped" '<details class="epd"><summary>All 9 episodes</summary>' "nine episodes: the table is in a disclosure under the heading"
has_l "$W/k2.stripped" '<div class="cc flush"><div class="tbl"><table class="epst">' "three episodes: the table is shown"
no_l "$W/k2.stripped" '<details class="epd">' "three episodes: no disclosure"
# captions: the selector card has its caption in the same markup as every card, so --captions lists it ("length | heading | caption"); none is longer than 120 characters
for r in k2 nine; do
  python3 "$T/extract.py" "$W/$r.dom" --captions > "$W/$r.captions"
  has_l "$W/$r.captions" '^[0-9]+ \| Episode [0-9]+ of [0-9]+ in this report \| The bundles hold [0-9]+ collection windows; one is shown at a time\. \?ep=<n> in the address chooses it\.$' "captions, $r: the selector card is listed with its caption"
  mx=$(cut -d' ' -f1 "$W/$r.captions" | sort -n | tail -1); n=$(wc -l < "$W/$r.captions" | tr -d ' ')
  if [ "$n" -ge 20 ] && [ "$mx" -le 120 ]; then pass "captions, $r: $n cards, the longest caption has $mx characters (at most 120)"; else fail "captions, $r: $n cards, the longest caption has $mx characters" "$(awk -F' [|] ' '$1 + 0 > 120' "$W/$r.captions" | head -3 | cut -c1-200)"; fi
done
sel=$(grep ' | Episode [0-9]* of [0-9]* in this report | ' "$W/k2.captions" | cut -d' ' -f1)
[ -n "$sel" ] && [ "$((sel + 2))" -le 120 ] && pass "captions: the selector's caption has $sel characters for 3 episodes, $((sel + 2)) for 999 (at most 120)" || fail "captions: the selector's caption is $sel characters"

# ---------------------------------------------------------------- make_report.sh: a hint on stderr, the same page under sh and dash
for SH in sh $DASH; do
  "$SH" "$R/sh/make_report.sh" -o "$W/m3_$(basename "$SH").html" $ALL3 2> "$W/m3_$(basename "$SH").err"
  "$SH" "$R/sh/make_report.sh" -o "$W/m1_$(basename "$SH").html" "$G/two_primary.jsonl" "$G/two_standby.jsonl" 2> "$W/m1_$(basename "$SH").err"
  "$SH" "$R/sh/make_report.sh" -o "$W/md_$(basename "$SH").html" "$W/d1/two_primary.jsonl" "$W/d1/two_standby.jsonl" 2> "$W/md_$(basename "$SH").err"
  b=$(basename "$SH")
  has_l "$W/m3_$b.err" '^3 collection windows: the report holds them as episodes, one shown at a time \(selector at the top, \?ep=<n> in the address\)\.$' "make_report.sh under $b: three pairs with three windows: the note on stderr"
  no_l "$W/m1_$b.err" 'collection windows' "make_report.sh under $b: one pair: no note"
  no_l "$W/md_$b.err" 'collection windows' "make_report.sh under $b: a pair whose windows differ by a minute: no note"
  has_l "$W/m3_$b.err" '^Report written: ' "make_report.sh under $b: ... and still says where the report is"
done
if [ -n "$DASH" ]; then
  same "make_report.sh: the report of three pairs is the same under sh and dash" "$W/m3_sh.html" "$W/m3_dash.html"
  grep 'collection windows' "$W/m3_sh.err" > "$W/m3_sh.note"; grep 'collection windows' "$W/m3_dash.err" > "$W/m3_dash.note"
  same "make_report.sh: the note is the same under sh and dash" "$W/m3_sh.note" "$W/m3_dash.note"
else skip "make_report.sh under dash: /bin/dash not found"; fi
# the page of three pairs holds every bundle once, as the plain embedding it always was
n=$(grep -c '^<script type="text/plain" class="dgr-bundle" data-file="' "$W/m3_sh.html")
[ "$n" = 6 ] && pass "make_report.sh: the six bundles are embedded one by one, as before" || fail "make_report.sh: $n embedded bundles, expected 6"

summary

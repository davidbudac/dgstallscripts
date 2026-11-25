#!/usr/bin/env python3
# Prints the derived claims of a rendered report DOM (headless Chrome --dump-dom) as plain text.
#   extract.py DOM          the claims: header, stat cards, signals (one block per incident or signal: its Observed rows and its Reading rows),
#                           ruled out, not checked, the coverage table, notes
#   extract.py DOM --mask   the same with every clock time and date replaced by <T> (a window that moved across midnight)
#   extract.py DOM --strip  the whole DOM without the contents of <script> elements (the embedded bundles), to compare renders
#   extract.py DOM --facts  the facts list the report built (the <script id="dgr-facts"> JSON): one line per fact
#   extract.py DOM --net    the "For the network team" text, one block per incident (a line "#### incident N" before each)
#   extract.py DOM --ticket the "For the ticket" text, the same way
#   extract.py DOM --parts  the sections of the newer collector's data: standby receive side, baseline, dgstatus rows, destination histogram, network history, recurrence view,
#                           and the cards built from the signals: the coverage reach column, explanations, before the next occurrence, the sequence of the incident
# Line prefixes: SUB BADGES NOTICES STAT / SIGNAL OBSERVED READING / RULED NONEFOUND NOTCHECKED HINT / COV / HISTNOTE FGNOTE
# --parts adds: REACH (the "Reached the window" column) EXPL* (explanation tables) NEXT (hints, once each) SEQ* (the sequence view)
#   extract.py DOM --captions | --order | --readings   the card captions with their length, the sections in document order, the Reading disclosures and whether each is closed
#   extract.py DOM --ui     the log of the button, tab and link clicks of hover.html;  --delivered copy|dl net|ticket  the texts Copy / Download .txt delivered, per incident
#   extract.py DOM --cards  the cards of the lookback and impact records: EP* (episodes side by side), WHO* (who waited), RECURBAR* (the activity bars of the day-and-hour grid)
#   extract.py DOM --sets   the episode selector of a report whose bundles hold several collection windows: SETS (its heading), SETNAV (Previous, Next), SET n | window | bundles | alert lines | shown or link ?ep=n per row;
#                           nothing when the report has no selector
import json, re, sys, html
d = open(sys.argv[1], encoding='utf-8').read()
mode = sys.argv[2] if len(sys.argv) > 2 else ''
if mode == '--strip':
    sys.stdout.write(re.sub(r' style=""', '', re.sub(r'<script.*?</script>', '<script></script>', d, flags=re.S)))
    sys.exit(0)
MASK = re.compile(r'(?:\d\d/\d\d/\d{4} )?(?:\d{4}-)?(?:\d\d-\d\d )?\d\d:\d\d(?::\d\d(?:\.\d+)?)?')
def emit(s):
    print(MASK.sub('<T>', s) if mode == '--mask' else s)
def txt(s): return re.sub(r'\s+', ' ', html.unescape(re.sub(r'<svg.*?</svg>|<[^>]+>', ' ', s, flags=re.S))).strip()
def block(id_):
    m = re.search(r'<(\w+)[^>]*\bid="%s"[^>]*>' % id_, d)
    if not m: return ''
    tag, i, depth = m.group(1), m.end(), 1
    for t in re.finditer(r'<(/?)%s\b[^>]*>' % tag, d[i:]):
        depth += -1 if t.group(1) else 1
        if depth == 0: return d[i:i + t.start()]
    return d[i:]
def cells(row, cls=None):
    return [txt(x) for x in re.findall(r'<span class="%s"[^>]*>(.*?)</span>' % cls, row, flags=re.S)] if cls else []
if mode in ('--net', '--ticket'):
    kind = mode[2:]
    for m in re.finditer(r'<pre class="hot[^"]*" data-ho="%s" data-inc="(\d+)"[^>]*>(.*?)</pre>' % kind, d, flags=re.S):
        print('#### incident %s' % m.group(1))
        print(html.unescape(m.group(2)))
    sys.exit(0)
if mode == '--parts':
    def rows(id_):
        out = []
        for r in re.findall(r'<tr[^>]*>(.*?)</tr>', block(id_), flags=re.S):
            c = [txt(x) for x in re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', r, flags=re.S)]
            if c and not (len(c) > 1 and c[0] in ('Event', 'Process', 'Interval', 'Host') and r.lstrip().startswith('<th')): out.append(' | '.join(c))
        return out
    emit('HISTCAPT: ' + txt(block('histCapt')))
    emit('HISTFOOT: ' + txt(block('histFoot')))
    emit('HISTTABS: ' + ' | '.join(txt(x) for x in re.findall(r'<button[^>]*>(.*?)</button>', block('histTabs'), flags=re.S)))
    emit('ALNOTE: ' + txt(block('alNote')))
    emit('ALTABS: ' + ' | '.join(txt(x) for x in re.findall(r'<button[^>]*>(.*?)</button>', block('alFilter'), flags=re.S)))
    emit('DGROWS: %d' % len(re.findall(r'<tr id="d\d+" class="dg', block('alog'))))
    for r in re.findall(r'<tr id="d\d+" class="dg[^"]*">(.*?)</tr>', block('alog'), flags=re.S): emit('  DGROW: ' + ' | '.join(txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', r, flags=re.S)))
    emit('BASENOTE: ' + txt(block('baseNote')))
    for r in rows('base'): emit('  BASE: ' + r)
    emit('RFSNOTE: ' + txt(block('rfsNote')))
    for r in rows('rfsEv'): emit('  RFSEV: ' + r)
    emit('SBNOTE: ' + txt(block('sbNote')))
    for r in rows('sbTx'): emit('  SBTX: ' + r)
    emit('PROCNOTE: ' + txt(block('procNote')))
    for r in rows('sbProc'): emit('  SBPROC: ' + r)
    emit('SBPROCTXT: ' + txt(block('sbProc'))[-200:])
    emit('NETCHART: ' + ' | '.join(txt(x) for x in re.findall(r'<h2[^>]*>(.*?)</h2>', block('netChart'), flags=re.S)))   # the sampler chart sits with the charts, the other network cards in #network
    emit('NETWORK CARDS: ' + ' | '.join(txt(x) for x in re.findall(r'<(?:h2|div class="subh")[^>]*>(.*?)</(?:h2|div)>', block('network'), flags=re.S)))
    sar = rows('sar'); emit('SARROWS: %d, of them overlapping an incident: %d' % (len(sar), len([r for r in sar if ' incident ' in r])))
    for r in [r for r in sar if ' incident ' in r and ('| -' in r or 'ETCP' in r or 'eth1 |' in r or 'eth0' in r)][:8]: emit('  SAR: ' + r)
    emit('SARCARD: ' + txt(block('sarCard'))[-260:] if '<section class="card" id="sarCard"' in d else 'SARCARD: none')
    emit('CONNROWS: %d' % len(re.findall(r'<tr>', block('connCard'))))
    emit('RECURNOTE: ' + txt(block('recurNote')))
    emit('HISTREADING: ' + txt(block('histReading')))
    emit('RECURCELLS: %d' % len(re.findall(r'data-tip="[^"]*episode', block('recurViz'))))
    for r in re.findall(r'<tr><td style="font-weight:500">(.*?)</tr>', block('cfg'), flags=re.S): pass
    for r in re.findall(r'<tr><td>((?:Endpoint|sqlnet\.ora|OS TCP)[^<]*)</td>(.*?)</tr>', block('cfg'), flags=re.S): emit('  CFG: ' + txt(r[0]) + ' | ' + ' | '.join(txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', r[1], flags=re.S)))
    # the coverage table's last column: does each source reach the window
    reach = re.findall(r'<tr data-cov="([^"]*)">(.*?)</tr>', block('covTbl'), flags=re.S)
    if not reach: emit('REACH: no coverage rows')
    for key, row in reach: emit('REACH: %s | %s' % (key, ([txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', row, flags=re.S)] + [''] * 7)[6]))
    # explanations and what the bundles hold: one table per incident
    emit('EXPLNOTE: ' + txt(block('explNote')))
    ex = block('explBody')
    if '<table' not in ex: emit('EXPL: ' + txt(ex))
    for part in re.split(r'(?=<div class="exh">)', ex)[1:]:
        emit('EXPL: ' + txt(re.search(r'<div class="exh">(.*?)</div>', part, flags=re.S).group(1)))
        emit('  EXPLEVERY: ' + txt(re.search(r'<div class="exev">(.*?)</div>', part, flags=re.S).group(1)))
        for rid, row in re.findall(r'<tr data-row="([^"]*)">(.*?)</tr>', part, flags=re.S):
            lab = txt(re.search(r'<td class="lab">(.*?)</td>', row, flags=re.S).group(1))
            cols = [' ; '.join(txt(y) for y in re.findall(r'<div[^>]*>(.*?)</div>', x, flags=re.S)) for x in re.findall(r'<td class="cell"[^>]*>(.*?)</td>', row, flags=re.S)]
            emit('  EXPLROW: %s | Observed: %s | Ruled out: %s | None found: %s | Not checked: %s' % ((lab,) + tuple(cols)))
        emit('  EXPLUNPLACED: ' + txt(re.search(r'<div class="exsub" data-unplaced[^>]*>(.*?)</div>', part, flags=re.S).group(1)))
    # before the next occurrence: the hints, each once, with the entries they concern
    nb = block('nextBody')
    if 'class="nx"' not in nb: emit('NEXT: ' + txt(nb))
    for part in re.split(r'(?=<div class="nx")', nb)[1:]:
        emit('NEXT: ' + txt(re.search(r'<div class="nt">(.*?)</div>', part, flags=re.S).group(1)))
        for cmd in re.findall(r'<code>(.*?)</code>', part, flags=re.S): emit('  CMD: ' + txt(cmd))
        emit('  FOR: ' + txt(re.search(r'<div class="ne">(.*?)</div>', part, flags=re.S).group(1)))
    # the sequence of the incident: panels, lanes, marks
    emit('SEQNOTE: ' + txt(block('seqNote')))
    sb = block('seqBody')
    if 'class="seqv' not in sb: emit('SEQ: ' + txt(sb))
    for part in re.split(r'(?=<div class="seqv)', sb)[1:]:
        emit('SEQ: ' + txt(re.search(r'<div class="exh">(.*?)</div>', part, flags=re.S).group(1)))
        if 'no event of this incident' in part.lower(): emit('  SEQEMPTY'); continue
        emit('  SEQARIA: ' + html.unescape(re.search(r'aria-label="([^"]*)"', part).group(1)))
        for t, rg in re.findall(r'<text x="0" y="[\d.]+" font-size="12.5" font-weight="600"[^>]*>(.*?)</text><text[^>]*>(.*?)</text>', part, flags=re.S): emit('  SEQPANEL: %s | %s' % (txt(t), txt(rg)))
        for sd in sorted(set(re.findall(r'>no (primary|standby) bundle</text>', part))): emit('  SEQLANE: no %s bundle' % sd)
        emit('  SEQMARKS: %d shapes with a tooltip, %d margin bands, %d margin scale marks' % (len(re.findall(r'<(?:path|rect)[^>]* data-tip=', part)), len(re.findall(r'stroke-dasharray="3 2"', part)), len(re.findall(r'cross-host margin', part))))
        for n, li in re.findall(r'<li[^>]*data-n="(\d+)"[^>]*>(.*?)</li>', part, flags=re.S):
            c = [txt(x) for x in re.findall(r'<span class="(?:w mono|tx|pr)"[^>]*>(.*?)</span>', li, flags=re.S)]
            host = txt(re.search(r'<span class="badge[^"]*">(?:<span class="dot"></span>)?(.*?)</span>', li, flags=re.S).group(1))
            emit('  SEQMARK %s | %s | %s | %s | %s' % (n, c[0], host, c[1], c[2]))
    sys.exit(0)
if mode == '--cards':
    rv = block('recurViz')
    emit('RECURBARS: %d RMAN bars, %d job bars; legend: %s' % (len(re.findall(r'<rect[^>]* data-tip="RMAN ', rv)), len(re.findall(r'<rect[^>]* data-tip="Job ', rv)), txt(re.search(r'<div class="legend"[^>]*>(.*?)</div>', rv, flags=re.S).group(1)) if 'id="recurLegend"' in rv else 'none'))
    tips = sorted(set(html.unescape(x) for x in re.findall(r'<rect[^>]* data-tip="((?:RMAN|Job) [^"]*)"', rv)))
    for tp in [x for x in tips if x.startswith('Job ') or 'DB INCR' in x] + [x for x in tips if not (x.startswith('Job ') or 'DB INCR' in x)][:2]: emit('  RECURBAR: ' + tp.replace('|', ' | '))
    # episodes side by side (the newer records laid beside each incident and episode of the history)
    emit('EPNOTE: ' + txt(block('epNote')))
    et = block('epTbl')
    if '<table' not in et: emit('EP: ' + txt(et))
    else:
        emit('EPHEAD: ' + ' | '.join(txt(x) for x in re.findall(r'<th[^>]*>(.*?)</th>', et, flags=re.S)))
        for rid, row in re.findall(r'<tr data-ep="([^"]*)"[^>]*>(.*?)</tr>', et, flags=re.S):
            cols = [' / '.join(txt(y) for y in re.findall(r'<div[^>]*>(.*?)</div>', x, flags=re.S)) or txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', row, flags=re.S)]
            emit('  EPROW %s | %s' % (rid, ' | '.join(cols)))
    for k, t in re.findall(r'<p class="exsub" data-ep-(count|reading)[^>]*>(.*?)</p>', block('epCounts'), flags=re.S): emit('  EPCOUNT: ' + ('Reading: ' if k == 'reading' else '') + txt(t))
    # who waited
    emit('WHONOTE: ' + txt(block('whoNote')))
    emit('WHOTABS: ' + ' | '.join(txt(x) for x in re.findall(r'<button[^>]*>(.*?)</button>', block('whoTabs'), flags=re.S)))
    wb = block('whoBody')
    if 'class="whov' not in wb: emit('WHO: ' + txt(wb))
    for part in re.split(r'(?=<div class="whov)', wb)[1:]:
        emit('WHO: ' + txt(re.search(r'<div class="exh">(.*?)</div>', part, flags=re.S).group(1)) + (' (hidden tab)' if part.startswith('<div class="whov off') else ''))
        if 'data-who-list' not in part: emit('  WHOLISTS: ' + txt(re.search(r'<div class="empty">(.*?)</div>', part, flags=re.S).group(1)) if '<div class="empty">' in part else '  WHOLISTS: none')
        for ch in part.split('<div class="whol" data-who-list="')[1:]:
            emit('  WHOLIST %s: %s' % (ch.split('"')[0], ' ; '.join(txt(x) for x in re.findall(r'<div class="whor">(.*?)</div>', ch, flags=re.S)) or 'none'))
        for k in ('cap', 'peak'):
            m = re.search(r'<p class="seqcap" data-who-%s="1">(.*?)</p>' % k, part, flags=re.S)
            if m: emit('  WHO%s: %s' % (k.upper(), txt(m.group(1))))
        for r in re.findall(r'<tr data-wl="(\w+)">(.*?)</tr>', part, flags=re.S): emit('  WHOWL %s | %s' % (r[0], ' | '.join(txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', r[1], flags=re.S))))
        for m in re.findall(r'<p class="seqcap" data-who-wl="1">(.*?)</p>', part, flags=re.S): emit('  WHOWL: ' + txt(m))
    sys.exit(0)
if mode == '--captions':   # every card heading with the paragraph beside it: "length | heading | caption"
    for m in re.finditer(r'<div class="ch"><div><h2[^>]*>(.*?)</h2>(?:<p[^>]*>(.*?)</p>)?', re.sub(r'<script.*?</script>', '', d, flags=re.S)):   # not the page's own source text
        c = txt(m.group(2) or '')
        print('%d | %s | %s' % (len(c), txt(m.group(1)), c))
    sys.exit(0)
if mode == '--order':   # the sections of the page in document order, with the ids of the two panes: report, ..., paneHandover, handover
    ids = 'report summary timeline sequence commits who lgwr baseline recur listener rfsCard nsCard signals explain next coverage episodes history alerts traces shipping cidCard config rfsEvCard standby network paneHandover handover'.split()
    print(' '.join(m.group(1) for m in re.finditer(r'<(?:section|div)[^>]*\bid="(%s)"' % '|'.join(ids), re.sub(r'<script.*?</script>', '', d, flags=re.S))))
    sys.exit(0)
if mode == '--sets':   # the page's own source (the selector's template strings) is left out: only a rendered selector counts
    d = re.sub(r'<script.*?</script>', '', d, flags=re.S)
    sec = block('epsel')
    if sec:
        emit('SETS: ' + txt(re.search(r'<h2[^>]*>(.*?)</h2>', sec, flags=re.S).group(1)))
        emit('SETNAV: ' + ' | '.join('%s %s' % (txt(l), h) for h, l in re.findall(r'<a class="btn" href="([^"]*)"[^>]*>(.*?)</a>', sec, flags=re.S)) + ''.join(' | %s none' % txt(l) for l in re.findall(r'<span class="btn" aria-disabled="true">(.*?)</span>', sec, flags=re.S)))
        for tag, row in re.findall(r'<tr (data-set="\d+"[^>]*)>(.*?)</tr>', sec, flags=re.S):
            c = re.findall(r'<td[^>]*>(.*?)</td>', row, flags=re.S)
            lk = re.search(r'<a href="([^"]*)"', c[4])
            state = 'shown' if 'aria-current="true"' in tag and 'shown' in txt(c[4]) else 'link ' + lk.group(1) if lk and 'aria-current' not in tag else 'MARK?'
            emit('SET %s | %s | %s | %s | %s' % (re.search(r'data-set="(\d+)"', tag).group(1), txt(c[1]), ' ; '.join(txt(x) for x in re.findall(r'<div[^>]*>(.*?)</div>', c[2], flags=re.S)), txt(c[3]), state))
    sys.exit(0)
if mode == '--readings':   # the Reading disclosures: "closed | Reading (n)"; DIVRD counts a Reading block that is not a disclosure
    page = re.sub(r'<script.*?</script>', '', d, flags=re.S)
    for m in re.finditer(r'<details class="rd"( open)?[^>]*><summary>(.*?)</summary>', page, flags=re.S): print('%s | %s' % ('open' if m.group(1) else 'closed', txt(m.group(2))))
    print('DIVRD: %d' % len(re.findall(r'<div class="rd"', page)))
    sys.exit(0)
if mode == '--delivered':   # extract.py DOM --delivered copy|dl net|ticket: what Copy (copy) or Download .txt (dl) delivered per incident, in the format of --net / --ticket
    m = re.search(r'<pre id="uidelivered" style=[^>]*>(.*?)</pre>', d, flags=re.S)
    got = json.loads(html.unescape(m.group(1)))[sys.argv[3]][sys.argv[4]] if m else {}
    for n in sorted(got, key=int):
        print('#### incident %s' % n)
        sys.stdout.write(got[n])
    sys.exit(0)
if mode == '--ui':
    m = re.search(r'<pre id="uitest" style=[^>]*>(.*?)</pre>', d, flags=re.S)
    print(html.unescape(m.group(1)) if m else 'NO UITEST')
    sys.exit(0)
if mode == '--facts':
    m = re.search(r'<script type="application/json" id="dgr-facts">(.*?)</script>', d, flags=re.S)
    data = json.loads(html.unescape(m.group(1))) if m else {'facts': [], 'incidents': []}
    print('CLOCKS %s' % json.dumps(data.get('clocks')))
    for f in data['incidents']: print('INCIDENT %d %s %s %s' % (f['n'], f['start'], f['end'], f['kinds']))
    for f in data['facts']:
        print('FACT %s | %s | %s | %s | %s | %s | inc=%s%s%s' % (f['at'] or 'as collected', f['side'], f['kind'], f['source'], f['text'], f['precision'], f['incident'], ' | converted' if f.get('converted') else '', ' | quiet' if f.get('quiet') else ''))
    sys.exit(0)
emit('SUB: ' + txt(block('sub')))
emit('BADGES: ' + txt(block('badges')))
emit('NOTICES: ' + txt(block('notices')))
for c in re.split(r'<div class="card stat', block('summary'))[1:]: emit('STAT: ' + txt('<div class="card stat' + c))
for a in re.split(r'<div class="alert', block('sigs'))[1:]:
    title = txt(re.search(r'<div class="at">(.*?)</div>', a, flags=re.S).group(1)) if '<div class="at">' in a else txt(a)
    emit('SIGNAL: ' + title)
    ob = re.search(r'<div class="ob">(.*?)</ul>', a, flags=re.S)
    for li in re.findall(r'<li class="o[^"]*"[^>]*>(.*?)</li>', ob.group(1) if ob else '', flags=re.S):
        parts = re.findall(r'<span class="(w mono|sr|tx|pr)"[^>]*>(.*?)</span>|<span class="badge[^"]*">(?:<span class="dot"></span>)?(.*?)</span>', li, flags=re.S)
        w = sr = tx = pr = host = ''
        for k, v, b in parts:
            if b: host = txt(b)
            elif k == 'w mono': w = txt(v)
            elif k == 'sr': sr = txt(v)
            elif k == 'tx': tx = txt(v)
            elif k == 'pr': pr = txt(v)
        emit('  OBSERVED: %s | %s | %s | %s | %s' % (w, host, sr, tx, pr))
    rd = re.search(r'<details class="rd"(?: open)?>(.*?)$', a, flags=re.S)
    rdb = re.sub(r'<summary>.*?</summary>', '', rd.group(1), count=1, flags=re.S) if rd else ''   # the Reading block without its closed-disclosure label
    for li in re.findall(r'<li class="r">(.*?)</li>', rdb, flags=re.S):
        tx = cells(li, 'tx'); asm = cells(li, 'as'); al = cells(li, 'al')
        emit('  READING: %s%s%s' % (tx[0] if tx else '', ' | ' + asm[0] if asm else '', ' | ' + al[0] if al else ''))
    if rd and '<ul class="rds">' not in rdb: emit('  READING: ' + txt(rdb))
ruled = block('ruled')
for r in re.split(r'(?=<div class="r(?:h| ro| nc| nf)"|<div class="hint")', ruled):
    if r.startswith('<div class="hint"'): emit('HINT: ' + txt(r))
    elif r.startswith('<div class="rh"'): emit('RULED/NC HEADING: ' + txt(r))
    elif r.startswith('<div class="r ro"'): emit('RULED: ' + txt(r))
    elif r.startswith('<div class="r nf"'): emit('NONEFOUND: ' + txt(r))
    elif r.startswith('<div class="r nc"'): emit('NOTCHECKED: ' + txt(r))
for r in re.findall(r'<tr data-cov="([^"]*)">(.*?)</tr>', block('covTbl'), flags=re.S):
    c = [txt(x) for x in re.findall(r'<td[^>]*>(.*?)</td>', r[1], flags=re.S)]
    emit('COV: %s | %s' % (r[0], ' | '.join(c[2:6])))   # the four columns after source and side that were always there; the "Reached the window" column is in --parts (REACH)
cn = txt(block('covNote'))
emit('COVNOTE: ' + cn)
emit('HISTNOTE: ' + txt(block('histNote')))
emit('FGNOTE: ' + txt(block('fgNote')))

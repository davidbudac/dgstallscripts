#!/usr/bin/env python3
"""check_bundle.py FILE [allow-ora] [collector]: is FILE a well-formed v2 bundle (docs/bundle-format.md)? Prints problems, exit 1 if any.
Every JSON line must parse, every time field must be a full timestamp, there must be exactly one cov record per
(side, src, kind) for every source (the sar source once per report kind), and one clock record per side. `v$redo_dest_resp_histogram.TIME` (dest_hist.hit) is text, not checked. A line that is not JSON is only allowed with allow-ora.
A record of the newer types (lfs_by, aas, wl_hist, alsync, act) must have its cov record (same side; act: same kind) and the right fields, with or without `collector`.
collector (the output of sh/collect.sh, and the example bundles): the newer sources must all be there: alsync (kind sql or text) and act rman, job and logsw on both sides,
lfs_by, aas and wl_hist on the primary; on the standby act job and logsw, and lfs_by, aas and wl_hist when present, are skipped. Without it a bundle may lack them (scenario bundles written before they existed)."""
import json, re, sys

TSF = {'alert': ['ts'], 'tx': ['ts'], 'fg': ['m'], 'fg10': ['b'], 'wl': ['m'], 'arch': ['first', 'next', 'done'], 'trace': ['ts'],
       'lsnr': ['m'], 'lsnr_ref': ['ts'], 'cid_hit': ['ts'], 'hist_awr': ['b', 'e'], 'net': ['at'], 'alhist': ['ts'],
       'lfs': ['a', 'z'], 'lfs_sum': ['pk_at', 'pk_lg_at'], 'ashgap': ['a', 'z'], 'lfs_by': ['a', 'z'], 'aas': ['m'], 'wl_hist': ['b', 'e'], 'alsync': ['ts'], 'act': ['a', 'z'],
       'lsnr_srv': ['ts'], 'dgstatus': ['ts'], 'netsamp': ['ts'], 'sar': ['ts'], 'base_day': ['from', 'to', 'b', 'e'], 'ntp': ['at'], 'dgproc': ['since']}
FULL = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d(:\d\d(\.\d{1,6})?)?$')
SRCS = ['database', 'ash', 'awr_snap', 'sysmetric', 'lfs', 'ashgap', 'tx', 'alert_sql', 'alert_text', 'alhist', 'dgstatus', 'dest_hist', 'base_hist', 'rfs_ev', 'rfs_hist', 'dgproc', 'archgap',
        'trace', 'listener', 'lsnr_ref', 'lsnr_srv', 'cid', 'ep', 'conn', 'sqlnet', 'ostcp', 'ntp', 'netsamp', 'net']
SARKINDS = ['ETCP', 'TCP', 'DEV', 'EDEV']
NEWSRCS = ['lfs_by', 'aas', 'wl_hist', 'alsync']     # the newer sources with a cov record of their own (alsync: kind sql or text)
ACTKINDS = ['rman', 'job', 'logsw']           # src act has one cov record per kind
LFSDIMS = ['service', 'module', 'machine']
MINUTE = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d$')
COVKEYS = ['t', 'side', 'src', 'st', 'first', 'last', 'n', 'cap', 'capped', 'note']

path, allow_ora, collector = sys.argv[1], 'allow-ora' in sys.argv[2:], 'collector' in sys.argv[2:]
isint = lambda v: isinstance(v, int) and not isinstance(v, bool)
isnum = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
bad, recs = [], []
for i, line in enumerate(open(path, encoding='utf-8'), 1):
    line = line.rstrip('\n')
    if not line.strip():
        continue
    if not line.startswith('{'):
        if not (allow_ora and re.search(r'ORA-|SP2-|^ERROR at line \d+:$', line)):
            bad.append('line %d: not JSON: %s' % (i, line[:60]))
        continue
    try:
        recs.append(json.loads(line))
    except ValueError as e:
        bad.append('line %d: invalid JSON (%s)' % (i, e))
if not recs or recs[0].get('t') != 'bundle' or recs[0].get('v') != 2:
    bad.append('first record is not a v2 bundle header')
bside = recs[0].get('side') if recs else None      # a record without side (fg, aas) belongs to the side of the bundle
seen = {}
for o in recs:
    for f in TSF.get(o['t'], []) + (['from', 'to', 'collected'] if o['t'] == 'bundle' else []):
        if o.get(f) is not None and not FULL.match(str(o[f])):
            bad.append('%s.%s is not a full timestamp: %r' % (o['t'], f, o[f]))
    if o['t'] == 'cov':
        miss = [k for k in COVKEYS if k not in o]
        if miss:
            bad.append('cov %s/%s lacks %s' % (o.get('side'), o.get('src'), miss))
        if o.get('st') not in ('ok', 'empty', 'error', 'skipped'):
            bad.append('cov %s/%s has st %r' % (o.get('side'), o.get('src'), o.get('st')))
        if not isinstance(o.get('capped'), bool) or not isinstance(o.get('n'), int):
            bad.append('cov %s/%s: n must be an integer and capped a boolean' % (o.get('side'), o.get('src')))
        if o.get('capped') and o.get('cap') is None:
            bad.append('cov %s/%s is capped without a cap' % (o.get('side'), o.get('src')))
        for f in ('first', 'last'):
            if o.get(f) is not None and not FULL.match(o[f]):
                bad.append('cov %s/%s.%s is not a full timestamp: %r' % (o.get('side'), o.get('src'), f, o[f]))
        seen.setdefault((o['side'], o['src'], o.get('kind')), []).append(o)
for k, v in seen.items():
    if len(v) != 1:
        bad.append('%d cov records for %s' % (len(v), k))
# the records of the newer statements: their fields, and the cov record each needs (with or without `collector`)
need = set()
for o in recs:
    t, sd = o['t'], o.get('side') or bside
    if t == 'lfs_by':
        nm = o.get('name')
        if o.get('dim') not in LFSDIMS:
            bad.append('lfs_by.dim is %r, not one of %s' % (o.get('dim'), LFSDIMS))
        if nm is not None and not (isinstance(nm, str) and len(nm) <= 64):
            bad.append('lfs_by.name must be null or a string of at most 64 characters: %r' % (nm,))
        if not all(isint(o.get(f)) for f in ('n', 'lg', 'sess')):
            bad.append('lfs_by %r: n, lg and sess must be integers' % (nm,))
        elif o['lg'] > o['n']:
            bad.append('lfs_by %r: lg %d is more than n %d' % (nm, o['lg'], o['n']))
        need.add((sd, t, None))
    elif t == 'aas':
        ev, wc = o.get('ev'), o.get('wc')
        if not MINUTE.match(str(o.get('m'))):
            bad.append('aas.m must be a time to the minute: %r' % (o.get('m'),))
        if (ev is None) != (wc is None):
            bad.append('aas %r/%r: ev and wc are both null (the events folded together) or both text' % (ev, wc))
        elif ev is not None and not (isinstance(ev, str) and isinstance(wc, str) and 0 < len(ev) <= 64 and 0 < len(wc) <= 64):
            bad.append('aas ev and wc must be text of at most 64 characters: %r, %r' % (ev, wc))
        if not all(isint(o.get(f)) and o[f] >= 0 for f in ('fg', 'bg')):
            bad.append('aas %s %s: fg and bg must be non-negative integers: %r, %r' % (o.get('m'), ev, o.get('fg'), o.get('bg')))
        elif o['fg'] == 0 and o['bg'] == 0:
            bad.append('aas %s %s: fg and bg are both 0 (no record is written for that)' % (o.get('m'), ev))
        need.add((sd, t, None))
    elif t == 'wl_hist':
        for f in ('b', 'e'):
            if not MINUTE.match(str(o.get(f))):
                bad.append('wl_hist.%s must be a time to the minute: %r' % (f, o.get(f)))
        for f in ('redo', 'redo_max', 'txn'):
            if o.get(f) is not None and not isnum(o.get(f)):
                bad.append('wl_hist.%s must be a number or null: %r' % (f, o.get(f)))
        need.add((sd, t, None))
    elif t == 'alsync':
        if not isinstance(o.get('msg'), str):
            bad.append('alsync.msg must be a string')
        need.add((sd, t, None))
    elif t == 'act':
        kd = o.get('kind')
        if kd not in ACTKINDS:
            bad.append('act.kind is %r, not one of %s' % (kd, ACTKINDS))
            continue
        if sd == 'standby' and kd != 'rman':
            bad.append('act %s record on the standby: only rman is collected there' % kd)
        if kd in ('rman', 'job') and not isinstance(o.get('name'), str):
            bad.append('act %s: name must be a string: %r' % (kd, o.get('name')))
        if kd == 'rman' and not (o.get('z') is None or isinstance(o.get('z'), str)):
            bad.append('act rman.z must be null or a timestamp: %r' % (o.get('z'),))
        if kd == 'job':
            if not isinstance(o.get('freq'), bool):
                bad.append('act job %s: freq must be a boolean: %r' % (o.get('name'), o.get('freq')))
            if not isint(o.get('n')):
                bad.append('act job %s: n must be an integer: %r' % (o.get('name'), o.get('n')))
            if o.get('con') is not None and not isint(o.get('con')):
                bad.append('act job %s: con must be an integer or null: %r' % (o.get('name'), o.get('con')))
        if kd == 'logsw' and not (isint(o.get('thr')) and isint(o.get('seq'))):
            bad.append('act logsw: thr and seq must be integers')
        need.add((sd, t, kd))
# aas: one record per minute and event, at most 12 events by name, the others folded into a record with ev null (which the cov record then calls capped)
for sd in {k[0] for k in seen}:
    ar = [o for o in recs if o['t'] == 'aas' and (o.get('side') or bside) == sd]
    if not ar:
        continue
    keys = [(o.get('m'), o.get('ev')) for o in ar]
    if len(keys) != len(set(keys)):
        bad.append('%s aas: more than one record for a minute and event' % sd)
    names = {o.get('ev') for o in ar if o.get('ev') is not None}
    cv = (seen.get((sd, 'aas', None)) or [{}])[0]
    if len(names) > 12:
        bad.append('%s aas: %d events by name, at most 12 are kept' % (sd, len(names)))
    if cv.get('cap') not in (None, 12):
        bad.append('%s cov aas has cap %r, not 12' % (sd, cv.get('cap')))
    if any(o.get('ev') is None for o in ar) and cv.get('st') == 'ok' and not cv.get('capped'):
        bad.append('%s aas: events are folded into a record with ev null but the cov record is not capped' % sd)
    # the same ASH source and window as fg: where the bundle has fg records, the foreground samples of a minute add up to its fg record
    fgm = {o['m']: o['lgwr'] + o['other'] + o['cpu'] for o in recs if o['t'] == 'fg' and (o.get('side') or bside) == sd and all(isint(o.get(k)) for k in ('lgwr', 'other', 'cpu'))}
    if fgm:
        sums = {}
        for o in ar:
            if isint(o.get('fg')):
                sums[o.get('m')] = sums.get(o.get('m'), 0) + o['fg']
        for m in sorted(set(fgm) | set(sums)):
            if fgm.get(m, 0) != sums.get(m, 0):
                bad.append('%s aas %s: the foreground samples add up to %d, fg.lgwr + fg.other + fg.cpu is %d' % (sd, m, sums.get(m, 0), fgm.get(m, 0)))
for sd, t, kd in sorted(need, key=str):
    if not any(k[0] == sd and k[1] == t and (kd is None or k[2] == kd) for k in seen):
        bad.append('%s records without a cov record for %s/%s%s' % (t, sd, t, '/' + kd if kd else ''))
for k in seen:
    if k[1] == 'alsync' and k[2] not in ('sql', 'text'):
        bad.append('cov %s/alsync has kind %r, not sql or text' % (k[0], k[2]))
sides = {o['side'] for o in recs if o['t'] == 'bundle'}
for sd in sides:
    for s in SRCS:
        if not any(k[0] == sd and k[1] == s for k in seen):
            bad.append('no cov record for %s/%s' % (sd, s))
    for k in SARKINDS:
        if (sd, 'sar', k) not in seen:
            bad.append('no cov record for %s/sar/%s' % (sd, k))
    if sum(1 for o in recs if o['t'] == 'clock' and o.get('side') == sd) != 1:
        bad.append('need exactly one clock record for %s' % sd)
    if collector:
        for s in NEWSRCS if sd == 'primary' else ['alsync']:
            if not any(k[0] == sd and k[1] == s for k in seen):
                bad.append('no cov record for %s/%s' % (sd, s))
        for k in ACTKINDS:
            if (sd, 'act', k) not in seen:
                bad.append('no cov record for %s/act/%s' % (sd, k))
        if sd == 'standby':
            for k in (k for k in seen if k[0] == sd and ((k[1] == 'act' and k[2] in ('job', 'logsw')) or k[1] in ('lfs_by', 'aas', 'wl_hist'))):
                if seen[k][0].get('st') != 'skipped':
                    bad.append('cov %s/%s%s is %r: it is not collected on the standby' % (k[0], k[1], '/' + k[2] if k[2] else '', seen[k][0].get('st')))
for o in recs:
    if o['t'] == 'clock' and not (o.get('utc_off') is None or re.match(r'^[+-]\d\d:\d\d$', o['utc_off'])):
        bad.append('clock utc_off %r' % o.get('utc_off'))
if bad:
    print('\n'.join(bad))
sys.exit(1 if bad else 0)

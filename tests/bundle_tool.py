#!/usr/bin/env python3
"""Bundle helper for the tests and for rebuilding the examples (python3 is allowed in tests only).

  bundle_tool.py upgrade IN         v1 bundle -> v2 on stdout: full timestamps, header v:2, plus clock and cov records
  bundle_tool.py shift SECONDS IN   move a v2 bundle's window and its records by SECONDS (use a multiple of 60);
                                    history rows (alhist) and collection-time stamps (collected, gen, net.at) stay put; the first/last of a cov record move with the data
  bundle_tool.py extend 'YYYY-MM-DD HH:MI:SS' IN   move the end of the window, data unchanged
  bundle_tool.py sample IN          add the lfs / lfs_sum / ashgap records and their cov records to an example bundle (idempotent), fix the LGWR wait
  bundle_tool.py sample3 IN         add the records of collector phase 3 (standby RFS latency, dgstatus, redo destination histogram, baseline days, listener
                                    server-to-server connections, endpoints, timeouts, clock state, sampler samples ...) and their cov records to an example bundle (idempotent)
  bundle_tool.py sample4 IN         add the records of the second newer-collector step (who waited by service, module and machine; workload per AWR interval; the lines that end an
                                    UNSYNCHRONIZED period; scheduled activity: RMAN commands, scheduler job runs, log switches) and their cov records to an example bundle (idempotent)
  bundle_tool.py gen OUTDIR         write the synthetic scenario bundles of the tests: <name>_primary.jsonl and <name>_standby.jsonl
                                    (quiet two noash drift lost tzoff rtpmode rac full sbgap late: `full` is a Linux pair with the primary at UTC+01:00 and the standby
                                    at UTC+00:00 and every record of the newer collector inside the window, `sbgap` the same with a gap in the standby's ASH sampler
                                    inside the wait, `late` instances that started after the window, `hist` a window older than the newest history lines, `waitcov` an ASH gap check that ends
                                    shortly after the SYNC wait, `stfail` the statements of the newer sources failing (the job read with its records), `capped` every lookback source cut at its cap); fictional names, documentation addresses 192.0.2.x / 198.51.100.x
"""
import json, re, sys
from datetime import datetime, timedelta

# time fields per record type (the same table the report uses to read v1 and v2)
TSF = {'alert': ['ts'], 'tx': ['ts'], 'fg': ['m'], 'fg10': ['b'], 'wl': ['m'], 'arch': ['first', 'next', 'done'],
       'trace': ['ts'], 'lsnr': ['m'], 'lsnr_ref': ['ts'], 'cid_hit': ['ts'], 'hist_awr': ['b', 'e'], 'net': ['at'], 'alhist': ['ts'],
       'lfs': ['a', 'z'], 'lfs_sum': ['pk_at', 'pk_lg_at'], 'ashgap': ['a', 'z'],
       'lsnr_srv': ['ts'], 'dgstatus': ['ts'], 'netsamp': ['ts'], 'sar': ['ts'], 'base_day': ['from', 'to', 'b', 'e'],
       'lfs_by': ['a', 'z'], 'wl_hist': ['b', 'e'], 'alsync': ['ts'], 'act': ['a', 'z']}
# cov sources that describe the host or the views as collected (or a log history), not the data of the window: they do not move with a shifted window
AS_COLLECTED = ('net', 'alhist', 'alsync', 'wl_hist', 'act', 'ep', 'conn', 'sqlnet', 'ostcp', 'ntp', 'dgproc', 'archgap', 'dest_hist', 'rfs_ev', 'rfs_hist')
MON = {m: '%02d' % (i + 1) for i, m in enumerate('JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC'.split())}


def load(path):
    return [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]


def dump(recs):
    for o in recs:
        print(json.dumps(o, separators=(',', ':'), ensure_ascii=False))


def full(v, day):
    if v is None or v == '' or v[:2].isdigit() and v[4:5] == '-':
        return v
    if len(v) > 11 and v[2] == '-' and v[3:6].isalpha():               # 13-NOV-2026 20:40:07 (listener log)
        return '%s-%s-%s %s' % (v[7:11], MON[v[3:6].upper()], v[:2], v[12:])
    return day + ' ' + v


def parse(s):
    for f in ('%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M'):
        try:
            return datetime.strptime(s, f), len(s)
        except ValueError:
            pass
    raise ValueError(s)


def move(s, secs):
    d, n = parse(s)
    d += timedelta(seconds=secs)
    return d.strftime('%Y-%m-%d %H:%M:%S.%f')[:n] if n > 19 else d.strftime('%Y-%m-%d %H:%M:%S')[:n]


def upgrade(recs):
    hdr = recs[0]
    assert hdr['t'] == 'bundle' and hdr.get('v') == 1, 'not a v1 bundle'
    day, cday, side = hdr['from'][:10], hdr['collected'][:10], hdr['side']
    for o in recs:
        for f in TSF.get(o['t'], []):
            if o.get(f):
                o[f] = full(o[f], cday if f == 'at' else day)
    hdr['v'] = 2
    cnt = {}
    for o in recs:
        cnt[o['t']] = cnt.get(o['t'], 0) + 1
    meta = next(o for o in recs if o['t'] == 'meta')
    out = list(recs)
    out.append({'t': 'clock', 'side': side, 'utc_off': meta['tz'], 'src': 'alert log'})

    def cov(src, st, first=None, last=None, n=0, cap=None, capped=False, note='', **extra):
        o = {'t': 'cov', 'side': side, 'src': src}
        o.update(extra)
        o.update({'st': st, 'first': first, 'last': last, 'n': n, 'cap': cap, 'capped': capped, 'note': note})
        out.append(o)

    cov('database', 'ok', n=1, note='sqlplus connected, meta written')
    net = [o for o in recs if o['t'] == 'net']
    ref = [o for o in recs if o['t'] == 'lsnr_ref']
    lsn = sum(o['n'] for o in recs if o['t'] == 'lsnr')
    if side == 'primary':
        cov('ash', 'ok', '2026-11-06 09:00:03', '2026-11-14 08:59:53', 2284, kind=meta['ash'], note='dba_hist_active_sess_history')
        cov('awr_snap', 'ok', '2026-11-06 09:00:03', '2026-11-14 09:00:04', 1, note='dba_hist_snapshot: first/last = oldest begin and newest end held; n = snapshots overlapping the window')
        cov('sysmetric', 'ok', '2026-11-06 09:00:00', '2026-11-14 08:59:00', cnt['wl'], note='dba_hist_sysmetric_history, 1 min values; n = minutes in the window')
        cov('lfs', 'skipped', note='not collected in format v1')
        cov('ashgap', 'skipped', note='not collected in format v1', samples=0)
        cov('alert_sql', 'ok', '2026-10-15 09:12:41', '2026-11-14 09:12:39', cnt['alert'], note='v$diag_alert_ext, lookback 30 days')
        cov('alert_text', 'skipped', note='not requested; pass -a to read the text alert log')
        cov('alhist', 'ok', '2026-10-15 09:12:41', '2026-11-14 09:12:39', cnt['alhist'], 300, False, 'v$diag_alert_ext, lookback 30 days, newest 300 kept', kind='sql')
    else:
        for s in ('ash', 'awr_snap', 'sysmetric', 'lfs', 'ashgap', 'alert_sql'):
            cov(s, 'skipped', note='not collected on the standby')
        cov('alert_text', 'ok', '2026-09-02 03:14:07', '2026-11-14 09:09:58', cnt['alert'], note='alert_proddb1.log')
        cov('alhist', 'ok', '2026-09-02 03:14:07', '2026-11-14 09:09:58', cnt['alhist'], 300, False, 'alert_proddb1.log, whole file, newest 300 kept', kind='text')
    cov('trace', 'ok', '2026-10-02 00:00:41', '2026-11-14 08:57:12', cnt['trace'], 400, False, 'files modified in the last 45 days',
        files=9 if side == 'primary' else 6)
    cov('listener', 'ok', '2026-09-20 00:00:01', '2026-11-14 09:12:36' if side == 'primary' else '2026-11-14 09:09:51', lsn + 26, note='listener.log')
    cov('lsnr_ref', 'ok' if ref else 'empty', '2026-09-20 00:00:01', '2026-11-14 09:12:36' if side == 'primary' else '2026-11-14 09:09:51', len(ref), 500, False,
        'refused establish lines in the window')
    if hdr['cidcheck'] == 'yes':
        cov('cid', 'ok', '2026-09-20 00:00:01', '2026-11-14 09:12:36', cnt['cid_hit'], 2000, False, '49 CONNECTION_IDs looked up')
    else:
        cov('cid', 'skipped', cap=2000, note='option -c not given')
    if net:
        cov('net', 'ok', net[0]['at'], net[0]['at'], 1, note='ping and netstat towards ' + net[0]['peer'])
    else:
        cov('net', 'skipped', note='option -p not given')
    return out


def shift(recs, secs):
    for o in recs:
        if o['t'] in ('bundle', 'meta'):
            for f in ('from', 'to', 'collected'):   # the collection time of the bundle moves with the window: the report states how long after the window it was collected
                if o.get(f):
                    o[f] = move(o[f], secs)
            continue
        if o['t'] in ('alhist', 'alsync', 'wl_hist', 'act'):   # the history (and the lookback records) is read back from the collection time: it stays put
            continue
        if o['t'] == 'cov':   # what a source held moves with the data it held (the network check ran at collection time and stays)
            if o['src'] not in AS_COLLECTED:
                for f in ('first', 'last'):
                    if o.get(f):
                        o[f] = move(o[f], secs)
            continue
        for f in TSF.get(o['t'], []):
            if o.get(f) and not (o['t'] == 'net' and f == 'at'):
                o[f] = move(o[f], secs)
        if o['t'] == 'trace' and 'exceeds begin time' in o.get('msg', ''):   # the wait that timed out names its own times: they move with the line
            o['msg'] = re.sub(r'<(\d\d/\d\d/\d{4} \d\d:\d\d:\d\d)>', lambda m: '<' + (datetime.strptime(m.group(1), '%m/%d/%Y %H:%M:%S') + timedelta(seconds=secs)).strftime('%m/%d/%Y %H:%M:%S') + '>', o['msg'])
    return recs


def extend(recs, to):
    for o in recs:
        if o['t'] in ('bundle', 'meta'):
            o['to'] = to
    return recs


# ----------------------------------------------------------------------------------------------------------------------------
# synthetic scenarios (fictional names, documentation addresses). Everything is generated here, nothing is copied from a real system.
# ----------------------------------------------------------------------------------------------------------------------------
FMT = '%Y-%m-%d %H:%M:%S'


def at(base, secs=0.0, ms=False):
    try:
        d = datetime.strptime(base, FMT)
    except ValueError:
        d = datetime.strptime(base, FMT + '.%f')
    d += timedelta(seconds=secs)
    return d.strftime(FMT + '.%f')[:-3] if ms else d.strftime(FMT)


class Bundle:
    """One host's bundle: header, meta, clock, records, and a cov record per source (covering the window unless a scenario says otherwise)."""

    def __init__(self, side, host, frm, to, off='+00:00', ash='V', collected=None, cid='no'):
        self.side, self.host, self.frm, self.to, self.off, self.ash = side, host, frm, to, off, ash
        self.collected = collected or at(to, 4 * 3600)
        self.cid = cid
        self.recs = []
        self.covs = {}
        self.meta_extra = {}
        self.clock = {'t': 'clock', 'side': side, 'utc_off': off, 'src': 'alert log'}

    def add(self, t, **kw):
        o = {'t': t, 'side': self.side}
        o.update(kw)
        self.recs.append(o)
        return o

    def alert(self, ts, msg):
        self.add('alert', ts=ts, msg=msg)

    def setcov(self, src, st='ok', first=None, last=None, n=0, cap=None, capped=False, note='', **extra):
        o = {'t': 'cov', 'side': self.side, 'src': src}
        o.update(extra)
        o.update({'st': st, 'first': first, 'last': last, 'n': n, 'cap': cap, 'capped': capped, 'note': note})
        self.covs[(src, extra.get('kind'))] = o

    def defaults(self):
        w0, w1 = at(self.frm, -30 * 86400), at(self.to, 3600)
        n = lambda t: sum(1 for o in self.recs if o['t'] == t)
        sd = lambda src, *a, **kw: None if (src, kw.get('kind')) in self.covs else self.setcov(src, *a, **kw)   # a scenario's own cov record wins
        if self.side == 'primary':
            sd('database', n=1, note='sqlplus connected, meta written')
            if True:
                sd('ash', first=at(self.frm, -3600) if self.ash == 'V' else w0, last=at(self.to, 900), n=max(n('tx'), 1), kind=self.ash, note='ash source')
            sd('awr_snap', first=w0, last=at(self.to, 600), n=1, note='dba_hist_snapshot')
            sd('sysmetric', first=w0, last=at(self.to, 600), n=n('wl'), note='dba_hist_sysmetric_history')
            sd('lfs', 'ok' if n('lfs') else 'empty', first=at(self.frm, -3600), last=at(self.to, 900), n=n('lfs'), cap=200, note='log file sync waits in ASH, longest 200 kept')
            sd('ashgap', 'empty', first=at(self.frm, -60), last=at(self.to, 60), n=0, cap=50, note='gaps over 2 s between consecutive ASH samples', samples=int(_secs(self.frm, self.to) / (1 if self.ash == 'V' else 10)))
            sd('alert_sql', first=w0, last=at(self.to, 900), n=n('alert'), note='v$diag_alert_ext, lookback 30 days')
            sd('alert_text', 'skipped', note='not requested; pass -a to read the text alert log')
            sd('alhist', first=w0, last=at(self.to, 900), n=n('alhist'), cap=300, kind='sql', note='v$diag_alert_ext, lookback 30 days, newest 300 kept')
            sd('tx', 'ok' if n('tx') else 'empty', first=at(self.frm, -3600) if self.ash == 'V' else w0, last=at(self.to, 900), n=n('tx'), note='transport wait samples in ASH')
            sd('dgstatus', 'empty', first=at(self.frm, -3 * 3600), last=at(self.collected, -30), n=0, cap=500, note='v$dataguard_status, in memory')
            sd('dest_hist', 'empty', first=self.collected, last=self.collected, n=0, note='as collected')
            sd('base_hist', 'skipped', note='option -b 0: no baseline requested')
            for src in ('rfs_ev', 'rfs_hist', 'dgproc', 'archgap'):
                sd(src, 'skipped', note='not collected on the primary')
        else:
            sd('database', n=1, note='sqlplus connected, meta written')
            for src in ('awr_snap', 'sysmetric', 'lfs', 'alert_sql', 'dest_hist', 'base_hist'):
                sd(src, 'skipped', note='not collected on the standby')
            # the standby's ASH is in memory only: collected hours later it no longer reaches the window
            sd('ash', 'empty', first=at(self.to, 3 * 3600), last=at(self.collected, -60), n=0, kind='V', note='v$active_session_history on the standby, in memory only')
            sd('ashgap', 'empty', n=0, cap=50, samples=0, note='gaps over 2 s between consecutive ASH samples (V)')
            sd('tx', 'ok' if n('tx') else 'empty', first=at(self.to, 3 * 3600), last=at(self.collected, -60), n=n('tx'), cap=5000, note='redo-related wait samples on the standby')
            sd('rfs_ev', 'empty', first=at(self.frm, -20 * 86400), last=self.collected, n=0, note='v$system_event, cumulative since startup')
            sd('rfs_hist', 'empty', first=at(self.frm, -20 * 86400), last=self.collected, n=0, note='v$event_histogram_micro, cumulative since startup')
            sd('dgstatus', 'empty', first=at(self.frm, -3 * 3600), last=at(self.collected, -30), n=0, cap=500, note='v$dataguard_status, in memory')
            sd('dgproc', 'empty', first=self.collected, last=self.collected, n=0, note='v$dataguard_process as collected')
            sd('archgap', 'empty', first=self.collected, last=self.collected, n=0, note='v$archive_gap as collected')
            sd('alert_text', first=w0, last=at(self.to, 900), n=n('alert'), note='alert_proddb.log')
            sd('alhist', first=w0, last=at(self.to, 900), n=n('alhist'), cap=300, kind='text', note='alert_proddb.log, whole file, newest 300 kept')
        sd('trace', 'ok' if n('trace') else 'empty', first=w0, last=at(self.to, 900), n=n('trace'), cap=400, note='files modified in the last 45 days', files=4)
        sd('listener', first=w0, last=at(self.to, 900), n=max(n('lsnr'), 1), note='listener.log')
        sd('lsnr_ref', 'ok' if n('lsnr_ref') else 'empty', first=w0, last=at(self.to, 900), n=n('lsnr_ref'), cap=500, note='refused establish lines in the window')
        sd('cid', 'skipped', cap=2000, note='option -c not given')
        sd('net', 'skipped', note='option -p not given')
        sd('lsnr_srv', 'empty', first=w0, last=at(self.to, 900), n=0, cap=500, note='establish lines with PROGRAM=oracle in the window')
        sd('ep', 'skipped', note='no destination or fal_server alias known')
        sd('conn', 'skipped', cap=200, note='no peer address: -p not given and none could be derived')
        sd('sqlnet', 'skipped', note='neither TNS_ADMIN nor ORACLE_HOME is set: sqlnet.ora not located')
        sd('ostcp', 'skipped', note='no TCP tunables read for this OS')
        sd('ntp', 'skipped', note='no clock synchronisation state could be read')
        for kind in ('ETCP', 'TCP', 'DEV', 'EDEV'):
            sd('sar', 'skipped', cap=2000, kind=kind, note='no sysstat network history read')
        sd('netsamp', 'skipped', cap=5000, note='option -n not given')

    def lines(self):
        self.defaults()
        hdr = {'t': 'bundle', 'side': self.side, 'host': self.host, 'from': self.frm, 'to': self.to, 'collected': self.collected, 'cidcheck': self.cid, 'v': 2}
        meta = {'t': 'meta', 'side': self.side, 'db': 'PRODDB', 'uniq': 'proddb' if self.side == 'primary' else 'proddb_s', 'role': 'PRIMARY' if self.side == 'primary' else 'PHYSICAL STANDBY',
                'open': 'READ WRITE' if self.side == 'primary' else 'MOUNTED', 'pmode': 'MAXIMUM AVAILABILITY', 'plevel': 'MAXIMUM AVAILABILITY', 'inst': 'proddb1',
                'host': self.host + '.example', 'ver': '19.27.0.0.0', 'plat': 'Linux x86 64-bit', 'from': self.frm, 'to': self.to, 'gen': self.collected, 'tz': self.off}
        meta['startup'] = at(self.frm, -20 * 86400)
        if self.side == 'primary':
            meta['ash'] = self.ash
            meta['cluster_database'] = 'FALSE'
            meta['inst_count'] = 1
        meta.update(self.meta_extra)
        return [hdr, meta, self.clock] + self.recs + list(self.covs.values())


def _secs(a, b):
    return (datetime.strptime(b, FMT) - datetime.strptime(a, FMT)).total_seconds()


DEST = {'t': 'dest', 'side': 'primary', 'id': 2, 'dest': 'proddb_s_dgmgrl', 'uniq': 'proddb_s', 'status': 'VALID', 'mode': 'PARALLELSYNC', 'affirm': 'YES', 'net_timeout': 30,
        'reopen': 300, 'max_failure': 0, 'failures': 0, 'error': None, 'sync': 'OK', 'synced': 'YES', 'gap': 'NO GAP'}
LAD_U = 'LGWR (PID:2201): RT_PMODE: LAD:2              changing to                             level UNSYNCHRONIZED{}'
LAD_S = 'LGWR (PID:2201): RT_PMODE: LAD:2              changing to                             level SYNCHRONIZED  '
PRI_U = 'LGWR (PID:2201): RT_PMODE: PRIMARY            changing to   mode MAXIMUM AVAILABILITY level UNSYNCHRONIZED'
PRI_S = 'LGWR (PID:2201): RT_PMODE: PRIMARY            changing to   mode MAXIMUM AVAILABILITY level SYNCHRONIZED  '
PHY_U = ' rfs (PID:4012): RT_PMODE: PHYSICAL           changing to   mode MAXIMUM AVAILABILITY level UNSYNCHRONIZED'
PHY_S = ' rfs (PID:4012): RT_PMODE: PHYSICAL           changing to   mode MAXIMUM AVAILABILITY level SYNCHRONIZED  '
ORA16198 = ['LGWR (PID:2201): ORA-16198: Received timed out error from KSR', 'LGWR (PID:2201): Attempting LAD:2 network reconnect (16198)', 'LGWR (PID:2201): LAD:2 network reconnect abandoned',
            'Errors in file /u01/app/oracle/diag/rdbms/proddb/proddb1/trace/proddb1_lgwr_2201.trc:\nORA-16198: Timeout incurred on internal channel during remote archival',
            "LGWR (PID:2201): Error 16198 for LNO:3 to 'proddb_s_dgmgrl'"]
ORA3135 = ['LGWR (PID:2201): Attempting LAD:2 network reconnect (3135)', 'LGWR (PID:2201): LAD:2 network reconnect abandoned',
           'Errors in file /u01/app/oracle/diag/rdbms/proddb/proddb1/trace/proddb1_lgwr_2201.trc:\nORA-03135: connection lost contact', "LGWR (PID:2201): Error 3135 for LNO:3 to 'proddb_s_dgmgrl'"]
VKTM = 'Warning: VKTM detected a forward time drift. '


def routine(b, frm, to, step=30):
    """log switches every `step` s: the alert noise of a healthy system"""
    t, k = 0, 1
    while at(frm, t) <= to:
        b.alert(at(frm, t, True), 'Thread 1 advanced to log sequence %d (LGWR switch),  current SCN: %d' % (500 + k, 9000000 + k * 777))
        t += step
        k += 1


def pairs(b, ts, ev, tw_ms, base_seq=100, p='LGWR'):
    for k, t in enumerate(ts):
        b.add('tx', ts=t, p=p, ev=ev, seq=base_seq + k * 7, tw=tw_ms * 1000)


def stall_samples(b, start, end_exact, p, ev, seq, step=1.0, exact=True):
    """ASH samples of one long wait: one per `step` s from `start`, time_waited on the last one when `exact` (microseconds = end_exact seconds)"""
    n = int(end_exact // step)
    for k in range(n):
        last = k == n - 1
        b.add('tx', ts=at(start, 0.4 + k * step, True), p=p, ev=ev, seq=seq, tw=int(end_exact * 1e6) if (last and exact) else 0)


def lsnr(b, frm, to, per_min=3, code='0'):
    t = datetime.strptime(frm, FMT).replace(second=0)
    while t.strftime(FMT) <= to:
        b.add('lsnr', m=t.strftime('%Y-%m-%d %H:%M'), code=code, n=per_min)
        t += timedelta(minutes=1)


def lfs_wait(b, sid, a, z, n, tw, lg=1, seq=None, ser=None):
    b.add('lfs', sid=sid, ser=ser or sid * 3 + 1, seq=seq or 4000 + sid, a=a, z=z, n=n, tw=tw, lg=lg)


def lfs_sum(b, waits, pk_n, pk_at, pk_lg=None, pk_lg_at=None):
    b.add('lfs_sum', waits=waits, lgwr_waits=waits, pk_n=pk_n, pk_at=pk_at, pk_lg=pk_n if pk_lg is None else pk_lg, pk_lg_at=pk_at if pk_lg_at is None else pk_lg_at)


def incident16198(p, s, t0='2026-11-20 10:05:00', n=12, drift=False):
    """ORA-16198 after a 30 s SYNC wait that began at t0 (V samples, exact time_waited on the last sample), then UNSYNCHRONIZED until 10:10:20."""
    err = at(t0, 30.2, True)
    stall_samples(p, t0, 30.2, 'LGWR', 'SYNC Remote Write', 5000)
    stall_samples(p, t0, 30.2, 'NSS2', 'Redo Transport MISC', 7000)
    p.add('trace', ts=err, file='proddb1_lgwr_2201.trc', msg='krsw_ksr_receive: Current time <%s> exceeds begin time <%s> by  <30> seconds, return timed out error' % (
        datetime.strptime(at(t0, 30), FMT).strftime('%m/%d/%Y %H:%M:%S'), datetime.strptime(t0, FMT).strftime('%m/%d/%Y %H:%M:%S')))
    for k, m in enumerate(ORA16198):
        p.alert(at(t0, 30.2 + k * 0.004, True), m)
    p.alert(at(t0, 30.4, True), LAD_U.format(' reason no connection'))
    p.alert(at(t0, 33.0, True), PRI_U)
    p.alert(at(t0, 320.5, True), LAD_S)
    p.alert(at(t0, 320.5, True), PRI_S)
    s.alert(at(t0, 321.0, True), PHY_S)
    for k in range(n):   # commit waits on LGWR, from the start of the stall until the release
        lfs_wait(p, 10 + k, at(t0, 0.5 + k * 0.1, True), at(t0, 29.5, True), 30 - k // 6, 30100000 - k * 100000)
    lfs_sum(p, n, n, at(t0, 25.5, True))
    for b in range(3):
        p.add('fg10', b=at(t0, b * 10), n=n * 10)
    p.add('fg10', b=at(t0, 30), n=0)


def base_pair(frm, to, off='+00:00', soff=None, ash='V'):
    p = Bundle('primary', 'prim-host', frm, to, off, ash, cid='no')
    s = Bundle('standby', 'stby-host', frm if soff is None else at(frm, _off(soff) - _off(off)), to if soff is None else at(to, _off(soff) - _off(off)), soff or off, ash)
    p.add('dest', **{k: v for k, v in DEST.items() if k not in ('t', 'side')})
    p.add('param', name='log_archive_config', value='dg_config=(proddb,proddb_s)')
    routine(p, frm, to, 45)
    routine(s, s.frm, s.to, 45)
    return p, s


def _off(o):
    return (1 if o[0] == '+' else -1) * (int(o[1:3]) * 3600 + int(o[4:6]) * 60)


def sc_quiet():
    p, s = base_pair('2026-11-20 09:20:00', '2026-11-20 09:45:00')
    for k in range(150):
        p.add('tx', ts=at('2026-11-20 09:20:00', 8 + k * 10, True), p='LGWR', ev='SYNC Remote Write', seq=100 + k, tw=2000 + (k % 5) * 400)
    p.add('tx', ts='2026-11-20 09:22:20.051', p='LGWR', ev='SYNC Remote Write', seq=39268, tw=347257)
    for ts_, tw in (('2026-11-20 09:37:40.412', 0), ('2026-11-20 09:39:10.412', None), ('2026-11-20 09:40:00.412', 0)):
        lfs_wait(p, 41, ts_, ts_, 1, tw, seq=900 + int(ts_[14:16]))
        p.add('fg10', b=ts_[:17] + '%d0' % (int(ts_[17:19]) // 10), n=1)
    lfs_sum(p, 3, 1, '2026-11-20 09:37:40.412')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_two():
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:45:00')
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60)], 'SYNC Remote Write', 3, 100)
    p.add('tx', ts='2026-11-20 10:04:30.250', p='LGWR', ev='SYNC Remote Write', seq=4900, tw=2100)
    incident16198(p, s)
    s.alert('2026-11-20 10:05:12.300', ' rfs (PID:4012): Selected LNO:11 for T-1.S-1514 dbid 1234567890 branch 1111111111')
    # second incident: a lost connection, no SYNC stall, the destination reports a gap
    for k, m in enumerate(ORA3135):
        p.alert(at('2026-11-20 10:30:00', k * 0.01, True), m)
    p.alert('2026-11-20 10:30:05.100', LAD_U.format(' reason destination has a gap'))
    p.alert('2026-11-20 10:31:40.700', LAD_S)
    s.alert('2026-11-20 10:30:00.500', ' rfs (PID:4012): Possible network disconnect with primary database')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    # the records of collector phase 3 (a Linux pair): the report must leave them alone. Standby ASH samples as the RFS processes show up there: program "oracle@<primary host> (TNS V1-V3)".
    for k in range(6):
        s.add('tx', ts=at('2026-11-20 10:05:00', 0.3 + k, True), p='TNS V1-V3', ev='RFS write' if k < 4 else 'RFS random i/o', seq=7700 + k // 2, tw=41000 + k, sid=311)
    s.add('tx', ts='2026-11-20 10:05:01.300', p='MRP0', ev='log file sequential read', seq=88, tw=0, sid=44)
    inc = ('2026-11-20 10:05:00', '2026-11-20 10:05:30.2', '2026-11-20 10:10:20')
    for b, own, peer, oh, ph in ((p, '198.51.100.11', '198.51.100.12', 'prim-host.example', 'stby-host.example'), (s, '198.51.100.12', '198.51.100.11', 'stby-host.example', 'prim-host.example')):
        R, C = phase3(b.side, b.frm, b.to, b.collected, plat='Linux', peer_ip=peer, own_ip=own, peer_host=ph, own_host=oh, incident=inc,
                      tx_n=sum(1 for o in b.recs if o['t'] == 'tx'), ash_first=at(b.frm, -600), ash_last=at(b.collected, -60), sampler=True, utc_off=b.off)
        b.recs.extend(R)
        for c in C:
            b.covs[(c['src'], c.get('kind'))] = c
    return p, s


def sc_noash():
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:30:00', ash='H')
    p.setcov('ash', first='2026-11-20 10:20:10', last='2026-11-20 10:40:00', n=12, kind='H', note='dba_hist_active_sess_history')
    p.setcov('ashgap', 'empty', first='2026-11-20 10:20:10', last='2026-11-20 10:31:00', n=0, cap=50, note='gaps over 2 s between consecutive ASH samples', samples=66)
    p.setcov('lfs', 'empty', first='2026-11-20 10:20:10', last='2026-11-20 10:40:00', n=0, cap=200, note='log file sync waits in ASH, longest 200 kept')
    for k, m in enumerate(ORA16198):
        p.alert(at('2026-11-20 10:05:30', k * 0.004, True), m)
    p.alert('2026-11-20 10:05:30.400', LAD_U.format(' reason no connection'))
    p.alert('2026-11-20 10:10:50.500', LAD_S)
    p.add('trace', ts='2026-11-20 10:05:30.200', file='proddb1_lgwr_2201.trc', msg='krsw_ksr_receive: Current time <11/20/2026 10:05:30> exceeds begin time <11/20/2026 10:05:00> by  <30> seconds, return timed out error')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_drift():
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:30:00')
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60)], 'SYNC Remote Write', 3, 100)
    t0 = '2026-11-20 10:05:00'
    # the sampler ran at 1 sample_id per second until 10:05:00.4, then the next sample came 29.4 s later: one sample_id on
    p.add('ashgap', ia=100000, a='2026-11-20 10:05:00.400', iz=100001, z='2026-11-20 10:05:29.800')
    p.setcov('ashgap', 'ok', first='2026-11-20 09:59:00', last='2026-11-20 10:31:00', n=1, cap=50, note='gaps over 2 s between consecutive ASH samples', samples=1900)
    p.alert('2026-11-20 10:05:30.197', VKTM)
    for k, m in enumerate(ORA16198):
        p.alert(at(t0, 30.201 + k * 0.004, True), m)
    p.alert('2026-11-20 10:05:30.400', LAD_U.format(' reason no connection'))
    p.alert('2026-11-20 10:10:20.500', LAD_S)
    p.add('trace', ts='2026-11-20 10:05:30.201', file='proddb1_lgwr_2201.trc', msg='krsw_ksr_receive: Current time <11/20/2026 09:48:12> exceeds begin time <11/20/2026 09:48:12> by  <30> seconds, return timed out error')
    s.alert('2026-11-20 10:05:30.100', VKTM + '\nTime drifts can result in unexpected behavior such as time-outs. \nPlease see the VKTM trace file for more details:\n/u01/app/oracle/diag/rdbms/proddb_s/proddb1/trace/proddb1_vktm_2251.trc')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_lost():
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:30:00')
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60)], 'SYNC Remote Write', 3, 100)
    p.alert('2026-11-20 10:15:00.400', 'Shutdown is initiated by sqlplus@prim-host.example (TNS V1-V3).')
    for k, m in enumerate(ORA3135):
        p.alert(at('2026-11-20 10:15:01.780', k * 0.01, True), m)
    p.alert('2026-11-20 10:15:01.830', LAD_U.format(' reason no connection'))
    p.alert('2026-11-20 10:15:02.100', 'Shutting down instance: further logons disabled')
    p.alert('2026-11-20 10:17:00.100', 'Instance shutdown complete (OS id: 4321)')
    for k in range(3):
        s.alert(at('2026-11-20 10:15:01.600', k * 0.002, True), 'Process termination requested for pid %d [source = unknown], [info = 0] [request issued by pid: 1, uid: 0]' % (2100 + k))
    for k, (code, osc) in enumerate(((12170, 0), (12543, 0))):
        t = at('2026-11-20 10:16:28.900', k * 3.1, True)
        main = 12535 if code == 12170 else 12543
        p.alert(t, '\nFatal NI connect error %d, connecting to:\n (DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=198.51.100.12)(PORT=1521)))(CONNECT_DATA=(SERVER=DEDICATED)(SID=proddb1)))' % code)
        p.alert(at(t, 0.001, True), '\n  VERSION INFORMATION:\n\tTNS for Linux: Version 19.0.0.0.0 - Production')
        p.alert(at(t, 0.002, True), '  Tns error struct:')
        p.alert(at(t, 0.003, True), '    ns main err code: %d' % main)
        p.alert(at(t, 0.004, True), 'TNS-%d: TNS:%s' % (main, 'operation timed out' if code == 12170 else 'destination host unreachable'))
        p.alert(at(t, 0.005, True), '    ns secondary err code: 12560')
        p.alert(at(t, 0.006, True), '    nt main err code: %d' % (505 if code == 12170 else 513))
        p.alert(at(t, 0.007, True), '    nt secondary err code: %d' % (0 if code == 12170 else 113))
        p.alert(at(t, 0.008, True), '    nt OS err code: %d' % osc)
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_tzoff():
    # the primary logs in UTC+01:00, the standby in UTC+00:00: the standby's own clock reads one hour less for the same instant
    p, s = base_pair('2026-11-20 11:00:00', '2026-11-20 11:45:00', off='+01:00', soff='+00:00')
    pairs(p, [at('2026-11-20 11:00:00', 20 + 17 * k, True) for k in range(60)], 'SYNC Remote Write', 3, 100)
    t0 = '2026-11-20 11:05:00'
    stall_samples(p, t0, 30.2, 'LGWR', 'SYNC Remote Write', 5000)
    p.add('trace', ts=at(t0, 30.2, True), file='proddb1_lgwr_2201.trc', msg='krsw_ksr_receive: Current time <11/20/2026 11:05:30> exceeds begin time <11/20/2026 11:05:00> by  <30> seconds, return timed out error')
    for k, m in enumerate(ORA16198):
        p.alert(at(t0, 30.2 + k * 0.004, True), m)
    p.alert(at(t0, 30.4, True), LAD_U.format(' reason no connection'))
    p.alert(at(t0, 320.5, True), LAD_S)
    s.alert('2026-11-20 10:05:12.300', ' rfs (PID:4012): Selected LNO:11 for T-1.S-1514 dbid 1234567890 branch 1111111111')   # 11:05:12 on the primary's clock
    s.alert('2026-11-20 10:05:32.900', ' rfs (PID:4012): Possible network disconnect with primary database')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_rtpmode():
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:45:00')
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60)], 'SYNC Remote Write', 3, 100)
    for t in ('2026-11-20 10:02:00.100', '2026-11-20 10:20:00.200'):
        p.alert(t, LAD_U.format(' reason ASYNC configuration'))
    for k in range(4):   # status lines that repeat; none of them is an incident
        p.alert(at('2026-11-20 10:03:00', k * 45, True), PRI_U)
        s.alert(at('2026-11-20 10:03:01', k * 45, True), PHY_U)
    p.alert('2026-11-20 10:30:00.100', LAD_U.format(' reason destination has a gap'))
    p.alert('2026-11-20 10:30:40.200', LAD_S)
    p.alert('2026-11-20 10:40:00.300', LAD_U.format(' reason no available SRLs'))
    p.alert('2026-11-20 10:40:30.400', LAD_S)
    for d, lines in (('2026-11-12', 2), ('2026-11-15', 1)):   # history: an episode on two days, plus routine lines that must not count
        p.add('alhist', ts=d + ' 02:03:10', msg=LAD_U.format(' reason no connection'))
        p.add('alhist', ts=d + ' 02:03:10', msg='LGWR (PID:2201): ORA-16198: Received timed out error from KSR')
    for k in range(5):
        p.add('alhist', ts='2026-11-1%d 12:%02d:00' % (k + 1, k * 10), msg=PRI_U)
    p.add('alhist', ts='2026-11-16 08:00:00', msg=LAD_U.format(' reason ASYNC configuration'))
    s.add('alhist', ts='2026-11-13 09:00:00', msg=PHY_U)
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


def sc_rac():
    # a RAC primary: meta says cluster_database TRUE and two open instances
    p, s = base_pair('2026-11-20 09:20:00', '2026-11-20 09:45:00')
    p.meta_extra = {'cluster_database': 'TRUE', 'inst_count': 2}
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    return p, s


NI_STBY = ('\n***********************************************************************\n\nFatal NI connect error 12170.\n\n  VERSION INFORMATION:\n\tTNS for Linux: Version 19.0.0.0.0 - Production\n'
           '  Time: 20-NOV-2026 09:05:31\n  Tracing not turned on.\n  Tns error struct:\n    ns main err code: 12535\n\nTNS-12535: TNS:operation timed out\n    ns secondary err code: 12560\n'
           '    nt main err code: 505\n\nTNS-00505: Operation timed out\n    nt secondary err code: 110\n    nt OS err code: 0\n'
           '  Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=198.51.100.11)(PORT=40112))')


def sc_full(gap=False):
    """A Linux pair that records everything the newer collector can: the primary logs at UTC+01:00, the standby at UTC+00:00, so every standby time is its own clock minus one hour.
    One SYNC wait of 30 s that ends in ORA-16198 at 10:05:30.2 (primary clock = 09:05:30.2 on the standby). The standby's ASH covers the window (gap=True: it has a sampler gap inside the wait),
    sysstat rows every 10 minutes on both hosts (one report missing on the standby), the sampler on both hosts, new connections at both listeners (one from another address), NTP state,
    a history of earlier episodes at about the same time of day, a baseline with unusable days."""
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:45:00', off='+01:00', soff='+00:00')
    SH = -3600                                   # standby clock minus primary clock
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60) if not 290 <= 20 + 17 * k <= 340], 'SYNC Remote Write', 3, 100)   # none while the wait of the incident runs
    t0 = '2026-11-20 10:05:00'
    incident16198(p, s, t0)
    s.recs.pop()                                 # the standby's SYNCHRONIZED line was written on the primary's clock
    s.alert(at(t0, 321.0 + SH, True), PHY_S)
    s.alert(at(t0, 31.1 + SH, True), NI_STBY)
    s.add('trace', ts=at(t0, 31.1 + SH, True), file='proddb1_rfs_4012.trc', msg='TNS-12535: TNS:operation timed out')
    p.alert(at(t0, 40.0, True), '\n***********************************************************************\n\nFatal NI connect error 12170.\n\n  VERSION INFORMATION:\n\tTNS for Linux: Version 19.0.0.0.0 - Production\n'
            '  Time: 20-NOV-2026 10:05:40\n  Tracing not turned on.\n  Tns error struct:\n    ns main err code: 12560\n\nTNS-12560: TNS:protocol adapter error\n    ns secondary err code: 0\n'
            '    nt main err code: 0\n    nt secondary err code: 0\n    nt OS err code: 0\n  connecting to: (DESCRIPTION=(ADDRESS=(PROTOCOL=beq)(PROGRAM=oracle)(ARGV0=oracleproddb1)))')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    sfrm, sto, scoll = s.frm, s.to, s.collected
    # ---- standby ASH: RFS (program oracle@prim-host (TNS V1-V3)) and MRP0 samples inside the wait that timed out
    for k, (ev, tw, sid) in enumerate((('RFS dispatch', 0, 311), ('RFS dispatch', 0, 311), ('RFS ping', 0, 312), ('RFS dispatch', 18000, 311))):
        s.add('tx', ts=at(t0, 4.3 + k * 6 + SH, True), p='TNS V1-V3', ev=ev, seq=7700 + k, tw=tw, sid=sid)
    s.add('tx', ts=at(t0, 12.3 + SH, True), p='MRP0', ev='log file sequential read', seq=88, tw=0, sid=44)
    ntx = sum(1 for o in s.recs if o['t'] == 'tx')
    s.setcov('ash', 'ok', at(sfrm, -1200), at(sto, 300), ntx, kind='V', note='v$active_session_history on the standby, in memory only')
    s.setcov('tx', 'ok', at(sfrm, -1200), at(sto, 300), ntx, 5000, note='redo-related wait samples on the standby')
    s.recs[:] = [o for o in s.recs if not (o['t'] == 'alert' and at(t0, -1 + SH) < o['ts'] < at(t0, 30.5 + SH))]   # no standby alert log line inside the wait: only its ASH can say whether it ran
    if gap:   # the standby's sampler did not run from just before the wait to just after it
        s.add('ashgap', ia=500200, a=at(t0, -0.6 + SH, True), iz=500201, z=at(t0, 30.9 + SH, True))
    s.setcov('ashgap', 'ok' if gap else 'empty', at(sfrm, -60), at(sto, 60), 1 if gap else 0, 50, note='gaps over 2 s between consecutive ASH samples (V)', samples=int(_secs(sfrm, sto)))
    # ---- the primary's own ASH covers the window as well (the default cov records do)
    # ---- the records of the newer collector, per host (times on the host's own clock)
    inc = (t0, at(t0, 30.2), at(t0, 320.5))
    for b, own, peer, oh, ph, shift, off in ((p, '198.51.100.11', '198.51.100.12', 'prim-host.example', 'stby-host.example', 0, '+01:00'), (s, '198.51.100.12', '198.51.100.11', 'stby-host.example', 'prim-host.example', SH, '+00:00')):
        R, C = phase3(b.side, b.frm, b.to, b.collected, plat='Linux', peer_ip=peer, own_ip=own, peer_host=ph, own_host=oh, incident=(at(inc[0], shift), at(inc[1], shift), at(inc[2], shift)),
                      tx_n=sum(1 for o in b.recs if o['t'] == 'tx'), ash_first=at(b.frm, -600), ash_last=at(b.collected, -60), sampler=False)
        R = [o for o in R if o['t'] not in ('sar', 'netsamp', 'lsnr_srv', 'dgstatus', 'ntp')]
        C = [c for c in C if not (c['src'] in ('sar', 'netsamp', 'lsnr_srv', 'dgstatus', 'ntp', 'ash', 'tx', 'ashgap') and (c['src'] != 'tx' or b is p))]
        b.recs.extend(R)
        for c in C:
            b.covs[(c['src'], c.get('kind'))] = c
    p.setcov('tx', 'ok', at(p.frm, -3600), at(p.to, 900), sum(1 for o in p.recs if o['t'] == 'tx'), note='transport wait samples in ASH')
    # sampler: one line every 5 s, 10:03:00 to 10:12:00 on the primary clock; no reply from 10:05:05 to 10:05:30
    for b, shift, off in ((p, 0, '+01:00'), (s, SH, '+00:00')):
        k, n = 0, 0
        while k * 5 <= 540:
            tt = at('2026-11-20 10:03:00', k * 5)
            lossy = at(t0, 5) <= tt <= at(t0, 30)
            b.add('netsamp', ts=at(tt, shift), off=off, rtt=None if lossy else round(0.38 + (k % 5) * 0.011, 3), loss=bool(lossy), retr=18400 + 2 * k + (60 if tt > at(t0, 30) else 0), sendq=14480 if lossy else 0)
            k += 1; n += 1
        b.setcov('netsamp', 'ok', at('2026-11-20 09:59:50', shift), at('2026-11-20 10:50:00', shift), n, 5000, note='samples of net_sampler.sh from /var/tmp/net_sampler.log (peer=%s port=1526 interval=5 started=%s)' % ('198.51.100.12' if b is p else '198.51.100.11', at('2026-11-20 09:59:50', shift)))
    # sysstat: rows every 10 minutes (the interval ends at the row's time); the first row after the window is kept
    ROWS = ['10:00:01', '10:10:01', '10:20:01', '10:30:01', '10:40:01', '10:50:01']
    rpm = {'ETCP': {'atmptf/s': (0.01, 0.12, 0.02), 'estres/s': (0.03, 0.2, 0.04), 'retrans/s': (0.02, 12.5, 0.05), 'isegerr/s': (0.0, 0.4, 0.0), 'orsts/s': (0.05, 0.9, 0.05)},
           'TCP': {'active/s': (0.2, 0.2, 0.2), 'passive/s': (0.1, 0.1, 0.1), 'iseg/s': (310.0, 150.0, 300.0), 'oseg/s': (290.0, 140.0, 280.0)}}
    for b, shift in ((p, 0), (s, SH)):
        sarcov = {}
        for rpt in ('ETCP', 'TCP', 'DEV', 'EDEV'):
            if b is s and rpt in ('ETCP', 'TCP'):
                b.setcov('sar', 'error', None, None, 0, 2000, False, '2026-11-20: Requested activities not available in file /var/log/sa/sa20', kind=rpt)
                continue
            n = 0
            for k, hms in enumerate(ROWS):
                tt = at('2026-11-20 ' + hms, shift)
                if rpt in rpm:
                    m = {key: vals[min(k, 2)] for key, vals in rpm[rpt].items()}
                    b.add('sar', rpt=rpt, ts=tt, **{'if': None}, m=m); n += 1
                else:
                    for ifc, rx in (('eth0', 120.5), ('eth1', 3.2), ('lo', 55.0)):
                        busy = 1 if k == 1 else 0
                        if rpt == 'DEV':
                            m = {'rxpck/s': round(rx * 1.2 + busy * 4, 2), 'txpck/s': round(rx * 0.9, 2), 'rxkB/s': round(rx + busy * 6, 2), 'txkB/s': round(rx * 0.7, 2), 'rxcmp/s': 0.0, 'txcmp/s': 0.0, 'rxmcst/s': 0.0}
                        else:
                            m = {'rxerr/s': 0.0, 'txerr/s': 0.0, 'coll/s': 0.0, 'rxdrop/s': 0.5 if (ifc == 'eth1' and busy) else 0.0, 'txdrop/s': 0.0, 'txcarr/s': 0.0, 'rxfram/s': 0.0, 'rxfifo/s': 0.0, 'txfifo/s': 0.0}
                        b.add('sar', rpt=rpt, ts=tt, **{'if': ifc}, m=m); n += 1
            b.setcov('sar', 'ok', at('2026-11-20 00:00:01', shift), at('2026-11-20 10:50:01', shift), n, 2000, False, 'sar -n %s, each row is the average over the interval that ends at its time' % rpt, kind=rpt)
    # listener: connections whose CID names PROGRAM=oracle
    p.add('lsnr_srv', ts=at(t0, 305.4), host='stby-host.example', ip='198.51.100.12', port=50123, svc='proddb', code='0')
    p.add('lsnr_srv', ts=at(t0, 306.2), host='stby-host.example', ip='198.51.100.12', port=50125, svc='proddb', code='0')
    p.add('lsnr_srv', ts=at(t0, 307.0), host='dblink-host.example', ip='192.0.2.77', port=61000, svc='proddb', code='0')
    s.add('lsnr_srv', ts=at(t0, 40.6 + SH), host='prim-host.example', ip='198.51.100.11', port=51234, svc='SID:proddb_s', code='12518')
    s.add('lsnr_srv', ts=at(t0, 311.0 + SH), host='prim-host.example', ip='198.51.100.11', port=51301, svc='SID:proddb_s', code='0')
    for b, shift, n in ((p, 0, 3), (s, SH, 2)):
        b.setcov('lsnr_srv', 'ok', at(b.frm, -30 * 86400), at(b.to, 900), n, 500, note='establish lines with PROGRAM=oracle in the window')
    # clock state, as collected
    for b, off_s in ((p, 0.000412), (s, -0.00311)):
        o = [x for x in b.recs if x['t'] == 'ntp']
        b.add('ntp', tool='chronyc tracking', ref='ntp1.example.net', stratum=3, off=off_s, synced='yes', at=b.collected, note='leap status: Normal')
        b.setcov('ntp', 'ok', b.collected, b.collected, 1, note='chronyc tracking, as collected: the clock state now, not at the incident')
    # Data Guard status rows (in the window), both sides
    p.add('dgstatus', ts=at(t0, 30.3), facility='Log Transport Services', severity='Error', dest=2, err=16198, msg="LGWR: Error 16198 for archive log file 3 to 'proddb_s_dgmgrl'")
    p.add('dgstatus', ts=at(t0, 320.4), facility='Log Transport Services', severity='Control', dest=2, err=0, msg='LGWR: LAD:2 SYNC destination is SYNCHRONIZED')
    s.add('dgstatus', ts=at(t0, 31.2 + SH), facility='Network Services', severity='Error', dest=0, err=12535, msg='TNS-12535: TNS:operation timed out')
    for b, n in ((p, 2), (s, 1)):
        b.setcov('dgstatus', 'ok', at(b.frm, -4 * 3600), at(b.collected, -30), n, 500, note='v$dataguard_status, in memory (lost at restart)')
    # earlier episodes at about the same time of day (the primary's alert log history), with routine lines that must not count
    for d in ('2026-11-19', '2026-11-18', '2026-11-16', '2026-11-13', '2026-11-12', '2026-11-06'):
        p.add('alhist', ts=d + ' 10:04:%02d' % (10 + len(d) % 7), msg='LGWR (PID:2201): ORA-16198: Received timed out error from KSR')
        p.add('alhist', ts=d + ' 10:04:%02d' % (11 + len(d) % 7), msg=LAD_U.format(' reason no connection'))
    p.add('alhist', ts='2026-11-14 03:12:00', msg=LAD_U.format(' reason no connection'))
    p.setcov('alhist', 'ok', at(p.frm, -30 * 86400), at(p.to, 900), 13, 300, False, 'v$diag_alert_ext, lookback 30 days, newest 300 kept', kind='sql')
    # baseline: day 3 is outside the AWR retention, day 5 spans an instance restart (no usable delta)
    for d in range(1, 8):
        snaps = 0 if d == 3 else 1
        used = 0 if d in (3, 5) else 1
        p.recs[:] = [o for o in p.recs if not (o['t'] == 'base_day' and o['d'] == d)]
        p.add('base_day', d=d, **{'from': at(p.frm, -d * 86400), 'to': at(p.to, -d * 86400)}, snaps=snaps, used=used, b=None if not snaps else at('2026-11-20 10:00:04', -d * 86400), e=None if not used else at('2026-11-20 10:30:05', -d * 86400))
    p.recs[:] = [o for o in p.recs if not (o['t'] == 'base_hist' and o['d'] in (3, 5))]
    p.setcov('base_hist', 'ok', at(p.frm, -8 * 86400), at(p.to, -600), 5, None, False, 'previous 7 days, same clock interval; n = days with a usable histogram delta', kind=None)
    sc_full_new(p, s)
    return p, s


def new4_common(p, s, lfs_cap=None):
    """lfs_by (from the lfs records of the primary) and the skipped cov records of the standby: the part of the new records every scenario that has them shares"""
    lb, ng = lfs_by_from([o for o in p.recs if o['t'] == 'lfs'])
    p.recs.extend(lb)
    p.setcov('lfs_by', 'ok', at(p.frm, -3600), at(p.to, 900), ng if lfs_cap is None else lfs_cap, 15, lfs_cap is not None,
             'log file sync samples in ASH (V) by service, module and machine, the 15 groups with the most samples kept per list; n = groups found over the three lists; first/last = what ASH holds')
    for src in ('lfs_by', 'wl_hist'):
        s.setcov(src, 'skipped', note='not collected on the standby')
    for k in ('job', 'logsw'):
        s.setcov('act', 'skipped', note='not collected on the standby', kind=k)


def wl_hourly(first, last, special):
    def val(d):
        redo = round((0.4 if d.hour < 6 else 1.4 + 0.1 * (d.day % 4)), 2)
        r, m = special.get(d.strftime('%Y-%m-%d %H'), (redo, round(redo * 1.6 + 0.2, 2)))
        return r, m, round(r * 20.0, 1)
    return hourly(first, last, val)


def sc_full_new(p, s):
    """the second newer-collector step for `full`: who waited, the workload per AWR interval, the lines that end an UNSYNCHRONIZED period, scheduled activity (primary clock; the standby's rows are on its own clock, one hour behind).
    The episodes of the history (10:04:13 on 11-19, 11-18, 11-16, 11-13, 11-12, 11-06 and 03:12:00 on 11-14) and the incident of the window (10:05:00 on 11-20) are what these records are read against:
    the AWR and the alsync history start on 11-08 (11-06 is not covered), the log-switch history on 11-10, an RMAN backup starts at 09:57:40 before five of the seven episodes it covers."""
    new4_common(p, s)
    wh = wl_hourly('2026-11-12 00:00', '2026-11-20 14:00', {'2026-11-20 10': (0.84, 3.3), '2026-11-19 10': (1.9, 2.8)})
    p.recs.extend(wh)
    p.setcov('wl_hist', 'ok', '2026-11-12 00:00:00', '2026-11-20 14:00:00', len(wh), 1500, False,
             'dba_hist_sysmetric_summary, group 2, lookback 30 days, one record per AWR snapshot interval, newest 1500 kept; first/last = the span the view holds, n = intervals in the lookback')
    for t in ('2026-11-19 10:09:21', '2026-11-18 10:09:40', '2026-11-13 10:09:18', '2026-11-12 10:09:51', '2026-11-20 10:10:20'):
        p.add('alsync', ts=t, msg='LGWR (PID:2201): LAD:2 is SYNCHRONIZED')
    p.setcov('alsync', 'ok', '2026-11-08 00:00:05', '2026-11-20 13:59:40', 5, 300, False,
             'v$diag_alert_ext, lookback 30 days, newest 300 kept; lines that end an UNSYNCHRONIZED period of a destination (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='sql')
    s.setcov('alsync', 'empty', '2026-11-08 00:00:05', at(s.collected, -60), 0, 300, False, 'text alert log, lookback 30 days, newest 300 kept; lines that end an UNSYNCHRONIZED period (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='text')
    rm = [('BACKUP ARCHIVELOG', '2026-11-%02d 09:57:40' % d, 262, 'COMPLETED') for d in (12, 13, 18, 19, 20)] + [('BACKUP ARCHIVELOG', '2026-11-16 02:00:03', 250, 'COMPLETED'), ('DELETE', '2026-11-15 03:30:12', 41, 'COMPLETED')]
    for name, a, secs, st in sorted(rm, key=lambda x: x[1]):
        p.add('act', kind='rman', name=name, a=a, z=at(a, secs), st=st)
    p.setcov('act', 'ok', '2026-11-08 02:00:01', '2026-11-20 09:57:40', len(rm), 500, False,
             'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman')
    for a in ('2026-11-20 09:58:30', '2026-11-19 02:10:00'):   # the standby's own backups, on its clock (one hour behind the primary's): the first starts 6 min 30 s before the incident of the window
        s.add('act', kind='rman', name='BACKUP ARCHIVELOG', a=at(a, SH_FULL), z=at(a, 300 + SH_FULL), st='COMPLETED')
    s.setcov('act', 'ok', at('2026-11-08 02:10:00', SH_FULL), at('2026-11-20 09:58:30', 300 + SH_FULL), 2, 500, False,
             'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman')
    p.add('act', kind='job', name='APP.EXPORT_REPORTS', con=0, a='2026-11-19 10:02:00', z='2026-11-19 10:07:00', st='SUCCEEDED', freq=False, n=1)
    p.add('act', kind='job', name='APP.NIGHTLY_CLEANUP', con=0, a='2026-11-19 01:30:00', z='2026-11-19 01:33:00', st='SUCCEEDED', freq=False, n=1)
    p.add('act', kind='job', name='APP.POLL_QUEUE', con=0, a='2026-10-21 14:46:00', z='2026-11-20 14:30:00', st=None, freq=True, n=2880)
    p.setcov('act', 'ok', '2026-10-21 14:46:00', '2026-11-20 14:30:00', 2882, 2000, False,
             'cdb_scheduler_job_run_details, lookback 30 days, newest 2000 run records kept, a job with more than 24 runs a day is one summary record; n = all rows in the lookback; first/last = the oldest and newest start the view holds, in the UTC offset this host has now', kind='job')
    sw = ['2026-11-%02d %02d:17:%02d' % (d, h, (d * 7 + h) % 60) for d in range(10, 21) for h in range(0, 24) if (d, h) <= (20, 14) and h != 10]
    sw += ['2026-11-18 10:04:30', '2026-11-20 10:04:52']
    sw = sorted(set(sw))
    for i, t in enumerate(sw):
        p.add('act', kind='logsw', a=t, thr=1, seq=88000 + i)
    p.setcov('act', 'ok', sw[0], sw[-1], len(sw), 5000, False, 'v$log_history, lookback 30 days, newest 5000 kept; first/last = the oldest and newest first_time the view holds', kind='logsw')


SH_FULL = -3600


def sc_hist_new(p, s):
    """for `hist`: the capped, failed and not-covered paths. The alsync history starts on 11-04 (the episode of 11-02 is not covered, the one of 11-19 has no return line); the AWR holds 11-04 on; the RMAN list is capped (500 of 620 rows,
    the oldest kept starts on 11-08: the episodes of 11-02 and 11-07 are not covered); the job read failed; the log switches cover everything; lfs_by is capped"""
    new4_common(p, s, lfs_cap=44)
    wh = wl_hourly('2026-11-04 00:00', '2026-11-20 12:00', {'2026-11-10 10': (0.7, 2.9)})
    p.recs.extend(wh)
    p.setcov('wl_hist', 'ok', '2026-11-04 00:00:00', '2026-11-20 12:00:00', len(wh), 1500, False,
             'dba_hist_sysmetric_summary, group 2, lookback 30 days, one record per AWR snapshot interval, newest 1500 kept; first/last = the span the view holds, n = intervals in the lookback')
    for t in ('2026-11-07 10:09:40', '2026-11-10 10:10:20', '2026-11-14 10:09:55', '2026-11-17 10:09:48'):
        p.add('alsync', ts=t, msg='LGWR (PID:2201): LAD:2 is SYNCHRONIZED')
    p.setcov('alsync', 'ok', '2026-11-04 00:00:05', '2026-11-20 11:59:40', 4, 300, False,
             'v$diag_alert_ext, lookback 30 days, newest 300 kept; lines that end an UNSYNCHRONIZED period of a destination (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='sql')
    s.setcov('alsync', 'skipped', note='alert log not readable: /u01/app/oracle/diag/rdbms/proddb_s/proddb1/trace/alert_proddb1.log', kind='text')
    days = [d for d in range(8, 21)]
    for d in days:
        p.add('act', kind='rman', name='BACKUP ARCHIVELOG', a='2026-11-%02d 09:57:30' % d, z='2026-11-%02d 10:02:10' % d, st='COMPLETED')
    p.add('act', kind='rman', name='BACKUP DB INCR', a='2026-11-10 09:58:00', z=None, st='RUNNING')
    p.setcov('act', 'ok', '2026-10-01 02:00:01', '2026-11-20 09:57:30', 620, 500, True,
             'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman')
    s.setcov('act', 'error', note='ORA-00942: table or view does not exist', kind='rman', cap=500)
    p.setcov('act', 'error', note='the cdb_scheduler_job_run_details statement failed', cap=2000, kind='job')
    sw = ['2026-11-%02d %02d:41:00' % (d, h) for d in range(1, 21) for h in range(0, 24, 3) if (d, h) <= (20, 12)] + ['2026-11-10 10:04:35', '2026-11-19 10:04:03']
    for i, t in enumerate(sorted(set(sw))):
        p.add('act', kind='logsw', a=t, thr=1, seq=500 + i)
    p.setcov('act', 'ok', '2026-10-27 00:00:00', max(sw), len(set(sw)), 5000, False, 'v$log_history, lookback 30 days, newest 5000 kept; first/last = the oldest and newest first_time the view holds', kind='logsw')


def sc_late():
    """Both instances started after the window (a restart the next day): the counters since startup (RFS histogram, destination histogram) hold nothing from the incident, the standby's ASH does not reach the window"""
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:30:00')
    p.collected = s.collected = '2026-11-20 14:00:00'
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60) if not 290 <= 20 + 17 * k <= 340], 'SYNC Remote Write', 3, 100)
    incident16198(p, s, '2026-11-20 10:05:00')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    inc = ('2026-11-20 10:05:00', '2026-11-20 10:05:30.2', '2026-11-20 10:10:20')
    for b, own, peer, oh, ph in ((p, '198.51.100.11', '198.51.100.12', 'prim-host.example', 'stby-host.example'), (s, '198.51.100.12', '198.51.100.11', 'stby-host.example', 'prim-host.example')):
        R, C = phase3(b.side, b.frm, b.to, b.collected, plat='Linux', peer_ip=peer, own_ip=own, peer_host=ph, own_host=oh, incident=inc, startup='2026-11-20 12:00:00',
                      tx_n=sum(1 for o in b.recs if o['t'] == 'tx'), ash_first='2026-11-20 12:00:30', ash_last='2026-11-20 13:59:00', sampler=False)
        b.recs.extend(R)
        for c in C:
            if not (b is p and c['src'] in ('ash', 'tx')):
                b.covs[(c['src'], c.get('kind'))] = c
        b.meta_extra = dict(b.meta_extra, startup='2026-11-20 12:00:00')
    return p, s


def sc_hist():
    """The window is older than the newest lines of the alert-log history (which is read back from the COLLECTION time): the history holds episodes before the window and episodes after it"""
    p, s = base_pair('2026-11-10 10:00:00', '2026-11-10 10:45:00')
    p.collected = s.collected = '2026-11-20 12:00:00'
    pairs(p, [at('2026-11-10 10:00:00', 20 + 17 * k, True) for k in range(60) if not 290 <= 20 + 17 * k <= 340], 'SYNC Remote Write', 3, 100)
    incident16198(p, s, '2026-11-10 10:05:00')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    for d, sec in (('2026-11-02', 11), ('2026-11-07', 12), ('2026-11-14', 13), ('2026-11-17', 14), ('2026-11-19', 15)):   # two episodes before the window, three after it
        p.add('alhist', ts='%s 10:04:%02d' % (d, sec), msg='LGWR (PID:2201): ORA-16198: Received timed out error from KSR')
        p.add('alhist', ts='%s 10:04:%02d' % (d, sec + 1), msg=LAD_U.format(' reason no connection'))
    p.setcov('alhist', 'ok', '2026-10-21 12:00:05', '2026-11-20 11:59:40', 10, 300, False, 'v$diag_alert_ext, lookback 30 days, newest 300 kept', kind='sql')
    sc_hist_new(p, s)
    return p, s


def sc_stfail():
    """`full` with the statements of the newer sources failing, as in the first live run: the job read has its records (the row statement ran) but its count statement failed, so its cov record is st error;
    the RMAN reads of both hosts, the log-switch read, the workload history, the alsync pass of the primary and lfs_by wrote no records and an error cov record (the notes the SQL writes). The report must say
    'not checked' for every one of them: never 'none' (the source did not hold the interval) and never 'not covered' (it was not read at all). The records that did arrive may still be drawn."""
    p, s = sc_full()

    def fail(b, src, note, cap, kind=None):
        b.recs[:] = [o for o in b.recs if not (o['t'] == src and (src != 'act' or o.get('kind') == kind))]   # only act records carry a kind
        b.setcov(src, 'error', None, None, 0, cap, False, note, **({'kind': kind} if kind else {}))
    p.setcov('act', 'error', None, None, 0, 2000, False, 'the cdb_scheduler_job_run_details statement failed', kind='job')
    fail(p, 'act', 'the v$rman_status statement failed', 500, 'rman')
    fail(s, 'act', 'the v$rman_status statement failed', 500, 'rman')
    fail(p, 'act', 'the v$log_history statement failed', 5000, 'logsw')
    fail(p, 'wl_hist', 'the dba_hist_sysmetric_summary statement failed', 1500)
    fail(p, 'alsync', 'the pass over v$diag_alert_ext failed', 300, 'sql')
    fail(p, 'lfs_by', 'the statement over ASH failed', 15)
    s.setcov('alsync', 'skipped', note='alert log not readable: /u01/app/oracle/diag/rdbms/proddb_s/proddb1/trace/alert_proddb1.log', kind='text')
    return p, s


def sc_capped():
    """`full` with every lookback source that has a cap cut at it: the newest records were kept and the oldest rows of the view were not, so the cov record's first is older than the oldest kept record.
    A capped source holds from its oldest kept record on: the episodes before that are 'not covered', the ones inside it get an answer (a name or 'none'), and the count lines say the source was cut.
    Oldest kept: job runs 11-13 09:30 (2000 of 5400 run records, one frequent job summarised), RMAN commands of the primary 11-16 (500 of 520), log switches 11-16 (5000 of 6200),
    alsync lines 11-18 (300 of 340), wl_hist intervals 11-17 (1500 of 1800). The standby's RMAN list is not capped. The episodes: 11-06, 11-12, 11-13, 11-14 03:12, 11-16, 11-18 and 11-19 (10:04 unless
    noted) and the incident of the window, 11-20 10:05."""
    p, s = sc_full()

    def newest(src, kind, field, since):   # keep the records of that source (and kind) from `since` on
        p.recs[:] = [o for o in p.recs if not (o['t'] == src and o.get('kind') == kind and o[field] < since)]
    newest('act', 'rman', 'a', '2026-11-16 00:00:00')
    newest('act', 'logsw', 'a', '2026-11-16 00:00:00')
    newest('alsync', None, 'ts', '2026-11-18 00:00:00')
    newest('wl_hist', None, 'b', '2026-11-17 00:00')
    p.recs[:] = [o for o in p.recs if not (o['t'] == 'act' and o.get('kind') == 'job')]
    for name, a, secs in (('APP.NIGHTLY_CLEANUP', '2026-11-13 09:30:00', 180), ('APP.EXPORT_REPORTS', '2026-11-19 10:02:00', 300), ('APP.EXPORT_REPORTS', '2026-11-20 09:58:00', 150)):
        p.add('act', kind='job', name=name, con=0, a=a, z=at(a, secs), st='SUCCEEDED', freq=False, n=1)
    p.add('act', kind='job', name='APP.POLL_QUEUE', con=0, a='2026-10-21 14:46:00', z='2026-11-20 14:30:00', st=None, freq=True, n=2880)
    last = lambda k: max(o['a'] for o in p.recs if o['t'] == 'act' and o.get('kind') == k)
    p.setcov('act', 'ok', '2026-10-21 14:46:00', '2026-11-20 14:30:00', 5400, 2000, True,
             'cdb_scheduler_job_run_details, lookback 30 days, newest 2000 run records kept, a job with more than 24 runs a day is one summary record; n = all rows in the lookback; first/last = the oldest and newest start the view holds, in the UTC offset this host has now', kind='job')
    p.setcov('act', 'ok', '2026-11-08 02:00:01', last('rman'), 520, 500, True, 'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman')
    p.setcov('act', 'ok', '2026-11-10 00:17:00', last('logsw'), 6200, 5000, True, 'v$log_history, lookback 30 days, newest 5000 kept; first/last = the oldest and newest first_time the view holds', kind='logsw')
    p.setcov('alsync', 'ok', '2026-11-08 00:00:05', '2026-11-20 13:59:40', 340, 300, True,
             'v$diag_alert_ext, lookback 30 days, newest 300 kept; lines that end an UNSYNCHRONIZED period of a destination (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='sql')
    s.setcov('alsync', 'skipped', note='alert log not readable: /u01/app/oracle/diag/rdbms/proddb_s/proddb1/trace/alert_proddb1.log', kind='text')
    p.setcov('wl_hist', 'ok', '2026-10-21 00:00:00', '2026-11-20 14:00:00', 1800, 1500, True,
             'dba_hist_sysmetric_summary, group 2, lookback 30 days, one record per AWR snapshot interval, newest 1500 kept; first/last = the span the view holds, n = intervals in the lookback')
    return p, s


def sc_waitcov():
    """The ASH sampler-gap check ends shortly after the SYNC wait that timed out (the samples read stop at 10:06:20) while ASH itself holds the whole incident interval, as in a live case: the check has an answer
    for the wait and none for the rest of the incident interval"""
    p, s = base_pair('2026-11-20 10:00:00', '2026-11-20 10:45:00')
    pairs(p, [at('2026-11-20 10:00:00', 20 + 17 * k, True) for k in range(60) if not 290 <= 20 + 17 * k <= 340], 'SYNC Remote Write', 3, 100)
    incident16198(p, s, '2026-11-20 10:05:00')
    lsnr(p, p.frm, p.to)
    lsnr(s, s.frm, s.to, 2)
    p.setcov('ashgap', 'empty', '2026-11-20 09:59:00', '2026-11-20 10:06:20', 0, 50, False, 'gaps over 2 s between consecutive ASH samples (V), 1 s per sample_id; first/last = samples read, one minute around the window', samples=440)
    return p, s


SCENARIOS = {'quiet': sc_quiet, 'two': sc_two, 'noash': sc_noash, 'drift': sc_drift, 'lost': sc_lost, 'tzoff': sc_tzoff, 'rtpmode': sc_rtpmode, 'rac': sc_rac, 'full': sc_full, 'sbgap': lambda: sc_full(gap=True), 'late': sc_late, 'hist': sc_hist, 'waitcov': sc_waitcov, 'stfail': sc_stfail, 'capped': sc_capped}


def gen(outdir):
    import os
    os.makedirs(outdir, exist_ok=True)
    for name, fn in SCENARIOS.items():
        for b in fn():
            with open(os.path.join(outdir, '%s_%s.jsonl' % (name, b.side)), 'w', encoding='utf-8') as f:
                for o in b.lines():
                    f.write(json.dumps(o, separators=(',', ':'), ensure_ascii=False) + '\n')


def sample(recs):
    """add commit waits and sampler records to an example bundle, consistent with its story (a 30 s SYNC wait that ends in ORA-16198)"""
    recs = [o for o in recs if o['t'] not in ('lfs', 'lfs_sum', 'ashgap') and not (o['t'] == 'cov' and o['src'] in ('lfs', 'ashgap'))]
    if recs[0]['side'] != 'primary':
        j = next(k for k, o in enumerate(recs) if o['t'] == 'cov' and o['src'] == 'sysmetric')
        skip = [{'t': 'cov', 'side': 'standby', 'src': src, 'st': 'skipped', 'first': None, 'last': None, 'n': 0, 'cap': None, 'capped': False, 'note': 'not collected on the standby'} for src in ('lfs', 'ashgap')]
        return recs[:j + 1] + skip + recs[j + 1:]
    for o in recs:   # the 20:38:52 sample of LGWR carried time_waited 26.4 s although the wait ended with ORA-16198 at 20:38:58.7: AWR keeps one sample in ten, so no sample carries it
        if o['t'] == 'tx' and o['ts'].startswith('2026-11-13 20:38:52') and o['p'] == 'LGWR':
            o['tw'] = 0
    buckets = [('2026-11-13 20:37:40', 4), ('2026-11-13 20:37:50', 12), ('2026-11-13 20:38:00', 9), ('2026-11-13 20:38:10', 13), ('2026-11-13 20:38:20', 14),
               ('2026-11-13 20:38:30', 16), ('2026-11-13 20:38:40', 17), ('2026-11-13 20:38:50', 18)]
    waits, sid = [], 100
    for i, (b, n) in enumerate(buckets[:5]):       # before the stall: short commit waits, one sample each, some with the exact time_waited
        for k in range(n):
            sid += 1
            z = at(b, 0.118 + 0.0 * k, True)
            waits.append({'t': 'lfs', 'side': 'primary', 'sid': sid, 'ser': sid * 3 + 1, 'seq': 8000 + sid, 'a': z, 'z': z, 'n': 1,
                          'tw': (1000000 + 90000 * (k % 8)) if (i in (2, 3, 4) and k % 3 == 0) else 0, 'lg': 1})
    for k in range(18):                              # the stall: waits from the start of the 20:38:30 bucket to the 20:38:50 sample, released by the error at 20:38:58.7
        sid += 1
        first = 0 if k < 16 else (1 if k == 16 else 2)
        a = at('2026-11-13 20:38:30', 0.118 + 10 * first, True)
        waits.append({'t': 'lfs', 'side': 'primary', 'sid': sid, 'ser': sid * 3 + 1, 'seq': 8000 + sid, 'a': a, 'z': '2026-11-13 20:38:50.118', 'n': 3 - first, 'tw': 0, 'lg': 1})
    summ = {'t': 'lfs_sum', 'side': 'primary', 'waits': len(waits), 'lgwr_waits': len(waits), 'pk_n': 18, 'pk_at': '2026-11-13 20:38:50.118', 'pk_lg': 18, 'pk_lg_at': '2026-11-13 20:38:50.118'}
    gaps = {'t': 'cov', 'side': 'primary', 'src': 'ashgap', 'st': 'empty', 'first': '2026-11-13 20:34:03', 'last': '2026-11-13 20:59:03', 'n': 0, 'cap': 50, 'capped': False,
            'note': 'gaps over 2 s between consecutive ASH samples (H), 1 s per sample_id; first/last = samples read, one minute around the window', 'samples': 150}
    lcov = {'t': 'cov', 'side': 'primary', 'src': 'lfs', 'st': 'ok', 'first': '2026-11-06 09:00:03', 'last': '2026-11-14 08:59:53', 'n': len(waits), 'cap': 200, 'capped': False,
            'note': 'log file sync waits in ASH (H), longest 200 kept; first/last = what ASH holds'}
    i = max(k for k, o in enumerate(recs) if o['t'] == 'fg10')
    recs = recs[:i + 1] + waits + [summ] + recs[i + 1:]
    j = next(k for k, o in enumerate(recs) if o['t'] == 'cov' and o['src'] == 'sysmetric')
    return recs[:j + 1] + [lcov, gaps] + recs[j + 1:]


# ----------------------------------------------------------------------------------------------------------------------------
# collector phase 3: records and coverage of the new sources (fictional names, documentation addresses)
# ----------------------------------------------------------------------------------------------------------------------------
NEWREC = ('dgstatus', 'dest_hist', 'base_day', 'base_hist', 'lsnr_srv', 'ep', 'conn', 'sqlnet', 'ostcp', 'ntp', 'sar', 'netsamp', 'rfs_ev', 'dgproc', 'archgap')
NEWCOV = ('tx', 'dgstatus', 'dest_hist', 'base_hist', 'rfs_ev', 'rfs_hist', 'dgproc', 'archgap', 'lsnr_srv', 'ep', 'conn', 'sqlnet', 'ostcp', 'ntp', 'sar', 'netsamp')
STANDBYCOV = NEWCOV + ('ash', 'ashgap', 'awr_snap', 'sysmetric', 'lfs', 'alert_sql')   # on the standby these are rewritten too (ash and ashgap are collected there now)


def cov(side, src, st='ok', first=None, last=None, n=0, cap=None, capped=False, note='', **extra):
    o = {'t': 'cov', 'side': side, 'src': src}
    o.update(extra)
    o.update({'st': st, 'first': first, 'last': last, 'n': n, 'cap': cap, 'capped': capped, 'note': note})
    return o


def rec(t, side, **kw):
    o = {'t': t, 'side': side}
    o.update(kw)
    return o


def phase3(side, frm, to, coll, *, plat='AIX', peer_ip, own_ip, peer_host, own_host, peer_port=1526, incident=None, startup='2026-09-02 03:12:40',
          tx_n=0, ash_first=None, ash_last=None, sampler=False, quiet=False, utc_off='+01:00'):
    """the records and cov records of the collector's phase-3 sources for one side. `incident` = (stall start, error time, back in sync) or None.
    Returns (records, covs). `coll` = collection time (as-collected sources carry it). plat 'AIX' = no sar, no getent; 'Linux' = sar rows, getent."""
    aix = plat == 'AIX'
    R, C = [], []
    tns = '/u01/app/oracle/product/19.0.0/dbhome_1/network/admin'
    stamp = lambda a: at(a, 0)
    inc = incident or (None, None, None)
    t0, te, tb = inc
    primary = side == 'primary'

    # ---- SQL sources
    if primary:
        if incident:
            rows = [(te, 'Log Transport Services', 'Error', 2, 16198, "LGWR: Error 16198 for archive log file 3 to 'proddb_s_dgmgrl'"),
                    (at(te, 0.2), 'Log Transport Services', 'Warning', 2, 0, 'LGWR: LAD:2 network reconnect abandoned'),
                    (at(tb, -330), 'Log Transport Services', 'Control', 2, 0, 'LGWR: Attempting destination LAD:2 network reconnect'),
                    (at(tb, -4.5), 'Log Transport Services', 'Error', 2, 16198, 'ARC1: FAL archive of T-1.S-114495 to LAD:2 failed'),
                    (at(tb, -2), 'Log Transport Services', 'Control', 2, 0, 'LGWR: LAD:2 SYNC destination is SYNCHRONIZED')]
        else:
            rows = [(at(frm, 90), 'Log Transport Services', 'Control', 2, 0, 'LGWR: Completed archiving log 3 thread 1 sequence 114493')]
        for r in rows:
            R.append(rec('dgstatus', side, ts=r[0][:19], facility=r[1], severity=r[2], dest=r[3], err=r[4], msg=r[5]))
        C.append(cov(side, 'dgstatus', 'ok', at(frm, -6 * 3600), at(coll, -10), len(rows), 500, False,
                     'v$dataguard_status, in memory (lost at restart); first/last = oldest and newest row it holds, newest 500 of the window kept'))
        hb = [(1, 91244017, '11/14/2026 09:12:38'), (2, 3120, '11/13/2026 20:53:28'), (3, 411, '11/13/2026 20:53:28'), (4, 120, '11/13/2026 20:48:21'), (5, 38, '11/13/2026 20:43:58'),
              (8, 14, '11/09/2026 02:14:09'), (16, 6, '11/06/2026 20:38:41'), (30, 9, '11/13/2026 20:38:58'), (60, 2, '10/30/2026 20:45:02')]
        for d, f, hit in hb:
            R.append(rec('dest_hist', side, dest=2, dur=d, freq=f, hit=hit))
        C.append(cov(side, 'dest_hist', 'ok', coll, coll, len(hb), None, False, 'as collected, counters not limited to the window; first = last = collection time'))
        # baseline: the same clock interval on the previous 7 days, 30 minute AWR snapshots (b/e = the snapshot that was summed)
        for d in range(1, 8):   # 30 minute AWR snapshots: the ones overlapping the interval are summed, so b/e are wider than the window
            lo = datetime.strptime(frm, FMT) - timedelta(days=d)
            lo = lo.replace(minute=lo.minute // 30 * 30, second=4)
            hi = datetime.strptime(to, FMT) - timedelta(days=d)
            hi = hi.replace(minute=hi.minute // 30 * 30, second=5) + timedelta(minutes=30)
            R.append(rec('base_day', side, d=d, **{'from': at(frm, -d * 86400), 'to': at(to, -d * 86400)}, snaps=int(round((hi - lo).total_seconds() / 1800)),
                         used=int(round((hi - lo).total_seconds() / 1800)), b=lo.strftime(FMT), e=hi.strftime(FMT)))
        # a few events per day, a normal shape; the day a week before has the same tail as the incident (the history shows a recurrence)
        for d in range(1, 8):
            for ev, scale in (('SYNC Remote Write', 1.0), ('log file sync', 1.4)):
                for ms, n in ((0.5, 3400), (1, 6100), (2, 2400), (4, 410), (8, 120), (16, 41), (32, 14), (64, 6)):
                    R.append(rec('base_hist', side, d=d, ev=ev, ms=ms, n=int(n * scale * (0.9 + 0.02 * d))))
                if d == 7 and ev == 'SYNC Remote Write':
                    R.append(rec('base_hist', side, d=d, ev=ev, ms=32768, n=1))
        C.append(cov(side, 'base_hist', 'ok', at(frm, -8 * 86400 + 3600), at(coll, -720), 7, None, False,
                     'previous 7 days, same clock interval; n = days with a usable histogram delta; first/last = the AWR span held; dba_hist_event_histogram deltas, intervals after an instance restart left out'))
        for src, note in (('rfs_ev', 'not collected on the primary'), ('rfs_hist', 'not collected on the primary'), ('dgproc', 'not collected on the primary'), ('archgap', 'not collected on the primary')):
            C.append(cov(side, src, 'skipped', note=note))
    else:
        if incident:
            rows = [(at(te, 10.4), 'Network Services', 'Error', 0, 12535, 'TNS-12535: TNS:operation timed out'),
                    (at(te, 10.5), 'Remote File Server', 'Warning', 0, 0, 'RFS[7]: Possible network disconnect with primary database'),
                    (at(tb, -329), 'Remote File Server', 'Informational', 0, 0, 'RFS[8]: Assigned to RFS process (PID:22872070)'),
                    (at(tb, -2), 'Fetch Archive Log', 'Informational', 0, 0, 'Fetching gap sequence in thread 1, gap sequence 114495-114495'),
                    (tb, 'Remote File Server', 'Informational', 0, 0, 'Primary database is in MAXIMUM AVAILABILITY mode, level SYNCHRONIZED')]
        else:
            rows = [(at(frm, 90), 'Remote File Server', 'Informational', 0, 0, 'RFS[3]: Assigned to RFS process (PID:22872068)')]
        for r in rows:
            R.append(rec('dgstatus', side, ts=r[0][:19], facility=r[1], severity=r[2], dest=r[3], err=r[4], msg=r[5]))
        C.append(cov(side, 'dgstatus', 'ok', at(frm, -2 * 3600), at(coll, -30), len(rows), 500, False,
                     'v$dataguard_status, in memory (lost at restart); first/last = oldest and newest row it holds, newest 500 of the window kept'))
        R.append(rec('param', side, name='fal_server', value='proddb_p_dgmgrl'))
        # RFS events since startup (cumulative; avg 35 us on RFS write)
        ev = [('RFS write', 412880311, 0, 35.0), ('RFS random i/o', 1903442, 0, 214.0), ('RFS sequential i/o', 9213, 0, 188.0), ('RFS dispatch', 3812004, 0, 12.0),
              ('RFS ping', 91822, 0, 3100.0), ('RFS attach', 2210, 0, 410.0), ('RFS detach', 2205, 0, 150.0), ('RFS create', 1180, 0, 2980.0), ('RFS close', 1180, 0, 1220.0)]
        for name, n, tmo, avg in ev:
            R.append(rec('rfs_ev', side, ev=name, n=n, tmo=tmo, us=int(n * avg), avg_us=avg))
        C.append(cov(side, 'rfs_ev', 'ok', startup, coll, len(ev), None, False,
                     'v$system_event, RFS events, cumulative since instance startup (first = startup, last = collection time), not limited to the window'))
        buckets = ['8 microseconds', '16 microseconds', '32 microseconds', '64 microseconds', '128 microseconds', '256 microseconds', '512 microseconds', '1 millisecond', '2 milliseconds',
                   '4 milliseconds', '8 milliseconds', '16 milliseconds', '32 milliseconds', '65 milliseconds', '131 milliseconds', '262 milliseconds', '524 milliseconds', '1 second', '2 seconds']
        us = [8, 16, 32, 64, 128, 256, 512, 1000, 2000, 4000, 8000, 16000, 32000, 65000, 131000, 262000, 524000, 1000000, 2000000]
        w = [0.004, 0.31, 0.52, 0.12, 0.03, 0.01, 0.003, 0.002, 0.0008, 0.0003, 0.00008, 0.00002, 0.00001, 4e-6, 2e-6, 8e-7, 4e-7, 2e-7, 1e-7]
        total = ev[0][1]
        cnt = [max(1, int(total * x)) for x in w]
        cnt[2] += total - sum(cnt)
        for b, u, c in zip(buckets, us, cnt):
            R.append(rec('hist_su', side, ev='RFS write', b=b, us=u, n=c))
        C.append(cov(side, 'rfs_hist', 'ok', startup, coll, len(buckets), None, False,
                     'v$event_histogram_micro, RFS events, cumulative since instance startup (first = startup, last = collection time), not limited to the window'))
        procs = [('ARC0', '22413314', 'archive local', 'IDLE', None, None, 0, 0, 0, 0, 1), ('ARC1', '22872070', 'archive redo', 'IDLE', None, None, 0, 0, 0, 0, 1),
                 ('RFS', '23200112', 'RFS sync', 'IDLE', 10224042, 'log writer', 1, 114712, 0, 0, 2), ('RFS', '23200114', 'RFS archive', 'IDLE', 16974138, 'archive redo', 0, 0, 0, 0, 2),
                 ('MRP0', '9437410', 'managed recovery', 'APPLYING_LOG', None, None, 1, 114711, 4210, 2048, 0), ('TMON', '8782204', 'redo transport monitor', 'IDLE', None, None, 0, 0, 0, 0, 0)]
        for nm, pid, role, act, cpid, crole, thr, seq, blk, blks, dest in procs:
            R.append(rec('dgproc', side, name=nm, pid=pid, role=role, action=act, client_pid=cpid, client_role=crole, thr=thr, seq=seq, block=blk, blocks=blks, dest=dest,
                         since=at(startup, 86400 * 2 + len(pid))[:19]))
        C.append(cov(side, 'dgproc', 'ok', coll, coll, len(procs), None, False, 'v$dataguard_process as collected; first = last = collection time'))
        C.append(cov(side, 'archgap', 'empty', coll, coll, 0, None, False, 'v$archive_gap as collected (empty = no gap at collection time); first = last = collection time'))
        # ASH on the standby is in memory: collected the next morning it no longer reaches back to the window
        C.append(cov(side, 'ash', 'ok' if tx_n else 'empty', ash_first, ash_last, tx_n, None, False, 'v$active_session_history on the standby, in memory only; first/last = what it holds', kind='V'))
        C.append(cov(side, 'tx', 'ok' if tx_n else 'empty', ash_first, ash_last, tx_n, 5000, False,
                     'wait samples of PRnn, MRP0, ARCn, TTnn, TMON, LGWR, LGnn, NSSn, DBWn, CKPT and of programs "oracle@<host> (TNS V1-V3)" (the RFS processes; database links also look like that); transport processes kept first when capped'))
        C.append(cov(side, 'ashgap', 'empty', None if not ash_first else at(frm, -60), None if not ash_first else at(to, 60), 0, 50, False,
                     'gaps over 2 s between consecutive ASH samples (V), 1 s per sample_id; first/last = samples read, one minute around the window', samples=0 if not tx_n else int(_secs(frm, to))))
        for src in ('dest_hist', 'base_hist'):
            C.append(cov(side, src, 'skipped', note='not collected on the standby'))
        for src in ('awr_snap', 'sysmetric', 'lfs', 'alert_sql'):
            C.append(cov(side, src, 'skipped', note='not collected on the standby'))

    # ---- shell sources: listener server-to-server connections (PROGRAM=oracle), endpoints, connections, timeouts, tunables, clock, sysstat, sampler
    srv = []
    if incident and primary:
        srv = [(at(te, 17), peer_host, peer_ip, 51234, 'SID:proddb', '0'), (at(tb, -7), peer_host, peer_ip, 51301, 'SID:proddb', '0')]
    elif incident:
        srv = [(at(tb, -329), peer_host, peer_ip, 41872, 'SID:proddb_s', '0'), (at(tb, -328), peer_host, peer_ip, 41874, 'SID:proddb_s', '0'),
               (at(te, 566), peer_host, peer_ip, 42011, 'SID:proddb_s', '12518'), (at(tb, -5), peer_host, peer_ip, 42650, 'SID:proddb_s', '0')]
    for t_, h_, ip_, pt_, svc_, code_ in srv:
        R.append(rec('lsnr_srv', side, ts=t_[:19], host=h_, ip=ip_, port=pt_, svc=svc_, code=code_))
    C.append(cov(side, 'lsnr_srv', 'ok' if srv else 'empty', '2026-09-20 00:00:01', at(coll, -4), len(srv), 500, False,
                 'establish lines with PROGRAM=oracle (the other database host: redo transport, FAL, broker) in the window'))
    alias = 'proddb_s_dgmgrl' if primary else 'proddb_p_dgmgrl'
    R.append(rec('ep', side, **{'from': 'v$archive_dest' if primary else 'fal_server'}, dest=2 if primary else None, alias=alias, file=tns + '/tnsnames.ora', host=peer_host, port=peer_port, addrs=1,
                 ip=None if aix else peer_ip, ip_how=None if aix else 'getent hosts ' + peer_host,
                 note='alias %s in %s%s' % (alias, tns + '/tnsnames.ora', '; getent not found: host name not resolved' if aix else '')))
    C.append(cov(side, 'ep', 'ok', coll, coll, 1, None, False, 'destination and fal_server aliases as configured, resolved through %s/tnsnames.ora; as collected, first = last = collection time' % tns))
    conns = [(own_ip, peer_port if not primary else 41622, peer_ip, 41622 if not primary else peer_port, 'ESTABLISHED', 0, 0),
             (own_ip, peer_port if not primary else 41640, peer_ip, 41640 if not primary else peer_port, 'ESTABLISHED', 0, 0)]
    for lip, lp, pip, pp, st, sq, rq in conns:
        R.append(rec('conn', side, lip=lip, lport=lp, pip=pip, pport=pp, state=st, sendq=sq, recvq=rq))
    C.append(cov(side, 'conn', 'ok', coll, coll, len(conns), 200, False,
                 'netstat -an: TCP connections between this host and %s on port %s, as collected (not during the window); first = last = collection time' % (peer_ip, peer_port)))
    for name, setv in (('SQLNET.EXPIRE_TIME', '10'), ('SQLNET.OUTBOUND_CONNECT_TIMEOUT', None), ('SQLNET.INBOUND_CONNECT_TIMEOUT', None), ('SQLNET.RECV_TIMEOUT', None),
                       ('SQLNET.SEND_TIMEOUT', None), ('TCP.CONNECT_TIMEOUT', None)):
        R.append(rec('sqlnet', side, name=name, set=setv is not None, value=setv, file=tns + '/sqlnet.ora'))
    C.append(cov(side, 'sqlnet', 'ok', coll, coll, 6, None, False, tns + '/sqlnet.ora'))
    if aix:
        tun = [('rfc1323', '1'), ('sb_max', '4194304'), ('tcp_keepcnt', '8'), ('tcp_keepidle', '14400'), ('tcp_keepinit', '150'), ('tcp_keepintvl', '150'), ('tcp_recvspace', '262144'), ('tcp_sendspace', '262144')]
        tool = 'no -a'
    else:
        tun = [('net.ipv4.tcp_keepalive_time', '7200'), ('net.ipv4.tcp_keepalive_intvl', '75'), ('net.ipv4.tcp_keepalive_probes', '9'), ('net.ipv4.tcp_retries2', '15')]
        tool = 'sysctl -n'
    for k, v in tun:
        R.append(rec('ostcp', side, name=k, value=v, tool=tool))
    C.append(cov(side, 'ostcp', 'ok', coll, coll, len(tun), None, False, '%s TCP tunables as collected; value null = not readable here' % plat))
    off = 0.000412 if primary else -0.00311
    R.append(rec('ntp', side, tool='ntpq -p', ref='ntp1.example.net', stratum=2, off=off, synced='yes', at=coll,
                 note='system peer = the line marked *; off = system clock minus the peer, seconds, positive = ahead (ntpq reports the opposite sign, in ms)'))
    C.append(cov(side, 'ntp', 'ok', coll, coll, 1, None, False, 'ntpq -p, as collected: the clock state now, not at the incident'))
    for kind in ('ETCP', 'TCP', 'DEV', 'EDEV'):
        if aix:
            C.append(cov(side, 'sar', 'skipped', None, None, 0, 2000, False, 'AIX has no network history by default (sar on AIX does not keep these reports)', kind=kind))
        elif kind == 'EDEV':
            C.append(cov(side, 'sar', 'error', None, None, 0, 2000, False, '%s: Requested activities not available in file /var/log/sa/sa%s' % (frm[:10], frm[8:10]), kind=kind))
        else:
            nm = {'ETCP': ('retrans/s', 0.02), 'TCP': ('active/s', 0.1), 'DEV': ('rxkB/s', 30.5)}[kind]
            for k, tt in enumerate((at(frm, 60), at(to, 60))):
                R.append(rec('sar', side, rpt=kind, ts=tt[:19], **{'if': 'eth0' if kind == 'DEV' else None}, m={nm[0]: nm[1] * (1 + k)}))
            C.append(cov(side, 'sar', 'ok', frm[:11] + '00:00:01', to[:11] + '23:50:01', 2, 2000, False, 'sar -n %s, each row is the average over the interval that ends at its time' % kind, kind=kind))
    if sampler and primary and incident:   # 5 s samples; the pings get no reply from shortly after the stall began until the error, Send-Q grows to the peer
        k = 0
        while at(frm, k * 5) <= to:
            t_ = at(frm, k * 5)
            lossy = at(t0, 5) <= t_ <= at(te, 0)
            R.append(rec('netsamp', side, ts=t_, off=utc_off, rtt=None if lossy else round(0.40 + (k % 5) * 0.012, 3), loss=bool(lossy), retr=18400 + 3 * k + (40 if t_ > te else 0), sendq=14480 if lossy else 0))
            k += 1
        C.append(cov(side, 'netsamp', 'ok', at(frm, -300), at(coll, -60), k, 5000, False, 'samples of net_sampler.sh from /var/tmp/net_sampler.log (peer=%s port=%s interval=5 started=%s)' % (peer_ip, peer_port, frm[:10] + 'T20:00:01+0100')))
    else:
        C.append(cov(side, 'netsamp', 'skipped', None, None, 0, 5000, False, 'option -n not given'))
    if primary:
        C.append(cov(side, 'tx', 'ok' if tx_n else 'empty', ash_first, ash_last, tx_n, None, False,
                     'LGWR/LGnn/NSSn/TTnn/ARCn/TMON wait samples in ASH (H); first/last = what ASH holds'))
    return R, C


def sample3(recs):
    """the example bundles of the AIX story, extended with the records of collector phase 3 (idempotent)"""
    side = recs[0]['side']
    recs = [o for o in recs if o['t'] not in NEWREC and not (o['t'] == 'cov' and o['src'] in (STANDBYCOV if side == 'standby' else NEWCOV)) and not (o['t'] == 'hist_su' and o.get('side') == 'standby')
            and not (o['t'] == 'param' and o.get('name') == 'fal_server' and side == 'standby')]
    hdr = recs[0]
    frm, to, coll = hdr['from'], hdr['to'], hdr['collected']
    ntx = sum(1 for o in recs if o['t'] == 'tx')
    inc = ('2026-11-13 20:38:28', '2026-11-13 20:38:58.7', '2026-11-13 20:53:27.9')
    ip_p, ip_s = '198.51.100.11', '198.51.100.12'
    if side == 'primary':
        R, C = phase3('primary', frm, to, coll, plat='AIX', peer_ip=ip_s, own_ip=ip_p, peer_host='stby-host.example', own_host='prim-host.example', incident=inc, tx_n=ntx,
                      ash_first='2026-11-06 09:00:03', ash_last='2026-11-14 08:59:53', sampler=True)
    else:
        R, C = phase3('standby', frm, to, coll, plat='AIX', peer_ip=ip_p, own_ip=ip_s, peer_host='prim-host.example', own_host='stby-host.example', incident=inc, tx_n=0,
                      ash_first='2026-11-14 04:51:20', ash_last='2026-11-14 09:10:01')
    out = []
    for o in recs:
        if o['t'] == 'meta':
            o['startup'] = '2026-10-04 02:15:33' if side == 'primary' else '2026-09-02 03:12:40'
            if side == 'primary':
                o['cluster_database'] = 'FALSE'
                o['inst_count'] = 1
        if o['t'] == 'cov' and o['src'] == 'alhist':
            o['note'] = 'v$diag_alert_ext, lookback 30 days, newest 300 kept; routine RT_PMODE lines (PRIMARY, PHYSICAL, reason ASYNC configuration) excluded' if side == 'primary' else \
                'text alert log, last 30 days (since 2026-10-15 09:10:02), newest 300 kept; routine RT_PMODE lines (PRIMARY, PHYSICAL, reason ASYNC configuration) excluded'
            if side == 'standby':
                o['first'] = '2026-10-15 09:41:07'
        if o['t'] == 'net':
            o['via'] = 'option -p'
        out.append(o)
    # the standby's ash and ashgap cov records are real now: replace the "not collected" ones, which the filter above removed
    return out + R + C



# ----------------------------------------------------------------------------------------------------------------------------
# the second newer-collector step: lfs_by, wl_hist, alsync, act (fictional names)
# ----------------------------------------------------------------------------------------------------------------------------
NEW4 = ('lfs_by', 'wl_hist', 'alsync', 'act')


def new4_clean(recs):
    return [o for o in recs if o['t'] not in NEW4 and not (o['t'] == 'cov' and o['src'] in NEW4)]


def lfs_by_from(lfs, side='primary'):
    """lfs_by records computed from the lfs records of the bundle, so the two agree: the same waits grouped three ways. service: sid mod 5, module: sid mod 4, machine: sid mod 3"""
    svc = {0: 'ordersvc.example', 1: 'ordersvc.example', 2: 'ordersvc.example', 3: 'reportsvc.example', 4: 'hash 3427055676'}
    mod = {0: 'ordersrv', 1: 'JDBC Thin Client', 2: 'batch_loader', 3: None}
    mch = {0: 'app01.example', 1: 'app02.example', 2: 'batch01.example'}
    out = []
    for dim, f in (('service', lambda w: svc[w['sid'] % 5]), ('module', lambda w: mod[w['sid'] % 4]), ('machine', lambda w: mch[w['sid'] % 3])):
        g = {}
        for w in lfs:
            x = g.setdefault(f(w), {'n': 0, 'lg': 0, 'sess': set(), 'a': w['a'][:19], 'z': w['z'][:19]})
            x['n'] += w['n']
            x['lg'] += w['n'] if w.get('lg') else 0
            x['sess'].add((w['sid'], w['ser']))
            x['a'], x['z'] = min(x['a'], w['a'][:19]), max(x['z'], w['z'][:19])
        for name, x in sorted(g.items(), key=lambda kv: (-kv[1]['n'], str(kv[0])))[:15]:
            out.append(rec('lfs_by', side, dim=dim, name=name, n=x['n'], lg=x['lg'], sess=len(x['sess']), a=x['a'], z=x['z']))
    return out, sum(len({f(w) for w in lfs}) for f in (lambda w: svc[w['sid'] % 5], lambda w: mod[w['sid'] % 4], lambda w: mch[w['sid'] % 3]))


def hourly(first, last, val):
    """one wl_hist record per whole hour from `first` to `last` (both 'YYYY-MM-DD HH:MM'); val(begin datetime) -> (redo, redo_max, txn)"""
    out, d, end = [], datetime.strptime(first, '%Y-%m-%d %H:%M'), datetime.strptime(last, '%Y-%m-%d %H:%M')
    while d < end:
        e = d + timedelta(hours=1)
        r, rm, t = val(d)
        out.append(rec('wl_hist', 'primary', b=d.strftime('%Y-%m-%d %H:%M'), e=e.strftime('%Y-%m-%d %H:%M'), redo=r, redo_max=rm, txn=t))
        d = e
    return out


def sample4(recs):
    """the example bundles, extended with who waited (lfs_by), the workload per AWR interval (wl_hist), the lines that end an UNSYNCHRONIZED period (alsync) and scheduled activity (act): RMAN commands, scheduler
    job runs and log switches. The story: the weekly episodes at about 20:40 on Fridays follow an RMAN full backup that starts at about 20:30 on Fridays (four of the five times within ten minutes before the first line);
    the AWR holds the last eight days only, the control-file history of log switches starts on 2026-10-18 (idempotent)"""
    recs = new4_clean(recs)
    side = recs[0]['side']
    hdr = recs[0]
    coll = hdr['collected']
    R, C = [], []
    D = lambda d: datetime.strptime(d, FMT)
    f = lambda d: d.strftime(FMT)
    days = [D('2026-10-16 00:00:00') + timedelta(days=k) for k in range(30)]   # 2026-10-16 .. 2026-11-14
    fridays = [d for d in days if d.weekday() == 4] + [D('2026-11-13 00:00:00')]
    fridays = sorted({f(d) for d in fridays})
    if side == 'primary':
        lfs = [o for o in recs if o['t'] == 'lfs']
        lb, ng = lfs_by_from(lfs)
        R += lb
        C.append(cov('primary', 'lfs_by', 'ok', '2026-11-06 09:00:03', '2026-11-14 08:59:53', ng, 15, False,
                     'log file sync samples in ASH (H) by service, module and machine, the 15 groups with the most samples kept per list; n = groups found over the three lists; first/last = what ASH holds'))
        # workload per AWR snapshot interval: the last eight days are held (the same span as the AWR snapshots of this bundle)
        def val(d):
            k = (d.day * 7 + d.hour * 3) % 5
            base = 0.5 if d.hour < 6 else 1.7 + 0.15 * k
            redo = round(base * (1.2 if d.hour in (2, 3) else 1), 2)
            if f(d) == '2026-11-13 20:00:00': redo, mx = 1.31, 2.4
            elif f(d) == '2026-11-06 20:00:00': redo, mx = 1.62, 2.7
            else: mx = round(redo * 1.7 + 0.2, 2)
            return redo, mx, round(redo * 21.5, 1)
        wh = hourly('2026-11-06 09:00', '2026-11-14 09:00', val)
        R += wh
        C.append(cov('primary', 'wl_hist', 'ok', '2026-11-06 09:00:00', '2026-11-14 09:00:00', len(wh), 1500, False,
                     'dba_hist_sysmetric_summary, group 2, lookback 30 days, one record per AWR snapshot interval, newest 1500 kept; first/last = the span the view holds, n = intervals in the lookback'))
        # the lines that end an UNSYNCHRONIZED period: one per episode of the alert-log history, and the one of the window
        ret = {'2026-10-16 20:41:12': '2026-10-16 20:55:42', '2026-10-23 20:39:55': '2026-10-23 20:53:44', '2026-10-30 20:44:31': '2026-10-30 20:59:43',
               '2026-11-06 20:38:07': '2026-11-06 20:52:27', '2026-11-13 20:38:58': '2026-11-13 20:53:27'}
        for _, t in sorted(ret.items()):
            R.append(rec('alsync', 'primary', ts=t, msg='LGWR (PID:10224042): LAD:2 is SYNCHRONIZED'))
        C.append(cov('primary', 'alsync', 'ok', '2026-10-15 09:12:41', '2026-11-14 09:12:39', len(ret), 300, False,
                     'v$diag_alert_ext, lookback 30 days, newest 300 kept; lines that end an UNSYNCHRONIZED period of a destination (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='sql'))
        # RMAN: the archived logs are backed up at 02:00 every day, the database every Friday from about 20:30 on (about 41 minutes), obsolete backups are deleted on Sundays
        start = {'2026-10-16': '20:32:10', '2026-10-23': '20:33:00', '2026-10-30': '20:29:50', '2026-11-06': '20:31:05', '2026-11-13': '20:31:30'}
        rm = []
        for d in days:
            day = f(d)[:10]
            rm.append(('BACKUP ARCHIVELOG', day + ' 02:00:0%d' % (d.day % 7), 4 * 60 + 20 + d.day, 'COMPLETED'))
            if d.weekday() == 6:
                rm.append(('DELETE', day + ' 03:30:12', 55, 'COMPLETED'))
        for day, t in start.items():
            rm.append(('BACKUP DB INCR', day + ' ' + t, 41 * 60 + 20, 'COMPLETED WITH WARNINGS' if day == '2026-10-30' else 'COMPLETED'))
        rm.sort(key=lambda x: x[1])
        for name, a, secs, st in rm:
            R.append(rec('act', 'primary', kind='rman', name=name, a=a, z=f(D(a) + timedelta(seconds=secs)), st=st))
        C.append(cov('primary', 'act', 'ok', '2026-09-18 02:00:04', '2026-11-14 02:00:05', len(rm), 500, False,
                     'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman'))
        # scheduler jobs: two daily jobs, a reporting export on two Fridays, and a job that runs every 15 minutes (one summary record)
        jb = []
        for d in days:
            day = f(d)[:10]
            jb.append(('APP_OWNER.NIGHTLY_CLEANUP', day + ' 01:30:00', 3 * 60 + (d.day % 4) * 7, 'SUCCEEDED'))
            jb.append(('SYS.PURGE_LOG', day + ' 03:00:00', 12 + d.day % 3, 'SUCCEEDED'))
        jb += [('APP_OWNER.EXPORT_REPORTS', '2026-10-16 20:40:30', 162, 'SUCCEEDED'), ('APP_OWNER.EXPORT_REPORTS', '2026-11-06 20:37:10', 175, 'SUCCEEDED')]
        jb.sort(key=lambda x: x[1])
        for name, a, secs, st in jb:
            R.append(rec('act', 'primary', kind='job', name=name, con=0, a=a, z=f(D(a) + timedelta(seconds=secs)), st=st, freq=False, n=1))
        R.append(rec('act', 'primary', kind='job', name='APP_OWNER.REFRESH_MV_STOCK', con=0, a='2026-10-15 09:15:00', z='2026-11-14 09:00:00', st=None, freq=True, n=2880))
        C.append(cov('primary', 'act', 'ok', '2026-10-15 09:15:00', '2026-11-14 09:00:00', len(jb) + 2880, 2000, False,
                     'cdb_scheduler_job_run_details, lookback 30 days, newest 2000 run records kept, a job with more than 24 runs a day is one summary record; n = all rows in the lookback; first/last = the oldest and newest start the view holds, in the UTC offset this host has now', kind='job'))
        # log switches: about every 90 minutes; the window's three sequences are the ones of its arch records; two switches fall within a minute of the start of an episode
        seqs = {'2026-11-13 20:31:02': 114493, '2026-11-13 20:36:41': 114494, '2026-11-13 20:52:10': 114495}
        ts_ = []
        d = D('2026-10-18 03:12:09')
        k = 0
        while d < D('2026-11-14 09:10:00'):
            t = f(d)
            if not ('2026-11-13 20:00:00' < t < '2026-11-13 21:00:00') and not any(abs((d - D(e)).total_seconds()) < 1500 for e in ('2026-10-23 20:39:55', '2026-11-06 20:38:07')):
                ts_.append(t)
            k += 1
            d += timedelta(minutes=84 + (k * 37) % 11)
        ts_ += ['2026-10-23 20:39:41', '2026-11-06 20:38:30'] + list(seqs)
        ts_ = sorted(set(ts_))
        base = ts_.index('2026-11-13 20:31:02')
        for i, t in enumerate(ts_):
            R.append(rec('act', 'primary', kind='logsw', a=t, thr=1, seq=114493 + i - base))
        assert all(114493 + ts_.index(t) - base == q for t, q in seqs.items())
        C.append(cov('primary', 'act', 'ok', '2026-10-18 03:12:09', ts_[-1], len(ts_), 5000, False,
                     'v$log_history, lookback 30 days, newest 5000 kept; first/last = the oldest and newest first_time the view holds', kind='logsw'))
    else:
        for src in ('lfs_by', 'wl_hist'):
            C.append(cov('standby', src, 'skipped', None, None, 0, None, False, 'not collected on the standby'))
        C.append(cov('standby', 'alsync', 'empty', '2026-10-15 09:41:07', '2026-11-14 09:09:58', 0, 300, False,
                     'text alert log, last 30 days (since 2026-10-15 09:10:02), newest 300 kept; lines that end an UNSYNCHRONIZED period (LAD:n is SYNCHRONIZED, LAD:n level SYNCHRONIZED)', kind='text'))
        rm = [(f(d + timedelta(hours=3, minutes=15, seconds=d.day % 5 + 1)), 6 * 60 + 5 + d.day % 9) for d in days]
        for a, secs in rm:
            R.append(rec('act', 'standby', kind='rman', name='BACKUP ARCHIVELOG', a=a, z=f(D(a) + timedelta(seconds=secs)), st='COMPLETED'))
        C.append(cov('standby', 'act', 'ok', '2026-10-02 03:15:01', rm[-1][0], len(rm), 500, False,
                     'v$rman_status, rows of type COMMAND, lookback 30 days, newest 500 kept; first/last = the oldest and newest start time the view holds', kind='rman'))
        for k in ('job', 'logsw'):
            C.append(cov('standby', 'act', 'skipped', None, None, 0, None, False, 'not collected on the standby', kind=k))
    return recs + R + C


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == 'upgrade':
        dump(upgrade(load(a[1])))
    elif len(a) == 3 and a[0] == 'shift':
        dump(shift(load(a[2]), int(a[1])))
    elif len(a) == 3 and a[0] == 'extend':
        dump(extend(load(a[2]), a[1]))
    elif len(a) == 2 and a[0] == 'sample':
        dump(sample(load(a[1])))
    elif len(a) == 2 and a[0] == 'sample3':
        dump(sample3(load(a[1])))
    elif len(a) == 2 and a[0] == 'sample4':
        dump(sample4(load(a[1])))
    elif len(a) == 2 and a[0] == 'gen':
        gen(a[1])
    else:
        sys.exit(__doc__)

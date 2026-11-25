#!/usr/bin/env python3
"""Checks the wording of the hand-over texts (extract.py --net / --ticket output on stdin or in files).

Both texts state observations only: no interpretation, no cause, no advice, no question. A logged message may contain any word:
text inside quotation marks (a quoted message may wrap onto several lines; its own double quotation marks are written as single ones) is exempt,
everything else is checked.
Prints one line per hit and exits 1 when there is one. Also: lines are ASCII; the text holds no title line of a ticket (title, summary, impact, root cause, next steps).
With --stats FILE it prints "blocks=N lines=A,B maxwidth=W" (one line count per block) instead.
"""
import re, sys

FORBIDDEN = [r'points? to', r'ruled out', r'likely', r'unlikely', r'probabl', r'suggest', r'caus(?:e|ed|es|ing)\b', r'because', r'consistent with', r'\bmay\b', r'might', r'should', r'appears?\b', r'seems?\b',
             r'indicat', r'impl(?:y|ies|ied)', r'\breading', r'\bcould\b', r'possib', r'presum', r'therefore', r'explain', r'evidence', r'assum', r'fault', r'culprit', r'responsib', r'recommend',
             r'please', r'(?:^|[.;:] )(?:check|verify|ask|look|investigate|confirm)\b', r'investigat', r'verify', r'\bensure', r'\bnext step', r'root cause', r'summary', r'\bimpact', r'\bsuspect', r'\bblame', r'due to', r'\bperhaps\b', r'\?']
RX = re.compile('|'.join('(?:%s)' % f for f in FORBIDDEN), re.I)


def check(text, name='text'):
    hits = []
    for block in re.split(r'^#### incident.*$', text, flags=re.M):
        if block.count('"') % 2:
            hits.append('%s: an odd number of quotation marks (a quotation is not closed)' % name)
        plain = re.sub(r'"[^"]*"', '""', block, flags=re.S)   # quoted text is exempt
        for ch in plain:
            if (ord(ch) > 126 or ord(ch) < 32) and ch != '\n':
                hits.append('%s: non-ASCII or control character %r' % (name, ch))
                break
        joined = ' '.join(l.strip() for l in plain.split('\n'))   # the texts wrap at 110 columns: a wrapped line must not look like the start of a sentence
        for m in RX.finditer(joined):
            hits.append('%s: "%s" in: ...%s...' % (name, m.group(0), joined[max(0, m.start() - 60):m.end() + 60]))
    return hits


def stats(text):
    blocks = [b for b in re.split(r'^#### incident.*$', text, flags=re.M) if b.strip()]
    lines = [len(b.strip('\n').split('\n')) for b in blocks]
    width = max([len(l) for b in blocks for l in b.split('\n')] or [0])
    return 'blocks=%d lines=%s maxwidth=%d' % (len(blocks), ','.join(map(str, lines)), width)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--stats':
        print(stats(open(sys.argv[2], encoding='utf-8').read()))
        sys.exit(0)
    bad = []
    srcs = sys.argv[1:] or ['-']
    for s in srcs:
        data = sys.stdin.read() if s == '-' else open(s, encoding='utf-8').read()
        bad += check(data, s)
    print('\n'.join(bad))
    sys.exit(1 if bad else 0)

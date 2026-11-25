#!/usr/bin/env python3
"""sql_lint.py FILE...: prints one line per select whose list holds an aggregate (count, min, max, sum, avg ... not analytic) and, beside it, an item with a scalar subquery
outside any aggregate, and no GROUP BY: Oracle raises ORA-00937 (not a single-group group function) for it. The fix is to move the subquery into a one-row inline view and join it
(max((select ...)) also parses, but is null when the aggregated rows are none).
Nothing is run: a stub cannot find this, a database does. Heuristic, on the statements of sql/*.sql; exit 1 when it finds one."""
import re, sys

AGG = re.compile(r'\b(count|min|max|sum|avg|stddev|variance|listagg|json_arrayagg|json_objectagg)\s*\(', re.I)
SUB = re.compile(r'\(\s*select\b', re.I)


def strip(s):   # comments and string literals out (the length is kept: positions stay valid)
    s = re.sub(r"--[^\n]*", lambda m: ' ' * len(m.group(0)), s)
    return re.sub(r"'(?:[^']|'')*'", lambda m: "'" + ' ' * (len(m.group(0)) - 2) + "'", s)


def close(s, i):   # the index of the parenthesis that closes the one at i
    d = 0
    for j in range(i, len(s)):
        d += (s[j] == '(') - (s[j] == ')')
        if d == 0:
            return j
    return len(s)


def top_commas(s):
    out, d, cur = [], 0, ''
    for c in s:
        d += (c == '(') - (c == ')')
        if c == ',' and d == 0:
            out.append(cur); cur = ''
        else:
            cur += c
    return out + [cur]


def outside(item, rx, only_agg):
    """is there a match of rx in item that is not inside a subselect and (only_agg) not analytic / (not only_agg) not inside an aggregate's own parentheses"""
    for m in rx.finditer(item):
        stack, k = [], 0
        for k, c in enumerate(item[:m.start()]):
            if c == '(':
                stack.append(k)
            elif c == ')':
                stack.pop()
        if only_agg:
            if any(SUB.match(item, q) for q in stack) or re.match(r'\s*over\b', item[close(item, m.end() - 1) + 1:], re.I):
                continue
            return True
        if not any(re.search(r'\b(count|min|max|sum|avg|stddev|variance|listagg)\s*$', item[:q], re.I) for q in stack):
            return True
    return False


def lint(path):
    found = []
    s = strip(open(path, encoding='utf-8').read())
    for m in re.finditer(r'\bselect\b', s, re.I):
        d, j, frm = 0, m.end(), None
        while j < len(s):
            c = s[j]
            d += (c == '(') - (c == ')')
            if d < 0 or (d == 0 and c == ';'):
                break
            if d == 0 and re.match(r'from\b', s[j:j + 5], re.I) and not s[j - 1].isalnum() and s[j - 1] != '_':
                frm = j
                break
            j += 1
        items = top_commas(s[m.end():frm if frm else j])
        aggs = [outside(i, AGG, True) for i in items]
        if not any(aggs):
            continue
        bare = [i.strip()[:70].replace('\n', ' ') for i, a in zip(items, aggs) if not a and SUB.search(i) and outside(i, SUB, False)]
        if not bare or frm is None:
            continue
        d, k = 0, frm
        while k < len(s):   # the end of this select: a ; or the parenthesis that closes it
            d += (s[k] == '(') - (s[k] == ')')
            if d < 0 or (d == 0 and s[k] == ';'):
                break
            k += 1
        tail, d, group = s[frm:k], 0, False
        for q in range(len(tail)):
            d += (tail[q] == '(') - (tail[q] == ')')
            if d == 0 and re.match(r'group\s+by\b', tail[q:], re.I):
                group = True
                break
        if not group:
            found.append('%s:%d: aggregate beside a scalar subquery with no GROUP BY (ORA-00937): %s' % (path, s[:m.start()].count('\n') + 1, '; '.join(bare)))
    return found


found = [line for f in sys.argv[1:] for line in lint(f)]
print('\n'.join(found))
sys.exit(1 if found else 0)

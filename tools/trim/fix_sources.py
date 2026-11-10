#!/usr/bin/env python3
"""清掉指向「已删除目录」的 source 行。含 $ 变量的行一律跳过。"""
import os, re, sys
tree = os.path.expanduser('~/kernel/src/linux-7.2.12')
rules = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rules.txt')
gone = set()
for ln in open(rules):
    ln = ln.split('#')[0].strip()
    if ln.startswith('KILL '):
        d = ln.split()[1].rstrip('/')
        if not os.path.isdir(os.path.join(tree, d)): gone.add(d)
pat = re.compile(r'^\s*source\s+"([^"]+?)/Kconfig[^"/]*"\s*$')
removed = []
for root, _, fs in os.walk(tree):
    for f in fs:
        if not (f == 'Kconfig' or f.startswith('Kconfig.')): continue
        p = os.path.join(root, f)
        txt = open(p, encoding='utf-8', errors='surrogateescape').read()
        out, ch = [], False
        for ln in txt.splitlines(True):
            m = pat.match(ln.rstrip('\n'))
            if m and '$' not in m.group(1) and not os.path.exists(
                    os.path.join(tree, m.group(1).lstrip('./'))):
                ch = True; removed.append((p, m.group(1))); continue
            out.append(ln)
        if ch: open(p, 'w', encoding='utf-8', errors='surrogateescape').write(''.join(out))
for p, r in removed: print(f"  - {r}   ({os.path.relpath(p, tree)})")
print(f"共清理 {len(removed)} 条 source 行，涉及已删目录 {len(gone)} 个")

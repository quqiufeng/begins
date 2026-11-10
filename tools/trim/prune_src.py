#!/usr/bin/env python3
"""删除配置里已完全没人用的驱动源码目录，并清掉父 Kconfig 的 source 行。
用法: prune_src.py [--apply]"""
import re, os, sys, subprocess, collections

tree = os.path.expanduser('~/kernel/src/linux-7.2.12')
rules = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rules.txt')
apply_ = '--apply' in sys.argv

kill = []
for ln in open(rules):
    ln = ln.split('#')[0].strip()
    if ln.startswith('KILL '):
        d = ln.split()[1].rstrip('/')
        if os.path.isdir(os.path.join(tree, d)): kill.append(d)
kill.sort(key=len)

# 去掉被父目录覆盖的子项
top = []
for d in kill:
    if not any(d.startswith(t + '/') for t in top): top.append(d)

sym2kc = {}
for ln in open('/tmp/sym2kc.tsv'):
    s, f = ln.rstrip('\n').split('\t'); sym2kc.setdefault(s, f.lstrip('./'))
en = set()
for ln in open(os.path.join(tree, '.config')):
    m = re.match(r'CONFIG_(\w+)=[ym]$', ln.strip())
    if m: en.add(m.group(1))

# 每个目录下还有多少活符号
live = collections.Counter()
for s in en:
    f = sym2kc.get(s)
    if not f: continue
    for d in top:
        if f.startswith(d + '/'): live[d] += 1; break

def lines_of(d):
    n = 0
    for root, _, fs in os.walk(os.path.join(tree, d)):
        for f in fs:
            if f.endswith(('.c', '.h', '.S', '.Kconfig', '.rs')) or f == 'Makefile':
                p = os.path.join(root, f)
                try:
                    with open(p, 'rb') as fh: n += fh.read().count(b'\n')
                except OSError: pass
    return n

def mb(d):
    out = subprocess.run(['du', '-sm', os.path.join(tree, d)], capture_output=True, text=True)
    return int(out.stdout.split()[0]) if out.stdout else 0

todo = [d for d in top if live[d] == 0]
skip = [(d, live[d]) for d in top if live[d] > 0]
tot_l = tot_m = 0
print(f"可删目录 {len(todo)} 个：")
for d in todo:
    l = lines_of(d); m = mb(d); tot_l += l; tot_m += m
    print(f"  {m:5d}M {l:9d}行  {d}")
print(f"\n合计可删 {tot_m}MB / {tot_l} 行源码")
if skip:
    print("保留（里面还有活符号）:")
    for d, n in skip: print(f"  {n:4d}个活符号  {d}")
print(f"总计 {tot_m}MB / {tot_l}行")

if not apply_:
    print("\n(dry-run，加 --apply 执行)"); sys.exit(0)

# 1) 删目录 2) 清 source 行
for d in todo:
    subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
pat = re.compile(r'^\s*source\s+"([^"]+)/Kconfig"\s*$')
removed = 0
for root, dirs, fs in os.walk(tree):
    if '/.git' in root: continue
    for f in fs:
        if not (f == 'Kconfig' or f.startswith('Kconfig.')): continue
        p = os.path.join(root, f)
        try: txt = open(p, encoding='utf-8', errors='surrogateescape').read()
        except OSError: continue
        out, ch = [], False
        for ln in txt.splitlines(True):
            m = pat.match(ln.rstrip('\n'))
            if m:
                ref = m.group(1).lstrip('./')
                if any(ref == d or ref.startswith(d + '/') for d in todo) or not os.path.exists(
                        os.path.join(root, m.group(1))):
                    ch = True; removed += 1; continue
            out.append(ln)
        if ch: open(p, 'w', encoding='utf-8', errors='surrogateescape').write(''.join(out))
print(f"删除 {len(todo)} 个目录，清理 {removed} 条 source 行")

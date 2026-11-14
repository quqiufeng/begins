#!/usr/bin/env python3
"""删除配置里已完全没人用的驱动源码目录，并清掉父 Kconfig 的 source 行。
用法: prune_src.py [--apply]"""
import re, os, sys, subprocess, collections

tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rules.txt'))
apply_ = '--apply' in sys.argv

kill, protect = [], []
for ln in open(rules):
    ln = ln.split('#')[0].strip()
    if ln.startswith('KILL '):
        d = ln.split()[1].rstrip('/')
        if os.path.isdir(os.path.join(tree, d)): kill.append(d)
    elif ln.startswith('PROTECT '):
        protect.append(ln.split()[1].rstrip('/'))
kill.sort(key=len)

# 去掉被父目录覆盖的子项
top = []
for d in kill:
    if not any(d.startswith(t + '/') for t in top): top.append(d)

# 前置输入由 sym2kc.py 生成；/tmp 被清掉时自动重建
_s2k = os.environ.get('SYM2KC', '/tmp/sym2kc.tsv')
if not os.path.exists(_s2k):
    import subprocess
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sym2kc.py')], check=True)
sym2kc = {}
for ln in open(_s2k):
    s, f = ln.rstrip('\n').split('\t')
    sym2kc.setdefault(s, f.lstrip('./'))
en = set()
# config 位置：$KCONFIG > <tree>/.config > /x96-build/config-x96-trimmed（本机是 out-of-tree 构建）
_cfg = os.environ.get('KCONFIG') or next((p for p in (os.path.join(tree, '.config'),
        '/x96-build/config-x96-trimmed') if os.path.exists(p)),
        os.path.join(tree, '.config'))
for ln in open(_cfg):
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

def makefile_syms(d):
    """目录自身 Makefile 引用到的 CONFIG 符号集合。

    Kconfig 归属判据不可靠：NET_DEVLINK / ETHTOOL_NETLINK / DVB_CORE / CGROUPS / PERF_EVENTS
    都定义在父级 Kconfig（net/Kconfig、drivers/media/Kconfig、init/Kconfig），按「符号 -> 定义文件所在目录」
    归属会让这些目录永远算 0 个活符号而被误删——上次就是这么炸出 238 条 undefined reference 的。
    以目录 Makefile 为准更稳：`obj-$(CONFIG_X)` 里 X 只要在 config 里 =y/=m 就整目录保留。
    """
    out = set()
    p = os.path.join(tree, d, 'Makefile')
    try: txt = open(p, encoding='utf-8', errors='replace').read()
    except OSError: return out
    return set(re.findall(r'CONFIG_([A-Za-z0-9_]+)', txt))

def parent_gate(d):
    """父 Makefile 怎么收这个目录：('cond', SYM) / ('always', None) / (None, None)。

    目录自身整份 `obj-y := ...` 时（如 net/devlink/Makefile），它自己不带任何 CONFIG，
    活得由父层决定：`obj-$(CONFIG_NET_DEVLINK) += devlink/`。只看目录本事会把它误判为可删。
    """
    parent, base = os.path.split(d.rstrip('/'))
    mp = os.path.join(tree, parent, 'Makefile') if parent else os.path.join(tree, 'Makefile')
    try: txt = open(mp, encoding='utf-8', errors='replace').read()
    except OSError: return (None, None)
    txt = txt.replace('\\\n', ' ')          # 续行拉平
    for ln in txt.splitlines():
        if base + '/' not in ln: continue
        m = re.match(r'\s*obj-\$\(CONFIG_([A-Za-z0-9_]+)\)\s*\+?=', ln)
        if m: return ('cond', m.group(1))
        if re.match(r'\s*obj-y\s*\+?=', ln): return ('always', None)
    return (None, None)

def keep_reason(d):
    """返回保留理由字符串；None = 可删。"""
    if d in protect: return 'PROTECT'
    if live[d]:
        return '%d 个 =y/=m 符号(按 Kconfig 归属)' % live[d]
    hit = sorted(makefile_syms(d) & en)
    if hit: return 'Makefile 引用 %s (=y/=m)' % ','.join(hit[:3])
    kind, sym = parent_gate(d)
    if kind == 'cond' and sym in en: return '父 Makefile obj-$(CONFIG_%s) 收它 (=y)' % sym
    if kind == 'cond' and sym not in en: return '父 Makefile obj-$(CONFIG_%s)，config 里没有 → 真没人用' % sym
    if kind == 'always': return '父 Makefile 无条件 obj-y 收它'
    return None

reason = {d: keep_reason(d) for d in top}
todo = [d for d in top if reason[d] is None]
skip = [(d, reason[d]) for d in top if reason[d] is not None]
tot_l = tot_m = 0
print(f"可删目录 {len(todo)} 个：")
for d in todo:
    l = lines_of(d); m = mb(d); tot_l += l; tot_m += m
    print(f"  {m:5d}M {l:9d}行  {d}")
print(f"\n合计可删 {tot_m}MB / {tot_l} 行源码")
if skip:
    print("保留（里面还有活符号）:")
    for d, why in skip: print(f"  保留 {d}  <- {why}")
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

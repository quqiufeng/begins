#!/usr/bin/env python3
"""按 rules.txt 生成需禁用的 CONFIG 符号清单（不落盘，只打印/写文件）。"""
import re, sys, os, collections

tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rules.txt'))

kill, keep = [], set()
for ln in open(rules):
    ln = ln.split('#')[0].strip()
    if not ln: continue
    k, _, v = ln.partition(' ')
    v = v.strip()
    if k == 'KILL': kill.append(v.rstrip('/'))
    elif k == 'KEEP': keep.add(v.replace('CONFIG_', '', 1))

# symbol -> 定义它的 Kconfig 路径
# 前置输入由 sym2kc.py 生成；/tmp 被清掉时自动重建
_s2k = os.environ.get('SYM2KC', '/tmp/sym2kc.tsv')
if not os.path.exists(_s2k):
    import subprocess
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sym2kc.py')], check=True)
sym2kc = {}
for ln in open(_s2k):
    s, f = ln.rstrip('\n').split('\t')
    sym2kc.setdefault(s, f.lstrip('./'))

en = {}
# config 位置：$KCONFIG > <tree>/.config > /x96-build/config-x96-trimmed（本机是 out-of-tree 构建）
_cfg = os.environ.get('KCONFIG') or next((p for p in (os.path.join(tree, '.config'),
        '/x96-build/config-x96-trimmed') if os.path.exists(p)),
        os.path.join(tree, '.config'))
for ln in open(_cfg):
    m = re.match(r'CONFIG_(\w+)=([ym])$', ln.strip())
    if m: en[m.group(1)] = m.group(2)

hit = collections.defaultdict(list)
for s, v in en.items():
    if s in keep: continue
    f = sym2kc.get(s)
    if not f: continue
    for k in kill:
        if f.startswith(k + '/') or f.startswith(k):
            # 命中更长的目录优先，但一条就够（同一符号只定义一次）
            hit[k].append(s); break

out = sorted({s for v in hit.values() for s in v})
with open(os.path.join(os.path.dirname(rules), 'disable.list'), 'w') as fh:
    fh.write('\n'.join(out) + '\n')

if '-q' not in sys.argv:
    tot = 0
    for k in sorted(hit, key=lambda x: -len(hit[x])):
        if not hit[k]: continue
        tot += len(hit[k])
        print(f"{len(hit[k]):5d}  {k}")
    print(f"\n合计禁用 {len(out)} 个符号（当前 =y {sum(1 for v in en.values() if v=='y')} / =m {sum(1 for v in en.values() if v=='m')}）")

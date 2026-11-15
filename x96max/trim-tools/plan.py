#!/usr/bin/env python3
"""按 rules.txt 生成需禁用的 CONFIG 符号清单（不落盘，只打印/写 disable.list）。"""
import os, sys, collections
import _trimpath                      # noqa: F401  (sys.path)
import trimlib as T

HERE = os.path.dirname(os.path.realpath(__file__))
tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(HERE, 'rules.txt'))
cfg = T.config_path(tree, '/x96-build/config-x96-20261115')

kill, keep = [], set()
for ln in open(rules, encoding='utf-8'):
    ln = ln.split('#')[0].strip()
    if not ln: continue
    k, _, v = ln.partition(' ')
    v = v.strip().rstrip('/')
    if k == 'KILL' and v: kill.append(v)
    elif k == 'KEEP' and v: keep.add(v.replace('CONFIG_', '', 1))

s2k = T.sym2kc(tree)
en = T.enabled(cfg)

hit = collections.defaultdict(list)
for s in en:
    if s in keep: continue
    f = s2k.get(s)
    if not f: continue
    for k in kill:
        if f.startswith(k + '/') or f.startswith(k):
            hit[k].append(s); break

out = sorted({s for v in hit.values() for s in v})
with open(os.path.join(HERE, 'disable.list'), 'w') as fh:
    fh.write('\n'.join(out) + '\n')

if '-q' not in sys.argv:
    print(f"config: {cfg}")
    for k in sorted(hit, key=lambda x: -len(hit[x])):
        print(f"{len(hit[k]):5d}  {k}")
    print(f"\n合计禁用 {len(out)} 个符号（当前 =y {sum(1 for v in en.values() if v=='y')} / =m {sum(1 for v in en.values() if v=='m')}）")

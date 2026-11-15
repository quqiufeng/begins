#!/usr/bin/env python3
"""删除配置里已完全没人用的源码目录，并清掉父 Kconfig 的 source 行。

用法: prune_src.py [--apply]        （判据在 tools/trim/trimlib.py，单点维护）"""
import os, sys, subprocess
import _trimpath                      # noqa: F401  (sys.path)
import trimlib as T

HERE = os.path.dirname(os.path.realpath(__file__))
tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(HERE, 'rules.txt'))
cfg = T.config_path(tree, '/x96-build/config-x96-20261115')
apply_ = '--apply' in sys.argv

todo, skip = T.plan(tree, cfg, rules)
print(f"config: {cfg}")
tot_l = tot_m = 0
print(f"可删目录 {len(todo)} 个：")
for d in todo:
    l = T.lines_of(tree, d); m = T.mb(tree, d); tot_l += l; tot_m += m
    print(f"  {m:5d}M {l:9d}行  {d}")
print(f"\n合计可删 {tot_m}MB / {tot_l} 行源码")
if skip:
    print("保留（里面还有活符号）:")
    for d, why in skip: print(f"  保留 {d}  <- {why}")
print(f"总计 {tot_m}MB / {tot_l}行")

if not apply_:
    print("\n(dry-run，加 --apply 执行)"); sys.exit(0)
for d in todo:
    subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
print(f"删除 {len(todo)} 个目录，清理 {T.strip_sources(tree, todo)} 条 source 行")

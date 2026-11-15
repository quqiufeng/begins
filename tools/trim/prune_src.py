#!/usr/bin/env python3
"""删除配置里已完全没人用的源码目录，并清掉父 Kconfig 的 source 行。

用法: prune_src.py [--apply]        （判据全在 trimlib.judge，先 dry-run 看「可删 0 个」）"""
import os, sys, glob, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trimlib as T

def newest_config():
    c = sorted(glob.glob(os.path.expanduser('~/kernel/configs/config-7.2.12-*')), key=os.path.getmtime)
    return c[-1] if c else None

tree = os.environ.get('KTREE', os.path.expanduser('~/kernel/src/linux-7.2.12'))
rules = os.environ.get('RULES', os.path.join(HERE, 'rules.txt'))
cfg = T.config_path(tree, newest_config())
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

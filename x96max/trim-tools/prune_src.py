#!/usr/bin/env python3
"""删除配置里已完全没人用的源码目录，并清掉父 Kconfig 的 source 行。

用法: prune_src.py [--apply]        （判据在 tools/trim/trimlib.py，单点维护）"""
import os, sys, subprocess
import _trimpath                      # noqa: F401  (sys.path)
import trimlib as T

HERE = os.path.dirname(os.path.realpath(__file__))
tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(HERE, 'rules.txt'))
orig = os.environ.get('KTREE_ORIG', '/opt/linux/src/linux-7.2.12')
restore_file = os.environ.get('RESTORE', os.path.join(HERE, 'restore.txt'))


def restore_list():
    """-> 要补回的切片路径。FORCEKILL 整删之后编译链仍然硬引用的那几个目录（见 restore.txt）。"""
    out = []
    for ln in open(restore_file, encoding='utf-8'):
        ln = ln.split('#')[0].strip()
        if ln: out.append(ln.rstrip('/'))
    return out
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

rest = restore_list()
if rest:
    rm_m = sum(T.mb(tree, d) for d in rest)
    print(f"\n--apply 后补回 {len(rest)} 个切片（源 {orig}，{rm_m}MB）：")
    for d in rest: print(f"  {T.mb(tree, d):5d}M  {d}")
    print(f"净体积 = {tot_m}MB - {rm_m}MB = {tot_m - rm_m}MB")

if not apply_:
    print("\n(dry-run，加 --apply 执行)"); sys.exit(0)
for d in todo:
    subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
print(f"删除 {len(todo)} 个目录，清理 {T.strip_sources(tree, todo)} 条 source 行")
for d in rest:
    src, dst = os.path.join(orig, d), os.path.join(tree, d)
    if not os.path.isdir(src): sys.exit(f"补回源不存在: {src}（设 KTREE_ORIG 指向原版源码树）")
    subprocess.run(['rm', '-rf', dst], check=True)
    os.makedirs(os.path.dirname(dst) or tree, exist_ok=True)
    subprocess.run(['cp', '-a', src, dst], check=True)
print(f"补回 {len(rest)} 个切片：{', '.join(rest)}")

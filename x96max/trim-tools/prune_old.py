#!/usr/bin/env python3
"""旧判据重裁（复刻 2026-11-15 第一轮 1.8G -> 821M 的口径）。

判据只有一条：目录自身 Makefile 里出现 obj-$(CONFIG_X)，且 X 在当前 config 里不是 =y/=m
-> 该目录没人用，可删。**不看** Kconfig 归属(live_counts)，**不看**父 Makefile 的 obj-$(CONFIG_X)。
PROTECT / restore.txt / FORCEKILL 的架构目录按原脚本处理。

用法: prune_old.py [--apply] [-v]
"""
import os, sys, subprocess
import _trimpath                      # noqa: F401
import trimlib as T

HERE = os.path.dirname(os.path.realpath(__file__))
tree = os.environ.get('KTREE', '/x96-build/src-linux')
rules = os.environ.get('RULES', os.path.join(HERE, 'rules.txt'))
orig = os.environ.get('KTREE_ORIG', '/x96-build/orig-src')
restore_file = os.path.join(HERE, 'restore.txt')
cfg = T.config_path(tree, os.environ.get('KCONFIG') or os.path.join(
    HERE, '..', '..', 'x96max', 'kernel', 'config-7.2.12-x96-full'))
apply_ = '--apply' in sys.argv

top, protect, force = T.read_rules(rules, tree)
en = T.enabled(cfg)


def restore_list():
    return [ln.split('#')[0].strip().rstrip('/')
            for ln in open(restore_file, encoding='utf-8') if ln.split('#')[0].strip()]


rest = set(restore_list())


def old_judge(d):
    if d in protect: return 'PROTECT'
    if d in rest:    return 'restore 切片'
    if d in force:   return None
    hit = sorted(T.makefile_syms(tree, d) & set(en))
    if hit: return 'Makefile 引用 %s (=y/=m)' % ','.join(hit[:3])
    return None


reason = {d: old_judge(d) for d in top}
todo = [d for d in top if reason[d] is None]
tot_m = sum(T.mb(tree, d) for d in todo)
print("config: %s  (=%d 个 =y/=m 符号)" % (cfg, len(en)))
print("可删目录 %d 个，合计 %dMB" % (len(todo), tot_m))
skip = [(d, reason[d]) for d in top if reason[d]]
print("保留 %d 个" % len(skip))
if '-v' in sys.argv:
    for d, w in skip: print("  保留 %s  <- %s" % (d, w))

if not apply_:
    print("\n(dry-run，加 --apply 执行)"); sys.exit(0)

for d in todo:
    subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
print("删除 %d 个目录，清理 %d 条 source 行" % (len(todo), T.strip_sources(tree, todo)))
for d in sorted(rest):
    s = os.path.join(orig, d)
    if not os.path.isdir(s): sys.exit("补回源不存在: %s" % s)
    os.makedirs(os.path.join(tree, d).rsplit('/', 1)[0], exist_ok=True)
    subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
    subprocess.run(['cp', '-a', s, os.path.join(tree, d)], check=True)
for d in sorted(rest):
    p = os.path.join(tree, d, 'Makefile')
    if not os.path.exists(p):
        open(p, 'w').write('# restored slice\n')
        print("补空 Makefile: %s" % d)

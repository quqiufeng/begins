#!/usr/bin/env python3
"""目录级 Kbuild 可达性裁剪：从顶层 Kbuild 的 obj-y 往下走，按 `obj-$(CONFIG_X)` 的
=y/=m 开合，凡是走不到、又没有别处 #include 其头文件的目录，判为可删。

为什么需要它：trimlib.judge() 是逐目录的局部启发式，三种情况会永远保留死目录——
  1. 父 Makefile `obj-$(CONFIG_X) += d/` 且 X 没开 → judge 却返回「真没人用」当保留理由；
  2. 目录自己的 Makefile 里出现 `CONFIG_ACPI/COMPAT/DEBUG_FS`（=y）就算「活符号」，
     于是 `drivers/gpu/drm/i915`（真正闸门 DRM_I915=n）被误留；
  3. 父级 `obj-y += d/` 无条件收，但祖父整枝都没被编译（drivers/media/usb/dvb-usb）。
可达性把这些一次性收干。

用法：
  ./reach.py --tree /x96-build/7.2.12-trim --config .../config-7.2.12-x96-trim           # dry-run
  ./reach.py ... --apply                                                                  # 真删
"""
import os, re, sys, collections, argparse, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trimlib as T

MK = re.compile(r'^\s*(obj|libs|core|drivers|net|virt|init|always|subdir)(-y|-m|-\$\(CONFIG_(\w+)\))\s*[:+]?=\s*(.*)$')
INC = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
SKIP = {'Documentation', 'tools', 'scripts', 'rust', 'samples', '.git', 'include', 'usr',
        'firmware', 'LICENSES', 'arch'}


def logical(path):
    """把 Makefile 读成逻辑行（续行拉平）。"""
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    return txt.replace('\\\n', ' ').splitlines()


def resolve_targets(rest, vals):
    """目标串 -> 子目录名列表；`$(VAR)` 用 vals 展开，展不开的返回进 unknown。"""
    unknown = []
    for v in re.findall(r'\$\(([\w-]+)\)', rest):
        if v in vals:
            rest = rest.replace('$(%s)' % v, ' '.join(vals[v]))
        elif v.startswith('CONFIG_'):
            rest = rest.replace('$(%s)' % v, '')
        else:
            unknown.append(v)
    dirs = [t for t in rest.split() if t.endswith('/') and '$' not in t]
    return [d.rstrip('/') for d in dirs], unknown


def walk(tree, en, protect, roots):
    """BFS：-> (reachable 集合, 未知变量集合)。"""
    vals = collections.defaultdict(list)
    vals['ARCH_LIB'] = ['lib/', 'arch/arm64/lib/']          # libs-y := lib/ + arch/arm64/lib/
    vals['ARCH_CORE'], vals['ARCH_DRIVERS'] = [], ['drivers/']  # core-y := 空；drivers-y := 空
    reach, unknown, q = set(), set(), collections.deque()
    for r in roots:
        q.append(r)
        reach.add(r)
    while q:
        d = q.popleft()
        mk = os.path.join(tree, d, 'Kbuild' if not d else 'Makefile')
        if not os.path.exists(mk):
            continue
        for ln in logical(mk):
            m = MK.match(ln)
            if not m:
                continue
            gate = m.group(3)          # 组3 才是 CONFIG 名；组4 是目标串
            if gate and en.get(gate) not in ('y', 'm'):
                continue
            subs, unk = resolve_targets(m.group(4), vals)
            unknown |= {u for u in unk if not u.endswith('-objs') and u not in ('obj', 'src', 'srctree')}
            for s in subs:
                p = os.path.normpath(os.path.join(d, s)).lstrip('./') if d else s
                if p not in reach:
                    reach.add(p)
                    q.append(p)
    for p in protect:                                   # PROTECT 一律算活
        reach.add(p)
    return reach, unknown


def cross_includes(tree, reach, cands):
    """可达源码里 `#include "../x/y.h"` / "y.h" 指进候选目录的 -> 救回该候选目录。"""
    hit = collections.defaultdict(set)
    for d in reach:
        root = os.path.join(tree, d)
        if not os.path.isdir(root):
            continue
        for f in os.listdir(root):
            if not f.endswith(('.c', '.h', '.S')):
                continue
            try:
                txt = open(os.path.join(root, f), encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for inc in INC.findall(txt):
                p = os.path.normpath(os.path.join(d, inc))
                for c in cands:
                    if p == c or p.startswith(c + '/'):
                        hit[c].add(os.path.join(d, f))
    return hit


def dirs_with_files(tree):
    out = set()
    for root, ds, fs in os.walk(tree):
        ds[:] = [x for x in ds if x not in ('.git',)]
        rel = os.path.relpath(root, tree)
        if rel == '.':
            continue
        out.add(rel if rel != '..' else '')
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tree', default='/x96-build/7.2.12-trim')
    ap.add_argument('--config', default=None)
    ap.add_argument('--rules', default='/home/quqiufeng/kernel/x96max/trim-tools/rules.txt')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--min-mb', type=int, default=0)
    a = ap.parse_args()

    tree = os.path.abspath(a.tree)
    cfg = a.config or T.config_path(tree)
    en = T.enabled(cfg)
    protect = T.read_rules(a.rules, tree)[1]
    # 顶层 Kbuild 才是真入口；include/ 是纯头文件目录（不进 obj-y）必须常留；
    # scripts/ 是构建工具（kconfig/dtc/kallsyms 等）也必须留。
    roots = ['', 'include', 'scripts', 'tools/include']
    reach, unknown = walk(tree, en, protect, roots)

    allsub = set(T.read_rules(a.rules, tree)[0])
    cands = {d for d in dirs_with_files(tree)
             if d not in reach
             and d not in protect
             and not any(d.startswith(p + '/') for p in protect)}
    # 只留有源码的目录
    cands = {d for d in cands if any(f.endswith(('.c', '.h', '.S', '.rs')) or f == 'Makefile'
                                     for f in os.listdir(os.path.join(tree, d)))}
    saved = cross_includes(tree, reach, cands)
    if saved:
        print('!! #include 交叉引用，救回 %d 个目录：' % len(saved))
        for d, who in sorted(saved.items()):
            print('   %-50s <- %s' % (d, sorted(who)[0]))
        cands -= set(saved)

    # 去掉被祖先覆盖的（只删最上层）
    top = []
    for d in sorted(cands):
        if not any(d.startswith(t + '/') for t in top):
            top.append(d)

    rows = sorted(((T.mb(tree, d), T.lines_of(tree, d), d) for d in top), reverse=True)
    total = sum(r[0] for r in rows)
    print('\n可删 %d 个顶层目录，合计 %d MB / %d 行' % (len(rows), total, sum(r[1] for r in rows)))
    if unknown:
        print('未解析变量 %d 个（目标可能少算，需人工看）：%s' % (len(unknown), sorted(unknown)[:8]))
    print('\n%6s %10s  %s' % ('MB', '行', '目录'))
    for mb, ln, d in rows:
        if mb >= a.min_mb:
            print('%6d %10d  %s' % (mb, ln, d))

    if not a.apply:
        print('\n(dry-run，加 --apply 才删)')
        return

    man = os.path.join('/x96-build', 'deleted-reach.txt')
    with open(man, 'w', encoding='utf-8') as fh:
        for mb, ln, d in rows:
            fh.write('%s\n' % d)
    for mb, ln, d in rows:
        subprocess.run(['rm', '-rf', os.path.join(tree, d)], check=True)
    n = T.strip_sources(tree, top)
    print('\n已删 %d 个目录，清掉 %d 条 source 行，清单：%s' % (len(rows), n, man))


if __name__ == '__main__':
    main()

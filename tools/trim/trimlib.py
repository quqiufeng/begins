#!/usr/bin/env python3
"""源码树裁剪判据的**唯一实现**：`tools/trim` 与 `x96max/trim-tools` 都 import 它。

为什么单点：这套判据修过两次同一个坑，两份拷贝必然分叉，分叉的代价是链接期几百条
`undefined reference`。业务脚本只保留各自的默认树路径（主机树 vs /x96-build/src-linux）
和 rules.txt，判据/解析/config 定位全在这里。

判据（`judge()`，任一命中即保留）：
  1. `rules.txt` 的 `PROTECT <dir>` —— 自己不带 CONFIG、但头文件/代码被别处引用的目录
     （`fs/squashfs` ← init/do_mounts_rd.c，`net/bridge` ← net/ipv6/netfilter.c 等）。
  2. `live[d] > 0` —— 按「符号 → 定义它的 Kconfig 所在目录」归属还有活符号。**弱判据**：
     定义在父级 Kconfig 的符号（NET_DEVLINK/ETHTOOL_NETLINK 在 net/Kconfig、DVB_CORE 在
     drivers/media/Kconfig、CGROUPS/PERF_EVENTS 在 init/Kconfig）永远算不到子目录头上，
     所以它命中就保留、不命中不代表可删。
  3. `makefile_syms(d) ∩ config 的 =y/=m` —— 目录自身 Makefile 的 `obj-$(CONFIG_X)` 里 X 活着。
  4. `parent_gate(d)` —— 父 Makefile 的 `obj-$(CONFIG_X) += <dir>/` 且 X 活着；或父级无条件
     `obj-y += <dir>/`。目录自身整份 `obj-y :=`（如 `net/devlink/Makefile`）时只有这层能救它。
全不命中才判可删。**对已裁剪的树 dry-run 必须得「可删 0 个」**，出非 0 就是判据又漏了，别 `--apply`。
"""
import re, os, collections, subprocess

# ---------------------------------------------------------------- rules / config

def read_rules(path, tree):
    """-> (kill, protect)。KILL 只收磁盘上真存在的目录（已删的规则不重复报）。"""
    kill, protect = [], []
    for ln in open(path, encoding='utf-8'):
        ln = ln.split('#')[0].strip()
        if not ln: continue
        k, _, v = ln.partition(' ')
        v = v.strip().rstrip('/')
        if not v: continue
        if k == 'KILL' and os.path.isdir(os.path.join(tree, v)): kill.append(v)
        elif k == 'PROTECT': protect.append(v)
    kill.sort(key=len)
    top = []
    for d in kill:                      # 去掉被父目录覆盖的子项
        if not any(d.startswith(t + '/') for t in top): top.append(d)
    return top, protect

def config_path(tree, fallback=None):
    """out-of-tree 构建没有 `<tree>/.config`：$KCONFIG → <tree>/.config → fallback。"""
    cands = [os.path.join(tree, '.config')]
    if fallback: cands.append(fallback)
    return os.environ.get('KCONFIG') or next((p for p in cands if os.path.exists(p)), cands[0])

def enabled(cfg):
    """-> {符号: 'y'|'m'}"""
    en = {}
    for ln in open(cfg, encoding='utf-8', errors='replace'):
        m = re.match(r'CONFIG_(\w+)=([ym])$', ln.strip())
        if m: en[m.group(1)] = m.group(2)
    return en

# ---------------------------------------------------------------- sym2kc 表

def build_sym2kc(tree):
    """扫全树 Kconfig，建「符号 -> 定义它的 Kconfig 路径」。"""
    out = {}
    skip = {'Documentation', '.git', 'scripts'}
    pat = re.compile(r'^\s*(?:menu)?config\s+([A-Za-z0-9_]+)')
    for root, dirs, fs in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in skip]
        for f in fs:
            if f != 'Kconfig' and not f.startswith('Kconfig.'): continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, tree)
            try: txt = open(p, encoding='utf-8', errors='replace').read()
            except OSError: continue
            for ln in txt.splitlines():
                m = pat.match(ln)
                if m: out.setdefault(m.group(1), rel)
    return out

def sym2kc(tree, cache=None):
    """读缓存（默认 $SYM2KC 或 /tmp/sym2kc.tsv），缺失就重建并落盘。"""
    cache = cache or os.environ.get('SYM2KC', '/tmp/sym2kc.tsv')
    if os.path.exists(cache):
        d = {}
        for ln in open(cache, encoding='utf-8'):
            s, _, f = ln.rstrip('\n').partition('\t')
            if s and f: d.setdefault(s, f.lstrip('./'))
        if d: return d
    d = build_sym2kc(tree)
    try:
        with open(cache, 'w', encoding='utf-8') as fh:
            for s, f in d.items(): fh.write('%s\t%s\n' % (s, f))
    except OSError: pass                      # 缓存写不了不影响判定
    return d

# ---------------------------------------------------------------- Makefile 判据

def makefile_syms(tree, d):
    """目录自身 Makefile 引用到的 CONFIG 符号集合。"""
    try: txt = open(os.path.join(tree, d, 'Makefile'), encoding='utf-8', errors='replace').read()
    except OSError: return set()
    return set(re.findall(r'CONFIG_([A-Za-z0-9_]+)', txt))

def parent_gate(tree, d):
    """父 Makefile 怎么收这个目录：('cond', SYM) / ('always', None) / (None, None)。"""
    parent, base = os.path.split(d.rstrip('/'))
    mp = os.path.join(tree, parent, 'Makefile') if parent else os.path.join(tree, 'Makefile')
    try: txt = open(mp, encoding='utf-8', errors='replace').read()
    except OSError: return (None, None)
    txt = txt.replace('\\\n', ' ')            # 续行拉平
    for ln in txt.splitlines():
        if base + '/' not in ln: continue
        m = re.match(r'\s*obj-\$\(CONFIG_([A-Za-z0-9_]+)\)\s*\+?=', ln)
        if m: return ('cond', m.group(1))
        if re.match(r'\s*obj-y\s*\+?=', ln): return ('always', None)
    return (None, None)

# ---------------------------------------------------------------- 汇总判定

def live_counts(top, en, s2k):
    """每个目录按 Kconfig 归属还有多少活符号（弱判据，见模块头）。"""
    live = collections.Counter()
    for s in en:
        f = s2k.get(s)
        if not f: continue
        for d in top:
            if f.startswith(d + '/'): live[d] += 1; break
    return live

def judge(tree, d, en, live, protect=()):
    """返回保留理由字符串；None = 可删。"""
    if d in protect: return 'PROTECT'
    if live[d]: return '%d 个 =y/=m 符号(按 Kconfig 归属)' % live[d]
    hit = sorted(makefile_syms(tree, d) & set(en))
    if hit: return 'Makefile 引用 %s (=y/=m)' % ','.join(hit[:3])
    kind, sym = parent_gate(tree, d)
    if kind == 'cond' and sym in en: return '父 Makefile obj-$(CONFIG_%s) 收它 (=y)' % sym
    if kind == 'cond': return '父 Makefile obj-$(CONFIG_%s)，config 里没有 → 真没人用' % sym
    if kind == 'always': return '父 Makefile 无条件 obj-y 收它'
    return None

def plan(tree, cfg, rules):
    """-> (todo, skip)。skip = [(目录, 保留理由)]。"""
    top, protect = read_rules(rules, tree)
    en = enabled(cfg)
    s2k = sym2kc(tree)
    live = live_counts(top, en, s2k)
    reason = {d: judge(tree, d, en, live, protect) for d in top}
    return [d for d in top if reason[d] is None], [(d, reason[d]) for d in top if reason[d]]

# ---------------------------------------------------------------- 体积统计

def lines_of(tree, d):
    n = 0
    for root, _, fs in os.walk(os.path.join(tree, d)):
        for f in fs:
            if f.endswith(('.c', '.h', '.S', '.Kconfig', '.rs')) or f == 'Makefile':
                try:
                    with open(os.path.join(root, f), 'rb') as fh: n += fh.read().count(b'\n')
                except OSError: pass
    return n

def mb(tree, d):
    out = subprocess.run(['du', '-sm', os.path.join(tree, d)], capture_output=True, text=True)
    return int(out.stdout.split()[0]) if out.stdout else 0

# ---------------------------------------------------------------- 收尾清理

def strip_sources(tree, dirs):
    """删掉指向 `dirs`（已删目录）或已不存在的 `source ".../Kconfig"` 行，返回清理条数。"""
    pat = re.compile(r'^\s*source\s+"([^"]+)/Kconfig"\s*$')
    removed = 0
    for root, _, fs in os.walk(tree):
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
                    if any(ref == d or ref.startswith(d + '/') for d in dirs) or not os.path.exists(
                            os.path.join(root, m.group(1))):
                        ch = True; removed += 1; continue
                out.append(ln)
            if ch: open(p, 'w', encoding='utf-8', errors='surrogateescape').write(''.join(out))
    return removed

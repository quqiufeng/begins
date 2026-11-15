#!/usr/bin/env python3
"""audit_stubs.py — 查「只剩 Kconfig 的空壳目录」里有没有 =y/=m 的活符号。

裁剪的判据是「目录里的符号在 config 里是否 =y/=m」，判错一次就会把
还要编的目录删成空壳，症状迟到大链接期（undefined reference）才爆出来。
这个脚本把判错的地方一次列全：

  python3 audit_stubs.py                 # 只列
  python3 audit_stubs.py --restore       # 从源码包补回整目录（KTAR=<tar.xz>）

用法要点：KTREE=裁剪树，KCFG=config（默认 $KTREE/../kbuild-trim/.config）。
退出码：0 无问题，1 有可疑空壳。
"""
import os, re, sys, tarfile

TREE = os.environ.get('KTREE', '/x96-build/7.2.12-trim')
CFG = os.environ.get('KCFG', '/x96-build/kbuild-trim/.config')
TAR = os.environ.get('KTAR', '/opt/linux/src/linux-7.2.12.tar.xz')
RESTORE = '--restore' in sys.argv

# 顶层符号定义：config FOO / menuconfig FOO，或 select 出来的都由 config 行覆盖
CONF_RE = re.compile(r'^\s*(?:menuconfig|config)\s+([A-Za-z0-9_]+)\s*$', re.M)
# 这些符号名是「能力/开关」性质，几乎每个 arch/驱动都定义一份同名 y，
# 拿它判「这目录要不要」只会刷屏，直接忽略。
NOISE_SYM = re.compile(r'^(64BIT|MMU|SMP|CPU_LITTLE_ENDIAN|GENERIC_.*|ARCH_.*|.*_POSSIBLE|.*_SUPPORTS.*|DUMMY_CONSOLE|FIX_EARLYCON_MEM|LOCKDEP_SUPPORT|KUSER_HELPERS|MMU|SCHED_MC|VIRTUALIZATION)$')


def load_cfg(path):
    live = {}
    for ln in open(path, errors='ignore'):
        m = re.match(r'(CONFIG_[A-Za-z0-9_]+)=(.*)$', ln.strip())
        if m:
            v = m.group(2).strip()
            if v in ('y', 'm'):
                live[m.group(1)[7:]] = v
    return live


def is_stub(d):
    try:
        names = os.listdir(d)
    except OSError:
        return False
    files = [n for n in names if os.path.isfile(os.path.join(d, n))]
    if not files:
        return False
    return all(n == 'Kconfig' or n.startswith('Kconfig.') for n in files)


def audit_stripped(tree, live):
    """prune 把 `obj-$(CONFIG_X) += dir/` 改成了 `obj-$(CONFIG_X) +=`（空 RHS）。
    符号还是 =y/=m 就说明这条代码被悄悄丢了 —— 症状是链接期 undefined reference。"""
    pat = re.compile(r'^[^#\n]*CONFIG_([A-Za-z0-9_]+)\)\s*\+=\s*$')
    bad = []
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d != '.git']
        for f in files:
            if f != 'Makefile' and not f.startswith('Makefile.'):
                continue
            p = os.path.join(root, f)
            for i, ln in enumerate(open(p, errors='ignore'), 1):
                m = pat.match(ln.rstrip('\n'))
                if m and m.group(1) in live:
                    bad.append((os.path.relpath(p, tree), i, m.group(1)))
    return bad


def main():
    live = load_cfg(CFG)
    bad = []
    for root, dirs, files in os.walk(TREE):
        dirs[:] = [d for d in dirs if d not in ('.git', 'Documentation')]
        if not is_stub(root):
            continue
        syms = set()
        for f in files:
            try:
                txt = open(os.path.join(root, f), errors='ignore').read()
            except OSError:
                continue
            syms.update(CONF_RE.findall(txt))
        rel_top = os.path.relpath(root, TREE).split(os.sep)[0]
        # arm64 构建只认 arch/arm64：别的 arch 目录是死代码，报出来没意义
        if rel_top == 'arch' and not os.path.relpath(root, TREE).startswith('arch/arm64'):
            continue
        hit = sorted(s for s in syms if s in live and not NOISE_SYM.match(s))
        if hit:
            bad.append((os.path.relpath(root, TREE), hit, set(live[s] for s in hit)))
    stripped = audit_stripped(TREE, live)
    if stripped:
        print('被剥掉的 Makefile 行但符号还是 =y/=m（会编出缺功能的 Image）：')
        for p, i, sym in stripped:
            print('  %s:%d  CONFIG_%s=%s' % (p, i, sym, live[sym]))
        bad = bad or [('(makefile-line)', [], set())]
    if not bad:
        print('OK 没有活符号住在空壳目录里')
        return 0
    print('可疑空壳 %d 个（里面住着 =y/=m 的符号）：' % len(bad))
    for rel, hit, vals in sorted(bad):
        print('  %-46s %s  %s' % (rel, ''.join(sorted(vals)), ','.join(hit[:4]) + ('…' if len(hit) > 4 else '')))
    if not RESTORE:
        return 1
    print('\n从 %s 补回整目录…' % TAR)
    tf = tarfile.open(TAR)
    for rel, hit, vals in sorted(bad):
        pref = 'linux-7.2.12/' + rel + '/'
        n = 0
        for m in tf.getmembers():
            if m.name.startswith(pref):
                m.name = m.name[len('linux-7.2.12/'):]
                tf.extract(m, TREE)
                n += 1
        print('  补回 %-46s %d 个文件' % (rel, n))
    return 1


if __name__ == '__main__':
    sys.exit(main())

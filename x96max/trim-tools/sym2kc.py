#!/usr/bin/env python3
"""生成 Kconfig 符号表 `sym2kc.tsv`（plan.py / prune_src.py 的前置输入）。

格式：每行 `<SYMBOL>\t<Kconfig 相对路径>`（SYMBOL 不含 CONFIG_ 前缀）。
来源：遍历源码树里所有 Kconfig / Kconfig.*，取 `config X` / `menuconfig X` 定义行。
输出：$SYM2KC（默认 /tmp/sym2kc.tsv）；`/tmp` 会被清，plan.py / prune_src.py 发现缺失会自动重跑本脚本。
"""
import os, re, sys

tree = os.environ.get('KTREE', '/x96-build/src-linux')
out = os.environ.get('SYM2KC', '/tmp/sym2kc.tsv')
pat = re.compile(r'^\s*(?:menu)?config\s+([A-Za-z0-9_]+)\s*$')

n = 0
with open(out, 'w', encoding='utf-8') as f:
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in ('.git', 'Documentation')]
        for fn in files:
            if fn != 'Kconfig' and not fn.startswith('Kconfig.'):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, tree)
            try:
                for ln in open(path, encoding='utf-8', errors='replace'):
                    m = pat.match(ln)
                    if m:
                        f.write('%s\t%s\n' % (m.group(1), rel)); n += 1
            except OSError as e:
                print('skip %s: %s' % (rel, e), file=sys.stderr)
print('%d 条 -> %s (tree=%s)' % (n, out, tree))

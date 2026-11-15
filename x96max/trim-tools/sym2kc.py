#!/usr/bin/env python3
"""生成 /tmp/sym2kc.tsv（符号 -> 定义它的 Kconfig 路径）。判据实现在 tools/trim/trimlib.py。"""
import os, sys
import _trimpath                      # noqa: F401  (sys.path)
import trimlib as T

tree = os.environ.get('KTREE', '/x96-build/src-linux')
cache = os.environ.get('SYM2KC', '/tmp/sym2kc.tsv')
d = T.sym2kc(tree, cache)
print(f"{cache}: {len(d)} 个符号 ← {tree}")

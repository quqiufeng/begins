#!/usr/bin/env python3
"""CRC 对表（零编译版）：Module.symvers vs 契约。

Module.symvers 就是内核的 CRC 全表，直接比对，秒出结果。
裁剪内核时每轮跑一次，521 个内核侧符号必须始终 PASS。

用法: ./check_symvers.py <Module.symvers> <contract> [--self <ko...>]
"""
import sys

def read_symvers(p):
    kv = {}
    for line in open(p):
        f = line.split()
        if len(f) < 2 or not f[0].startswith('0x'): continue
        kv[f[1]] = int(f[0], 16)
    return kv

def main():
    if len(sys.argv) < 3:
        print(__doc__); return 2
    errno = 0
    sym = read_symvers(sys.argv[1])
    con = {}
    for line in open(sys.argv[2]):
        line = line.strip()
        if not line or '=' not in line: continue
        n, c = line.rsplit('=', 1); con[n] = int(c, 0)

    # 模块间符号（nvidia↔nvidia 自导出）不算内核侧契约
    self_ = set()
    if '--self' in sys.argv:
        sys.path.insert(0, __file__.rsplit('/', 1)[0])
        from elf import Elf
        for ko in sys.argv[sys.argv.index('--self') + 1:]:
            e = Elf(ko)
            self_.update(n for n, v, sh in e.syms() if sh != 0)

    ok = bad = miss = 0
    for n, c in sorted(con.items()):
        if n not in sym:
            if self_ and n in self_: continue
            miss += 1; print(f"  - 未导出  {n}")
        elif sym[n] != c:
            bad += 1; print(f"  ✗ CRC不符 {n}: 需要 {c} 实际 {sym[n]}")
        else:
            ok += 1
    print(f"\n=== 匹配 {ok} · CRC不符 {bad} · 未导出 {miss} / 契约 {len(con)} ===")
    print("判定:", "PASS" if bad == miss == 0 else "FAIL")
    return 0 if bad == miss == 0 else 1

if __name__ == '__main__':
    sys.exit(main())

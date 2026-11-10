#!/usr/bin/env python3
"""从 .ko 提取 ABI 契约：symbol -> CRC。

这是整个 ABI 兼容工作的地基。__versions 里的 CRC 是**编译器算出来的类型签名指纹**，
我们的内核必须为每个符号算出同一个 CRC，否则 insmod 直接拒绝。

用法:
  ./manifest.py <ko...>                     打印契约
  ./manifest.py --kv a.kv b.kv <ko...>      和已存在的 CRC 清单比对
  ./manifest.py --c-header <ko>             生成 C 侧自检头
"""
import sys, os, subprocess
from elf import Elf

def load_kv(paths):
    """读 name=crc 或 crc name 两种格式。"""
    kv = {}
    for p in paths:
        for line in open(p):
            line = line.strip()
            if not line or line.startswith('#'): continue
            if '=' in line:
                n, c = line.rsplit('=', 1)
            else:
                parts = line.split()
                if len(parts) < 2: continue
                c, n = parts[0], parts[1]
            try: kv[n.strip()] = int(c, 0)
            except ValueError: pass
    return kv

def contract(kos):
    """symbol -> crc，多模块冲突时记录。"""
    out, src, conflict = {}, {}, {}
    for ko in kos:
        e = Elf(ko)
        und = set(e.undefined())
        for crc, name in e.versions():
            if name not in und and name != 'module_layout':
                continue                      # 只保留真正被引用的
            if name in out and out[name] != crc:
                conflict.setdefault(name, {})[crc] = src[name]
                conflict[name][crc] = src[name]
                continue
            out[name] = crc
            src.setdefault(name, os.path.basename(ko))
    return out, src, conflict

def main():
    argv = sys.argv[1:]
    kv_paths, show_c, kos = [], None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--kv':
            i += 1
            while i < len(argv) and not argv[i].endswith('.ko'):
                kv_paths.append(argv[i]); i += 1
            continue
        if a == '--c-header':
            show_c = True; i += 1; continue
        kos.append(a); i += 1
    if not kos:
        print(__doc__); return 1

    need, src, conflict = contract(kos)

    if show_c:
        basename = os.path.basename(kos[0]).replace('.ko', '').replace('-', '_')
        print(f"/* 自动生成：{basename} 需要的 {len(need)} 个符号 CRC 契约。不要手改。 */")
        print("#ifndef _ABI_CONTRACT_H\n#define _ABI_CONTRACT_H\n")
        print("struct abi_expect { const char *name; unsigned long crc; };")
        print(f"static const struct abi_expect abi_{basename}[] = {{")
        for n, c in sorted(need.items()):
            print(f'    {{ "{n}", {c}UL }},')
        print("};\n#endif")
        return 0

    kv = load_kv(kv_paths) if kv_paths else None
    ok = miss = bad = 0
    for n, c in sorted(need.items()):
        if kv is None:
            print(f"{c:>20}  {n}")
            continue
        if n not in kv:
            miss += 1; print(f"  缺失  {n:'<40} 需要 {c}")
        elif kv[n] != c:
            bad += 1; print(f"  不符  {n:'<40} 需要 {c} 实际 {kv[n]}")
        else:
            ok += 1

    print(f"\n=== 契约 {len(need)} 个符号，来自 {len(kos)} 个模块 ===")
    if kv is not None:
        print(f"比对: 匹配 {ok} · CRC 不符 {bad} · 内核未导出 {miss}")
        print("判定:", "PASS" if bad == miss == 0 else "FAIL")
    if conflict:
        print(f"\n⚠ {len(conflict)} 个符号在不同模块要求不同 CRC:")
        for n, m in conflict.items():
            print(f"   {n}: " + ", ".join(f"{c}({s})" for c, s in m.items()))
    return 0 if kv is None or bad == miss == 0 else 1

if __name__ == '__main__':
    sys.exit(main())

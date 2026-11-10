#!/usr/bin/env python3
"""扫所有 .c，找出引号 #include 在本目录解析不到的头文件（裁剪删目录的典型残留）"""
import os, re, sys
root = sys.argv[1] if len(sys.argv) > 1 else '.'
inc = re.compile(r'^\s*#\s*include\s*"([^"]+)"')
hits = {}
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in ('.git',)]
    for fn in fns:
        if not fn.endswith('.c'):
            continue
        p = os.path.join(dp, fn)
        try:
            with open(p, errors='ignore') as f:
                for i, ln in enumerate(f, 1):
                    m = inc.match(ln)
                    if not m:
                        continue
                    h = m.group(1)
                    if os.path.exists(os.path.join(dp, h)):
                        continue
                    hits.setdefault(h, []).append(f'{p}:{i}')
        except OSError:
            pass
for h in sorted(hits, key=lambda k: -len(hits[k])):
    print(f'{h}\t{len(hits[h])}\t' + ' '.join(hits[h][:4]))
print(f'--- 缺失头文件种类 {len(hits)}，涉及文件 {len({x.split(":")[0] for v in hits.values() for x in v})}', file=sys.stderr)

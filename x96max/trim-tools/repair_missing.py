#!/usr/bin/env python3
"""反复跑 olddefconfig，缺哪个文件就从全量树补回对应目录，直到通过。
用法: repair_missing.py [最多轮数]"""
import os, re, shutil, subprocess, sys

SRC = '/x96-build/src-linux'
ORIG = '/x96-build/orig-src'
BUILD = '/x96-build/kbuild-verify'
ENV = dict(os.environ, ARCH='arm64', CROSS_COMPILE='aarch64-linux-gnu-')
rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 200

for r in range(rounds):
    p = subprocess.run(['make', 'O=' + BUILD, 'olddefconfig'], cwd=SRC, env=ENV,
                       capture_output=True, text=True)
    if p.returncode == 0:
        print('olddefconfig OK (round %d)' % r); break
    out = p.stdout + p.stderr
    # can't open file "drivers/scsi/megaraid/Kconfig.megaraid"
    m = re.findall(r'can.t open file "([^"]+)"', out)
    if not m:
        print(out[-2000:]); sys.exit('无法识别的错误')
    rel = m[0]
    # 补回该文件所在目录（Kconfig 归属目录），从全量树
    d = os.path.dirname(rel)
    while d and not os.path.isdir(os.path.join(ORIG, d)):
        d = os.path.dirname(d)
    if not d:
        print(out[-1000:]); sys.exit('全量树里也没有: %s' % rel)
    dst = os.path.join(SRC, d)
    if os.path.isdir(dst): shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(os.path.join(ORIG, d), dst, symlinks=True)
    print('补回 %s  (%dM)' % (d, int(subprocess.run(['du','-sm',dst],capture_output=True,text=True).stdout.split()[0])))
else:
    sys.exit('超过轮数上限')

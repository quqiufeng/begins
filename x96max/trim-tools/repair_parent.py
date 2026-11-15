#!/usr/bin/env python3
"""补回被删、但父 Makefile 的 obj-$(CONFIG_X) += <dir>/ 在 config 里 =y/=m 的目录。"""
import os, shutil, subprocess
import _trimpath  # noqa
import trimlib as T

SRC='/x96-build/src-linux'; ORIG='/x96-build/orig-src'
cfg=T.config_path(SRC,'/home/quqiufeng/kernel/x96max/kernel/config-7.2.12-x96-full')
en=T.enabled(cfg)
missing=[]
for root,dirs,files in os.walk(ORIG):
    if '/.git' in root: continue
    for d in dirs:
        rel=os.path.relpath(os.path.join(root,d),ORIG)
        if os.path.isdir(os.path.join(SRC,rel)): continue
        kind,sym=T.parent_gate(SRC,rel)
        if kind=='cond' and sym in en: missing.append((rel,sym))
        elif kind=='always': missing.append((rel,'obj-y'))
print('需补回 %d 个:' % len(missing))
tot=0
for rel,why in missing:
    src=os.path.join(ORIG,rel); dst=os.path.join(SRC,rel)
    os.makedirs(os.path.dirname(dst),exist_ok=True)
    if os.path.isdir(dst): shutil.rmtree(dst)
    shutil.copytree(src,dst,symlinks=True)
    tot+=int(subprocess.run(['du','-sm',dst],capture_output=True,text=True).stdout.split()[0])
    print('  %-45s <- %s' % (rel,why))
print('补回体积 %dMB' % tot)

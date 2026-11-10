#!/usr/bin/env python3
"""CRC 对表：生成 stub 模块 → 用目标内核头文件编译 → 读它的 __versions → 和契约比对。

原理：CRC 是类型签名经 genksyms 算出的指纹。我们不去重实现 genksyms，
而是让内核自己算——编一个引用全部目标符号的 stub，读回结果。
stub 的 CRC 与契约一致 = 我们的头文件声明与 Linux 逐字同构。

用法:
  ./verify.py <内核源码树> <契约文件> [工作目录]
  ./verify.py /opt/linux/src/linux-7.2.12 ~/kernel/kpi/abi/nvidia.contract /tmp/abichk
"""
import sys, os, subprocess, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elf import Elf

STUB_TMPL = """/* 自动生成：ABI CRC 自检 stub。只引用符号，不调用。 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>
#include <linux/acpi.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/mutex.h>
#include <linux/ww_mutex.h>
#include <linux/vmalloc.h>
#include <linux/io.h>
#include <linux/kthread.h>
#include <linux/wait.h>
#include <linux/file.h>
{drm_include}
void *volatile __abi_sink;
void __abi_touch(void)
{{
{body}
}}
MODULE_LICENSE("GPL");
"""

MAKEFILE = """obj-m := abistub.o
KDIR := {kdir}
all:
\t$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
\t$(MAKE) -C $(KDIR) M=$(PWD) clean
"""

def load_contract(path):
    kv = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        n, c = line.rsplit('=', 1)
        kv[n] = int(c, 0)
    return kv

def gen_stub(contract, dir_):
    need_drm = any(n.startswith('drm_') for n in contract)
    body = "\n".join(f'    __abi_sink = (void *)&{n};' for n in contract)
    open(os.path.join(dir_, 'abistub.c'), 'w').write(
        STUB_TMPL.format(drm_include='#include <drm/drm_drv.h>' if need_drm else '',
                         body=body))

def main():
    if len(sys.argv) < 3:
        print(__doc__); return 2
    kdir = os.path.abspath(sys.argv[1])
    contract = load_contract(sys.argv[2])
    work = sys.argv[3] if len(sys.argv) > 3 else '/tmp/abichk'
    os.makedirs(work, exist_ok=True)

    for req in ('Makefile', 'include/generated/autoconf.h'):
        if not os.path.exists(os.path.join(kdir, req)):
            print(f"内核树未准备：缺 {req}\n"
                  f"先做：cd {kdir} && cp /boot/config-$(uname -r) .config && make olddefconfig\n"
                  f"      make modules_prepare          # 生成 autoconf.h 等，能编模块即可")
            return 2

    gen_stub(contract, work)
    open(os.path.join(work, 'Makefile'), 'w').write(MAKEFILE.format(kdir=kdir))
    print(f"stub 生成：{len(contract)} 个符号 → {work}/abistub.c")

    r = subprocess.run(['make', '-C', work], capture_output=True, text=True)
    ko = os.path.join(work, 'abistub.ko')
    if not os.path.exists(ko):
        print("编译失败:\n" + (r.stderr or r.stdout)[-3000:]); return 1

    got = dict((n, c) for c, n in Elf(ko).versions())
    ok = bad = miss = 0
    for n, c in sorted(contract.items()):
        if n not in got:
            miss += 1
            print(f"  未生成  {n:<42} 期望 {c}")
        elif got[n] != c:
            bad += 1
            print(f"  ✗ CRC   {n:<42} 期望 {c} 实际 {got[n]}")
        else:
            ok += 1
    print(f"\n=== 匹配 {ok} · CRC 不符 {bad} · 未生成 {miss} / 共 {len(contract)} ===")
    print("判定:", "PASS — 头文件与 Linux 同构" if bad == miss == 0 else "FAIL")
    return 0 if bad == miss == 0 else 1

if __name__ == '__main__':
    sys.exit(main())

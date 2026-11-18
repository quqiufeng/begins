#!/usr/bin/env python3
# 生成 EDID 分辨率池（本目录 *.bin）。纯离线工具，不碰机器。
# 用法: ./mk-pool.py     # 重写 720p/1080p/1440p/2160p 四个 bin 并自校验
#
# 来源：
#   x96-hdmi-1080p.bin   盒子空 HDMI 下自报的 EDID（1080p 已知可用，作为底稿）
#   benq-pd2500q.bin     BenQ PD2500Q 原生 EDID（1440p DTD 直接搬过来）
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from edid_tool import parse, show, mkdtd, fix_cs  # noqa: E402


def load(name):
    with open(os.path.join(HERE, name), 'rb') as f:
        return f.read()


def w(name, data):
    p = os.path.join(HERE, name)
    with open(p, 'wb') as f:
        f.write(data)
    return p


def main():
    base1080 = load('x96-hdmi-1080p.bin')
    benq = load('benq-pd2500q.bin')

    # 1) 1080p60 —— 原样（已知可用）
    w('x96-1080p60.bin', base1080)

    # 2) 720p60 —— 把原文件里的 DTD1(1280x720) 换到 DTD0 位置，纯搬运不改数值
    d = bytearray(base1080)
    dtd0 = bytes(d[54:72])
    dtd1 = bytes(d[72:90])
    d[54:72] = dtd1
    d[72:90] = dtd0
    w('x96-720p60.bin', fix_cs(bytes(d)))

    # 3) 1440p60 —— BenQ 原生 DTD，直接用
    w('x96-1440p60.bin', benq)

    # 4) 2160p30 —— 4K30 落在 HDMI1.4 的 340MHz 内，安全；DTD0 手写，DTD1/2/3 保留原文件的
    d = bytearray(base1080)
    d[54:72] = mkdtd(3840, 2160, 176, 88, 296, 8, 10, 72, 297000000,
                     flags=0x1a, wmm=1440, hmm=810)
    w('x96-2160p30.bin', fix_cs(bytes(d)))

    names = ['x96-720p60.bin', 'x96-1080p60.bin',
             'x96-1440p60.bin', 'x96-2160p30.bin']
    want = {'x96-720p60.bin': (1280, 720, 60),
            'x96-1080p60.bin': (1920, 1080, 60),
            'x96-1440p60.bin': (2560, 1440, 60),
            'x96-2160p30.bin': (3840, 2160, 30)}
    allok = True
    for n in names:
        p, err = parse(load(n))
        if err:
            print("  %-20s FAIL %s" % (n, err))
            allok = False
            continue
        ha, va, hz, _clk = p['dtds'][0]
        wh, hh, hzz = want[n]
        ok = (ha, va) == (wh, hh) and abs(hz - hzz) < 1.5
        print("  %-20s 期望 %dx%d@%d  实际 %dx%d@%.2f  %s"
              % (n, wh, hh, hzz, ha, va, hz, "OK" if ok else "FAIL"))
        allok = allok and ok
    print("总校验:", "PASS" if allok else "FAIL")
    return 0 if allok else 1


if __name__ == '__main__':
    sys.exit(main())

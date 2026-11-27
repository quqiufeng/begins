#!/usr/bin/env python3
"""把 fbwall 用的裸 BGRA 壁纸转成 PNG（sway 的 bg 只吃图片文件）。

用法: bgra2png.py <wallpaper.bgra> <wallpaper.png> [宽] [高]
盒上:
  /opt/desktop/assets/wallpaper.bgra  2560x1440 BGRA 14.7MB（fbwall 直接贴 framebuffer）
  /opt/desktop/assets/wallpaper.png   同图，给 swaybg 当 background

改了壁纸后两边都要重生成，否则桌面（DRM）和微信（sway）背景会不一致。
"""
import sys
from PIL import Image

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 2560
    h = int(sys.argv[4]) if len(sys.argv) > 4 else 1440
    data = open(src, "rb").read()
    need = w * h * 4
    if len(data) < need:
        raise SystemExit("文件太小：%d < %d（%dx%d BGRA）" % (len(data), need, w, h))
    im = Image.frombytes("RGB", (w, h), data[:need], "raw", "BGRX", 0, 1)
    im.save(dst)
    print("%s -> %s  %dx%d" % (src, dst, w, h))
    return 0

if __name__ == "__main__":
    sys.exit(main())

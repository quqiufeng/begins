#!/bin/sh
# 交叉编译 fbwall（aarch64），产物拷到盒子 /opt/desktop/bin/fbwall
# 干什么：util/fbcon.lua 的 M.wall() 调它，把壁纸原始 BGRA 直接写进 /dev/fb0，
# 于是「没人持有 DRM master」的空档里露出的是壁纸，而不是开机 tty1 文本。
set -e
cd "$(dirname "$0")/.."
aarch64-linux-gnu-gcc -O2 -Wall -o /tmp/fbwall-aarch64 tools/fbwall.c
echo "built /tmp/fbwall-aarch64 $(md5sum /tmp/fbwall-aarch64 | cut -d' ' -f1)"
echo "壁纸原始数据（2560x1440 BGRA = 14745600 B）是生成物，不入库："
echo "  ffmpeg -i wallpaper.png -pix_fmt bgra -f rawvideo /opt/desktop/assets/wallpaper.bgra"
echo "部署: scp /tmp/fbwall-aarch64 <box>:/tmp/ && install -m0755 /tmp/fbwall-aarch64 /opt/desktop/bin/fbwall"

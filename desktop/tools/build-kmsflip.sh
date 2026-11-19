#!/bin/sh
# 交叉编译 kmsflip.so（aarch64），产物拷到盒子 /opt/desktop/lib/kmsflip.so
# 头文件走 aarch64 sysroot：libdrm 的 xf86drm.h 会 #include <drm.h>，
# 而 drm.h 只在 /usr/aarch64-linux-gnu/include/drm 下，得显式 -I。
set -e
cd "$(dirname "$0")/.."
aarch64-linux-gnu-gcc -O2 -fPIC -shared -Wall \
	-I/usr/aarch64-linux-gnu/include \
	-I/usr/aarch64-linux-gnu/include/drm \
	-o /tmp/kmsflip.so tools/kmsflip.c -ldl
echo "built /tmp/kmsflip.so $(md5sum /tmp/kmsflip.so | cut -d' ' -f1)"
echo "部署: scp /tmp/kmsflip.so <box>:/tmp/ && install -m0755 /tmp/kmsflip.so /opt/desktop/lib/kmsflip.so"

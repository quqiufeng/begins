#!/bin/sh
# run.sh — 桌面一键上屏（kmsdrm 全屏 2560x1440）
cd /opt/desktop || exit 1
export DESKTOP_HOME=/root
export DESKTOP_FONT_DIR=/opt/reader/assets/fonts
export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-kmsdrm}
# 缩略图纹理上限（张）。256x256 RGBA ≈ 256KB/张，48 张 ≈ 12MB 硬上界
export DESKTOP_THUMB_CACHE=${DESKTOP_THUMB_CACHE:-48}
# glibc 默认每线程一个 arena，线程多就多几份 malloc 堆；小机器收到 2 能压掉
# 相当一部分匿名页，并发度对这种 IO 型程序没有影响
export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}
# 播放结束回原目录：play.sh 起播前把这条片所在目录写进 /run/desktop-start
# （它用 systemctl stop/start 停起桌面，新进程本来只会从首页虚拟根开始，
#  所以播完「退出直接回主页」）。/run 是 tmpfs，重启就清，不会永久粘住目录。
if [ -z "${DESKTOP_START}" ] && [ -r /run/desktop-start ]; then
	DESKTOP_START=$(head -n 1 /run/desktop-start)
	[ -n "$DESKTOP_START" ] && export DESKTOP_START
fi
# 同模式的 drmModeSetCrtc 降级成 PageFlip：一次真 modeset 在 HDMI 上就是一次
# 信号重锁存，电视会弹信号黄条。桌面开/关阅读器一共 4 次，全是同分辨率空转。
# KMSFLIP=fix 生效 / log 只记录不改行为 / 不设则完全旁路
if [ -x /opt/desktop/lib/kmsflip.so ] && [ -n "${KMSFLIP}" ]; then
	export LD_PRELOAD=/opt/desktop/lib/kmsflip.so
	export KMSFLIP_LOG=${KMSFLIP_LOG:-/tmp/kmsflip.log}
fi
export LUAJIT=${LUAJIT:-/opt/reader/bin/luajit}
exec "$LUAJIT" main.lua "$@"

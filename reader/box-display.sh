#!/bin/bash
# 在盒子 HDMI 屏上显示 native-reader（KMSDRM，无需 X）
set -u
BOOK="${1:-/opt/reader/testdata/sample.txt}"
LOG=/tmp/reader-display.log
SOCK=/tmp/native-reader-automation.sock

pkill -f "[n]ative-reader" 2>/dev/null
sleep 1
rm -f "$SOCK"
: > "$LOG"

cd /opt/reader || exit 1
export READER_ROOT=/opt/reader
export SDL_VIDEODRIVER=kmsdrm
export SDL_RENDER_DRIVER=software
export SDL_VIDEO_KMSDRM_REQUIRE_DRM_MASTER=0

setsid ./build/native-reader "$BOOK" </dev/tty1 >>"$LOG" 2>&1 &
disown

for i in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 0.5; done
echo "pid=$(pgrep -f "[n]ative-reader" | head -1)"
echo "sock=$([ -S "$SOCK" ] && echo up || echo down)"
echo "--- log ---"; cat "$LOG"

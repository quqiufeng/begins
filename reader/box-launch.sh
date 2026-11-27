#!/bin/bash
# 在盒子上后台拉起 native-reader，脱离当前会话
set -u
BOOK="${1:-/opt/reader/testdata/sample.txt}"
LOG=/tmp/reader-run.log
SOCK=/tmp/native-reader-automation.sock

pkill -f "[n]ative-reader testdata" 2>/dev/null
pkill -f "[n]ative-reader /opt" 2>/dev/null
sleep 1
rm -f "$SOCK"
: > "$LOG"

cd /opt/reader || exit 1
export READER_ROOT=/opt/reader
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"

setsid ./build/native-reader "$BOOK" </dev/null >>"$LOG" 2>&1 &
disown

for i in $(seq 1 20); do
    [ -S "$SOCK" ] && break
    sleep 0.5
done

echo "pid=$(pgrep -f '[n]ative-reader' | head -1)"
echo "sock=$([ -S "$SOCK" ] && echo up || echo down)"
echo "--- log ---"
cat "$LOG"

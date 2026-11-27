#!/bin/bash
# 盒子 HDMI 屏自动翻页：box-autoturn.sh [次数(0=无限)] [间隔秒]
set -u
N="${1:-0}"; DELAY="${2:-8}"
LOG=/tmp/reader-autoturn.log
pkill -f "[a]utoturn.lua" 2>/dev/null; sleep 0.5
: > "$LOG"
cd /opt/reader || exit 1
export LUA_PATH="/opt/reader/automation/?.lua;/opt/reader/lua/?.lua;;"
export LUA_CPATH="/opt/reader/build/?.so;/usr/lib/aarch64-linux-gnu/lua/5.1/?.so;;"
setsid env N="$N" DELAY="$DELAY" luajit /opt/reader/automation/autoturn.lua >>"$LOG" 2>&1 </dev/null &
disown
sleep 2
echo "pid=$(pgrep -f '[a]utoturn.lua' | head -1) log=$LOG"
cat "$LOG"

#!/bin/sh
# 测 seek 链：key fwd → restart_at → 重开整条 HEVC 链
set -u
echo "== 按前 =="
grep -E '^(OFF|START|PAUSE_AT)=' /tmp/tvplay.state
sh /tmp/tvplay-node.sh key fwd
sleep 8
echo "== 按后 state =="
grep -E '^(OFF|START|PAUSE_AT)=' /tmp/tvplay.state
echo "== 日志 =="
tail -6 /tmp/tvplay.log
echo "== 进程 =="
pgrep -fa 'v4l2hevc-aarch64|ffmpeg .*-f hevc|mpv --no-config' | grep -v pgrep | cut -c1-90

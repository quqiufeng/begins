#!/bin/sh
# 盒端自检：全部匹配串放在文件里，不出现在 ssh 命令行中
# （否则 pkill -f 会把运行本脚本的 ssh 会话自己打停）
set -u
P='v4l2hevc-gl-aarch64'
F='ffmpeg .*-f hevc'

echo "== 恢复被误停的进程 =="
pkill -CONT -f "$P" 2>/dev/null
pkill -CONT -f "$F" 2>/dev/null
sleep 0.3

echo "== 进程状态 =="
for p in $(pgrep -f "$P"); do echo "hevc pid=$p stat=$(ps -o stat= -p $p 2>/dev/null)"; done
for p in $(pgrep -f "$F"); do echo "ffmpeg pid=$p stat=$(ps -o stat= -p $p 2>/dev/null)"; done

echo "== state =="
cat /tmp/tvplay.state 2>/dev/null

echo "== 播放推进（3s 内帧计数变化）=="
a=$(grep -c '' /tmp/tvplay.log 2>/dev/null)
sleep 3
b=$(grep -c '' /tmp/tvplay.log 2>/dev/null)
echo "log 行数 $a -> $b"
tail -4 /tmp/tvplay.log 2>/dev/null

echo "== rc log =="
tail -6 /tmp/tvplay-rc.log 2>/dev/null

#!/bin/sh
# 盒端：把播放切到 tvplay-node.sh 链路（有 state/socket，遥控器才有效），
# 并拉起 rcinputd 守护。用法：rc-up.sh [起始秒]
set -u
F=/root/Sicario.Day.of.the.Soldado.2018.BluRay.2160p.TrueHD.Atmos.7.1.x265.10bit.HDR-ALT.mkv
S=${1:-0}
NODE=/tmp/tvplay-node.sh
enc() { printf '%s' "$1" | base64 -w0; }

# 1) 清掉裸管道链（nowplay.sh 那条，没有 state，遥控器管不了）
pkill -x hevcplay4 2>/dev/null
pkill -x hevcplay3 2>/dev/null
pkill -9 -f 'ffmpeg .*-f hevc' 2>/dev/null
pkill -9 -x mpv 2>/dev/null
sleep 0.3

# 2) 走 node play：建 state + mpv IPC socket + HEVC 硬解链
sh "$NODE" play "$(enc hevc)" "$(enc "$F")" "$(enc "$S")" \
   "$(enc 1)" "$(enc 1)" "$(enc 0)" "$(enc 2560x1440)"
sleep 1

# 3) 遥控器守护（EVIOCGRAB 独占 event0）
pkill -x rcinputd-aarch64 2>/dev/null
setsid nohup /tmp/rcinputd-aarch64 >>/tmp/tvplay-rc.log 2>&1 </dev/null &
sleep 0.5

echo "--- 进程 ---"
pgrep -fa 'v4l2hevc-aarch64|ffmpeg .*-f hevc|mpv|rcinputd' | grep -v pgrep
echo "--- state ---"
cat /tmp/tvplay.state 2>/dev/null
echo "--- rc log ---"
tail -3 /tmp/tvplay-rc.log 2>/dev/null
echo "--- tvplay log ---"
tail -5 /tmp/tvplay.log 2>/dev/null

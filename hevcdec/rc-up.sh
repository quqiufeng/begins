#!/bin/sh
# rc-up.sh — 盒端：一条命令把「播放 + 遥控器」摆好。
#   rc-up.sh [片子] [起播秒]
# 没给片子就用默认那部。走 play.sh（有 state + mpv IPC socket，遥控器才管得了），
# 老链路 /tmp/tvplay-node.sh 已经下线，别再回去。
set -u
DEF=/root/Sicario.Day.of.the.Soldado.2018.BluRay.2160p.TrueHD.Atmos.7.1.x265.10bit.HDR-ALT.mkv
F=${1:-$DEF}
S=${2:-0}
PLAY=/tmp/play.sh

[ -f "$F" ] || { echo "片源不存在：$F"; exit 1; }

# 1) 先把持久副本补进 /tmp 并保证 rcinputd 活着（/tmp 重启即空）
sh /tmp/rcup-start.sh || exit 1

# 2) play.sh 自己会清场（旧 ffmpeg/播放器/mpv 一起收），这里不重复 pkill
sh "$PLAY" -d "$F" "$S"

# 3) 报一下现状
sleep 1
echo "--- 进程 ---"
pgrep -fa 'v4l2hevc-aarch64|ffmpeg .*-f hevc|mpv --no-config|rcinputd' | grep -v pgrep
echo "--- state ---"
cat /tmp/play.state 2>/dev/null | grep -Ev '^SRCB64='
echo "--- rc log ---"
tail -3 /tmp/tvplay-rc.log 2>/dev/null
echo "--- play log ---"
tail -3 /tmp/play.log 2>/dev/null

#!/bin/sh
# 带画面的播放：$1=起始秒 $2=时长秒
F=/root/Sicario.Day.of.the.Soldado.2018.BluRay.2160p.TrueHD.Atmos.7.1.x265.10bit.HDR-ALT.mkv
S=${1:-0}
T=${2:-120}
ffmpeg -v error -ss "$S" -i "$F" -t "$T" -map 0:v:0 -c copy \
	-bsf:v hevc_mp4toannexb -f hevc - 2>/tmp/ff.log \
	| PLAY=1 NOWRITE=1 /tmp/hevcplay3 - 2>&1

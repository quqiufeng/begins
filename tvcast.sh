#!/bin/bash
# 默认播放参数: 23.976fps 内容在 60Hz 屏上用 display-resample+插帧消除 3:2 抖动
# (盒子 EDID 读不到, 无 24Hz 模式; v4l2m2m-copy 在 60Hz 上传会掉帧, 故用零拷贝/软解)
# 播放参数已固化在盒子 /root/.config/mpv/mpv.conf（display-resample + 插帧 + 零拷贝 hwdec）
# MPV_EXTRA 仅用于临时覆盖，例如 MPV_EXTRA="--no-config" 可完全绕开该配置做对照测试
MPV_EXTRA="${MPV_EXTRA:-}"
# tvcast.sh — 4K/HDR 片源"主机转码 + 盒子播放"
#   盒子(X96, panfrost G31) 硬解 4K HEVC10 实际只能 ~12fps（mpv 该构建无 v4l2m2m 零拷贝，
#   只能 -copy，每帧 9MB CPU->GPU 上传），因此 4K HDR 交给主机 RTX3080:
#   cuda 硬解 + zscale tonemap(HDR->SDR) + 缩 1080p + nvenc，TCP 推给盒子直显。
#   实测: 转码 1.56x 实时, 盒子 drop=0, A-V=0.000
# 用法: tvcast.sh <关键词> | -p <dav路径> [起始秒] | -s 停止 | -t 进度 | -d 部署盒子配置
set -uo pipefail
[ -f "$HOME/.env" ] && . "$HOME/.env"
X96="${X96_IP:-192.168.1.121}"
PORT="${CAST_PORT:-5000}"
IDX="$HOME/.cache/tvplay.index"
CAST_HOST="${CAST_HOST:-$(ip route get "$X96" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$X96"

davurl() {
  python3 - "$1" <<'PY'
import os,re,sys,urllib.parse as up
env={}
for line in open(os.path.expanduser('~/.env')):
    m=re.match(r"\s*(\w+)=(.*)",line)
    if m:
        k,v=m.group(1),m.group(2).strip()
        if len(v)>1 and v[0]==v[-1] and v[0] in "\"'": v=v[1:-1]
        env[k]=v
sp=up.urlsplit(env['WEBDAV_URL'])
print("%s://%s:%s@%s:%d%s"%(sp.scheme,env['WEBDAV_USER'],up.quote(env['WEBDAV_PASS'],safe=''),
      sp.hostname,sp.port or 80,up.quote(sys.argv[1])))
PY
}

stop_all() {
  pkill -f "ffmpeg .*tcp://0.0.0.0:$PORT" 2>/dev/null
  $SSH 'pkill -9 mpv 2>/dev/null' 2>/dev/null
}

ensure_box() {
  $SSH 'test -s /root/.config/mpv/mpv.conf && test -s /root/.config/mpv/stats.lua' 2>/dev/null && return 0
  local here; here="$(cd "$(dirname "$0")" && pwd)"
  for f in mpv.conf stats.lua; do
    [ -s "$here/box-$f" ] && scp -q "$here/box-$f" "root@$X96:/root/.config/mpv/$f" 2>/dev/null
  done
  $SSH 'chmod 644 /root/.config/mpv/* 2>/dev/null' 2>/dev/null
}

case "${1:-}" in
  -s) stop_all; echo "已停止"; exit 0;;
  -t) $SSH 'cat /tmp/mpvstat.txt 2>/dev/null' ; exit 0;;
  -d) ensure_box && echo "盒子配置已就绪"; $SSH 'ls -l /root/.config/mpv/' 2>/dev/null; exit 0;;
esac

if [ "${1:-}" = "-p" ]; then
  P="$2"; START="${3:-0}"
else
  kw="${*:-}"
  [ -s "$IDX" ] || { echo "缺索引，先跑: tvplay.sh -i"; exit 1; }
  mapfile -t hits < <(awk -F'|' -v k="$kw" 'k=="" || tolower($2) ~ tolower(k)' "$IDX" | head -20)
  [ ${#hits[@]} -eq 0 ] && { echo "没找到「$kw」"; exit 1; }
  i=0; for h in "${hits[@]}"; do i=$((i+1)); printf '%2d) %s\n' "$i" "$(basename "$(echo "$h" | cut -d'|' -f2-)")"; done
  if [ ${#hits[@]} -eq 1 ]; then sel=1; else read -rp "选第几个(回车=1)? " sel; sel="${sel:-1}"; fi
  P=$(echo "${hits[$((sel-1))]}" | cut -d'|' -f2-); START="${2:-0}"
  case "$START" in ''|*[!0-9.]*) START=0;; esac
fi

echo "▶ 转码: $(basename "$P")"
stop_all >/dev/null 2>&1; ensure_box; sleep 0.2
U=$(davurl "$P")
: > /tmp/tvcast.log
ffmpeg -hide_banner -loglevel warning -re \
  ${START:+$( [ "${START%.*}" -gt 0 ] 2>/dev/null && echo "-ss $START" )} \
  -hwaccel cuda -hwaccel_output_format cuda -i "$U" \
  -map 0:v:0 -map 0:a:1? \
  -vf "hwdownload,format=p010le,scale=1920:-2:flags=bilinear,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
  -c:v h264_nvenc -preset p4 -b:v 8M -maxrate 12M -bufsize 16M -g 48 -bf 2 \
  -c:a aac -b:a 192k -ac 2 \
  -f mpegts "tcp://0.0.0.0:$PORT?listen=1" >> /tmp/tvcast.log 2>&1 &
sleep 1.5
$SSH "pkill -9 mpv 2>/dev/null; sleep 0.5
  setsid nohup /usr/bin/mpv 'tcp://$CAST_HOST:$PORT' \
    --config-dir=/root/.config/mpv ${MPV_EXTRA:-} \
    > /tmp/mpvcast.log 2>&1 < /dev/null &" 9>&-
sleep 3
echo "▶ 盒子 mpv=$($SSH 'pgrep -c mpv' 2>/dev/null)  停: $0 -s   进度: $0 -t"

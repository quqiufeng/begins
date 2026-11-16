#!/bin/bash
# tvplay.sh — 从极空间 NAS(WebDAV) 取片，在 X96 盒子上用 mpv 全屏播放到电视
# 用法:
#   tvplay.sh -i              # 重建索引
#   tvplay.sh -l [关键词]     # 只列表
#   tvplay.sh 关键词...       # 搜索并播放(多个命中会让你选)
#   tvplay.sh -p <完整dav路径> # 直接播放
set -uo pipefail
[ -f ~/.env ] && . ~/.env
BASE="${WEBDAV_URL:?缺 WEBDAV_URL}"; U="${WEBDAV_USER}"; P="${WEBDAV_PASS}"
ROOT="${WEBDAV_MOVIES:-/sata11-18072858035}"
X96="${X96_IP:-192.168.1.121}"
IDX="$HOME/.cache/tvplay.index"
VID='\.(mkv|mp4|m2ts|ts|avi|rmvb|mov|wmv|flv)$'

davlist() { # $1=dir → "size|解码路径" 每行一条(目录 size 为空)
  curl -s -m 40 -u "$U:$P" -X PROPFIND -H 'Depth: 1' \
    -H 'Content-Type: text/xml' \
    --data-binary '<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/></a:prop></a:propfind>' \
    "$BASE$1" 2>/dev/null \
  | python3 -c 'import sys,re,urllib.parse
base=sys.argv[1].rstrip("/")
raw=sys.stdin.read()
for blk in raw.split("<D:response>")[1:]:
    h=re.search(r"<D:href>([^<]+)",blk)
    if not h: continue
    path=urllib.parse.unquote(h.group(1))
    if path.rstrip("/")==base: continue
    sz=re.search(r"<D:getcontentlength>([0-9]+)",blk)
    isdir="<D:collection>" in blk
    print("%s|%s"%(("" if isdir else (sz.group(1) if sz else "0")),path))' "$1"
}

http="http://$U:$P"
build_index() { # BFS 最多 3 层
  : > "$IDX"
  local q=("$ROOT") d=0 entry sz p
  while [ ${#q[@]} -gt 0 ] && [ $d -lt 3 ]; do
    local nq=()
    for cur in "${q[@]}"; do
      while IFS='|' read -r sz p; do
        [ -z "$p" ] && continue
        if [ -z "$sz" ]; then
          [ "$(basename "$p")" = "${p%/}" ] 2>/dev/null
          case "$(basename "$p")" in .*) continue;; esac
          nq+=("$p")
        elif [[ "${p,,}" =~ $VID ]]; then
          printf '%s|%s\n' "$sz" "$p" >> "$IDX"
          printf '  + %6.1fG  %s\n' "$(awk -v s="$sz" 'BEGIN{print s/1073741824}')" "$(basename "$p")" >&2
        fi
      done < <(davlist "$cur")
    done
    q=("${nq[@]}"); d=$((d+1))
    echo "  ...第 $d 层完成, 累计 $(wc -l < "$IDX") 部" >&2
  done
  sort -t'|' -k1,1nr "$IDX" -o "$IDX"
  echo "索引完成: $(wc -l < "$IDX") 部 → $IDX" >&2
}

play() { # $1= dav path
  local enc
  enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")
  echo "▶ 电视播放: $(basename "$1")"
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96" \
    "pkill -9 mpv 2>/dev/null; sleep 0.5; \
     setsid nohup openvt -f -c 3 -s -- /usr/bin/mpv --vo=gpu --gpu-context=drm --hwdec=no \
       --vd-lavc-threads=4 --ao=alsa --audio-device=alsa/hw:0,0 \
       --audio-channels=stereo --no-osc --osd-level=0 --save-position-on-quit \
       '$http$enc' >/tmp/mpv-tv.log 2>&1 < /dev/null & sleep 2" 9>&-
  sleep 1
  st=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96" \
        'pgrep -c mpv || true' 2>/dev/null)
  if [ "${st:-0}" -gt 0 ]; then
    echo "✔ 已在电视上播放(盒子 mpv pid 数=$st)。停止: $0 -s   查进度: $0 -t"
  else
    echo "✘ 启动失败，看日志:"; ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96" 'tail -5 /tmp/mpv-tv.log' 2>/dev/null
  fi
}

case "${1:--l}" in
  -i) build_index; exit 0;;
  -p) shift; play "$1"; exit 0;;
  -s) ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96" 'pkill -9 mpv; chvt 1' 2>/dev/null; echo "已停止"; exit 0;;
  -t) ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$X96" "grep -oE \"time-pos[^,]*\" /tmp/mpv-tv.log | tail -1; pgrep -af mpv | head -2" 2>/dev/null; exit 0;;
esac
[ -s "$IDX" ] || { echo "首次使用，建索引..."; build_index; }
kw="$*"; kw="${kw#-l}"; kw="${kw# }"
mapfile -t hits < <(while IFS='|' read -r sz p; do
    if [ -z "$kw" ] || echo "$(basename "$p")" | grep -qiE "$kw"; then printf '%s|%s\n' "$sz" "$p"; fi
  done < "$IDX")
if [ ${#hits[@]} -eq 0 ]; then echo "没找到匹配「$kw」"; echo "试试: $0 -l | head -40"; exit 1; fi
i=0
for h in "${hits[@]}"; do i=$((i+1)); printf '%2d) %5.1fG  %s\n' "$i" "$(echo "$h" | cut -d'|' -f1 | awk '{print $1/1073741824}')" "$(echo "$h" | cut -d'|' -f2-)"; done
[ "$1" = "-l" ] && exit 0
if [ ${#hits[@]} -eq 1 ]; then sel=1; else read -rp "选第几个(回车=1)? " sel; sel="${sel:-1}"; fi
play "$(echo "${hits[$((sel-1))]}" | cut -d'|' -f2-)"

#!/bin/bash
# x96-shot.sh — 给 X96 盒子截图，落到本机
#
# 盒子现在有两套显示栈（见 X96max.md §22.0），所以有两条抓法：
#   desk（默认）  tty1 桌面：走它自己的自动化 unix socket，调 app.capture 内部抓帧。
#                 /dev/fb0 里没有桌面像素（桌面走 DRM planes），别用 fb 抓桌面。
#   console(-c)   tty2 壁纸终端：读 /dev/fb0（fbterm 走 fbcon），原始 BGRA 拉回来再转 PNG。
#                 只 dd 上屏的 h 行（fb0 virtual_size 是 2560x2160，比屏高，全读会多一大条白边）。
#                 桌面在前台时抓到的只是打底壁纸，终端文字要 chvt 2 之后才有。
#   -a           两个都抓。
#
# 用法:
#   tools/x96-shot.sh                 # 桌面 → ~/x96-desktop-YYYYmmdd-HHMMSS.png
#   tools/x96-shot.sh -c              # 壁纸终端 → ~/x96-console-....png
#   tools/x96-shot.sh -a              # 两个都抓
#   tools/x96-shot.sh -o /tmp/a.png   # 指定输出（多张时自动加后缀）
#   tools/x96-shot.sh -O <盒子路径>   # 只留在盒子上，不 scp 回来
#
# 依赖: 本机 ssh/scp 免密到盒子、ffmpeg；盒子 root ssh（socket 是 root:600）
# 环境: ~/.env 里可用 X96_HOST 覆盖主机名（默认 x96）
set -uo pipefail
[ -f ~/.env ] && . ~/.env
HOST="${X96_HOST:-x96}"
SOCK=/tmp/desktop-automation.sock
SSH="ssh -o BatchMode=yes $HOST"

MODE=desk; OUT=""; REMOTE_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--console) MODE=console ;;
    -a|--all)     MODE=all ;;
    -o)           OUT="$2"; shift ;;
    -O)           REMOTE_ONLY="$2"; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *)            OUT="$1" ;;
  esac
  shift
done

stamp=$(date +%Y%m%d-%H%M%S)

# 桌面：让盒子自己抓帧落盘，再取回来
grab_desk() {
  local base=${1:-screen-$stamp}
  local rp; rp=$(timeout 20 $SSH "printf '%s\n' '{\"cmd\":\"call\",\"fn\":\"app.capture\",\"args\":{\"path\":\"/tmp/$base.png\"}}' \
    | python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(10)
s.connect(\"$SOCK\"); s.sendall((sys.stdin.readline().strip()+\"\n\").encode())
b=b\"\"
while not b.endswith(b\"\n\"):
    d=s.recv(65536)
    if not d: break
    b+=d
print(b.decode(errors=\"replace\").strip())'" 2>&1)
  case "$rp" in
    *'"ok":true'*) echo "desktop ok: $(echo "$rp" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')" ;;
    *) echo "desktop FAIL: $rp" >&2; return 1 ;;
  esac
  return 0
}

# 壁纸终端：dd /dev/fb0 原始 BGRA，拉回来转 PNG
grab_console() {
  local dst="$1"
  # virtual_size 是整块 fb（这台是 2560x2160，比屏高），真正上屏的行数看 modes，
  # 只 dd 可见的 h 行，否则下面会多出一大片空白。
  local geo; geo=$(timeout 20 $SSH 'cat /sys/class/graphics/fb0/modes /sys/class/graphics/fb0/stride /sys/class/graphics/fb0/bits_per_pixel' 2>/dev/null)
  local md st bpp wh w h
  md=$(echo "$geo" | sed -n 1p); st=$(echo "$geo" | sed -n 2p); bpp=$(echo "$geo" | sed -n 3p)
  [ -n "$st" ] || { echo "console FAIL: 读不到 fb0 几何" >&2; return 1; }
  [ "$bpp" = 32 ] || { echo "console FAIL: 只支持 32bpp（现在 $bpp）" >&2; return 1; }
  wh=$(echo "$md" | sed -n 's/^[A-Z]*:\([0-9]*x[0-9]*\)p.*/\1/p')
  [ -n "$wh" ] || wh=$(timeout 20 $SSH 'cat /sys/class/graphics/fb0/virtual_size')
  w=${wh%x*}; h=${wh#*x}
  local raw=/tmp/x96-fb.raw
  timeout 30 $SSH "dd if=/dev/fb0 of=$raw bs=$st count=$h status=none" || { echo "console FAIL: dd" >&2; return 1; }
  timeout 30 scp -q -o BatchMode=yes "$HOST:$raw" "$raw" || { echo "console FAIL: scp" >&2; return 1; }
  ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s ${w}x${h} -i "$raw" "$dst" || {
    echo "console FAIL: ffmpeg" >&2; rm -f "$raw"; return 1; }
  rm -f "$raw"
  echo "console ok: $dst (${w}x${h})"
  return 0
}

rc=0
case "$MODE" in
  desk)
    [ -n "$REMOTE_ONLY" ] && { grab_desk "$(basename "${REMOTE_ONLY%.png}")" || rc=1; exit $rc; }
    dst="${OUT:-$HOME/x96-desktop-$stamp.png}"
    base="$(basename "${dst%.png}")"  # 名字已经带时间戳，别再拼一遍
    grab_desk "$base" || exit 1
    timeout 30 scp -q -o BatchMode=yes "$HOST:/tmp/$base.png" "$dst" && echo "→ $dst" || rc=1
    ;;
  console)
    [ -n "$REMOTE_ONLY" ] && { echo "-O 只对 desk 有效" >&2; exit 1; }
    dst="${OUT:-$HOME/x96-console-$stamp.png}"
    grab_console "$dst" || rc=1
    ;;
  all)
    d1="${OUT:-$HOME/x96-desktop-$stamp.png}"; d2="${OUT:+${OUT%.png}-console.png}"
    d2="${d2:-$HOME/x96-console-$stamp.png}"
    base="x96-desktop-$stamp"
    if grab_desk "$base"; then
      timeout 30 scp -q -o BatchMode=yes "$HOST:/tmp/$base.png" "$d1" && echo "→ $d1" || rc=1
    else rc=1; fi
    grab_console "$d2" || rc=1
    ;;
esac
exit $rc

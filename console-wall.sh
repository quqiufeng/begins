#!/bin/bash
# console-wall: 命令行 + 高清图背景 + 半透明 fbterm（默认 tty2，藏在桌面后面；
# 要 tty1 前台终端就把 console-wall.service 的 TTYPath 改成 /dev/tty1）
# 用法: console-wall.sh [图片路径]
#   1 给路径       -> 用这张
#   2 没给路径     -> 用 /root/backgrounds/.pinned 里写的那张
#   3 都没有       -> 从 /root/backgrounds 随机取
FB=/dev/fb0
BG_DIR=/root/backgrounds
PIN="$BG_DIR/.pinned"
RAW=/run/console-wall.raw

# 分辨率：优先取真实显示模式。virtual_size 会报 2560,2160（虚拟高），
# 按它画会导致图垂直拉伸 1.5 倍且底部被裁掉，所以先读 modes。
MODE=$(head -1 /sys/class/graphics/fb0/modes 2>/dev/null)
if [[ "$MODE" =~ ([0-9]+)x([0-9]+) ]]; then
  W=${BASH_REMATCH[1]}; H=${BASH_REMATCH[2]}
else
  read W H < <(awk '{gsub(","," "); print $1, $2}' /sys/class/graphics/fb0/virtual_size)
  : ${W:=2560}; : ${H:=1440}
fi
[[ -z "$W" || -z "$H" ]] && { W=2560; H=1440; }

IMG="$1"
if [ -z "$IMG" ] && [ -s "$PIN" ]; then
  p=$(head -1 "$PIN"); [ -f "$p" ] && IMG="$p"
fi
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  IMG=$(find "$BG_DIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | shuf -n1)
fi

if [ -n "$IMG" ] && [ -f "$IMG" ]; then
  # 铺满裁切 + 压暗 42% + 轻微模糊（降噪点，让文字压得住）
  ffmpeg -y -loglevel error -i "$IMG" \
    -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},lutrgb=r=val*0.42:g=val*0.42:b=val*0.42,gblur=sigma=2" \
    -pix_fmt bgra -f rawvideo "$RAW" 2>/dev/null
  if [ -s "$RAW" ]; then
    dd if="$RAW" of=$FB bs=$((W*4)) conv=notrunc status=none
  fi
else
  # 没图就铺纯深灰，别留花屏
  head -c $((W*H*4)) /dev/zero | tr '\0' '\30' > "$RAW"
  dd if="$RAW" of=$FB bs=$((W*4)) conv=notrunc status=none
fi

# 字号决定屏幕上的行×列（2560x1440 实测：-s 20 -> 49 行 x 170 列，单格 29x15）
# 想更密就调小：-s 16 -> 62x213；想更大：-s 24 -> 41x142
FONT=${CONSOLE_WALL_FONT:-"Noto Sans Mono CJK SC"}
FSIZE=${CONSOLE_WALL_FONTSIZE:-20}

exec env FBTERM_BACKGROUND_IMAGE=1 TERM=fbterm \
  fbterm -n "$FONT" -s "$FSIZE" -f 0xffe6ffe6 -b 0xb0000000 -- /bin/bash -l

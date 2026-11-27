#!/bin/bash
# cage.sh —— 三站合一：cage 独占 DRM + chromium kiosk 直出（前台 exec，日志进 /tmp/cage.log）
#   用法: cage.sh <yt|wb|gm|raw> [额外 chromium 参数...]
#     yt  = YouTube  profile /root/.config/chromium     走代理 127.0.0.1:7890
#     wb  = 微博     profile /root/.config/chromium-wb  国内直连，不走代理
#     gm  = Gmail    profile /root/.config/chromium-gm  走代理 127.0.0.1:7890
#     raw = about:blank，默认 profile（调参/排错起手）
#   前置: desktop 会抢 DRM master，脚本先 mask --runtime 再 stop（收尾见 README「还原桌面」）
set -u
SITE="${1:-raw}"; shift 2>/dev/null || true
PROXY="http://127.0.0.1:7890"
case "$SITE" in
  yt)  UD=/root/.config/chromium;    EXTRA=(--proxy-server=$PROXY) ;;
  wb)  UD=/root/.config/chromium-wb; EXTRA=() ;;
  gm)  UD=/root/.config/chromium-gm; EXTRA=(--proxy-server=$PROXY) ;;
  raw) UD=/root/.config/chromium;    EXTRA=() ;;
  *)   echo "用法: cage.sh <yt|wb|gm|raw> [额外参数]"; exit 2 ;;
esac

systemctl mask --runtime desktop >/dev/null 2>&1
systemctl stop desktop 2>/dev/null
sleep 1.5
pkill -x cage 2>/dev/null; pkill -x chromium 2>/dev/null; sleep 0.5

export XDG_RUNTIME_DIR=/run/user/0
export LIBSEAT_BACKEND=seatd
cd /root || exit 1
exec dbus-run-session -- cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 --remote-allow-origins='*' \
  "${EXTRA[@]}" \
  --user-data-dir="$UD" \
  --lang=zh-CN \
  "$@" \
  about:blank > /tmp/cage.log 2>&1

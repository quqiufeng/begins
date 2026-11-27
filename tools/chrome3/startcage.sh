#!/bin/bash
# startcage.sh —— 同 cage.sh，但后台起 + 等 CDP ready + 启动前修字号 + 多核调优参数
#   用法: startcage.sh <yt|wb|zh|gm|dy|jb|raw>   （参数含义见 cage.sh）
#   为什么单独一份：字号修正必须在 chromium 停掉之后、起来之前做（运行中改会被它退出时覆写）；
#   光栅调优是常驻参数，只有这条后台路线会等 CDP，前台 exec 版等不了。
set -u
SITE="${1:-raw}"
LITE_FONT_SIZE="${LITE_FONT_SIZE:-14}"     # 默认字号 14px，见 chrome.md §14
PROXY="http://127.0.0.1:7890"
case "$SITE" in
  yt)  UD=/root/.config/chromium;    EXTRA=(--proxy-server=$PROXY) ;;
  wb)  UD=/root/.config/chromium-wb; EXTRA=() ;;
  zh)  UD=/root/.config/chromium-zh; EXTRA=() ;;
  gm)  UD=/root/.config/chromium-gm; EXTRA=(--proxy-server=$PROXY) ;;
  jb)  UD=/root/.config/chromium-jb; EXTRA=(--proxy-server=$PROXY) ;;
  dy)  UD=/root/.config/chromium-dy; EXTRA=() ;;
  raw) UD=/root/.config/chromium;    EXTRA=() ;;
  *)   echo "用法: startcage.sh <yt|wb|zh|gm|dy|jb|raw>"; exit 2 ;;
esac

systemctl mask --runtime desktop >/dev/null 2>&1
systemctl stop desktop 2>/dev/null
sleep 1.5
pkill -x cage 2>/dev/null; pkill -x chromium 2>/dev/null; sleep 0.5

# 默认字号：chromium 没有命令行开关，只认 Preferences 的 webkit.webprefs（幂等，改完再起）
python3 - "$LITE_FONT_SIZE" "$UD/Default/Preferences" <<'PY' 2>/dev/null
import json, os, sys
p = sys.argv[2]
size = int(sys.argv[1])
try:
    d = json.load(open(p))
except Exception:
    d = {}
w = d.setdefault("webkit", {}).setdefault("webprefs", {})
changed = []
if w.get("default_font_size") != size:
    w["default_font_size"] = size
    changed.append("font-size -> %dpx" % size)
# 关掉"是否保存登录信息？"气泡：kiosk 遥控没有键鼠，那个气泡会盖在页面上挡点击
if d.get("credentials_enable_service") is not False:
    d["credentials_enable_service"] = False
    changed.append("credentials_enable_service -> false")
prof = d.setdefault("profile", {})
if prof.get("password_manager_enabled") is not False:
    prof["password_manager_enabled"] = False
    changed.append("password_manager_enabled -> false")
if changed:
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(d, open(p, "w"))
    print("; ".join(changed))
PY

export XDG_RUNTIME_DIR=/run/user/0
export LIBSEAT_BACKEND=seatd
cd /root || exit 1
setsid dbus-run-session -- cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' \
  --num-raster-threads=3 --disable-accelerated-2d-canvas \
  "${EXTRA[@]}" \
  --user-data-dir="$UD" --lang=zh-CN \
  about:blank > /tmp/cage.log 2>&1 &

for i in $(seq 1 40); do
  if curl -s --max-time 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
    echo "CDP ready after ${i}x0.5s"; curl -s http://127.0.0.1:9222/json/version; exit 0
  fi
  sleep 0.5
done
echo "TIMEOUT"; tail -20 /tmp/cage.log; exit 1

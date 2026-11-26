#!/bin/bash
# 浏览器直出：cage 独占 DRM + chromium kiosk  -- 多核调优参数见 chrome.md
#   --num-raster-threads=3      光栅线程 3（4 核里留一核给 GPU 进程/合成）
#   --disable-accelerated-2d-canvas  canvas 2D 走 CPU 软光栅（Panfrost 弱，软光栅多核更快：1.5→3.6fps）
# 默认字号 14px：chromium 没有命令行开关，只认 Preferences 的 webkit.webprefs；
#   而它退出时会覆写该文件，所以每次启动前修一次（幂等），改完再起。
FONTSIZE="${LITE_FONT_SIZE:-14}"
systemctl mask --runtime desktop >/dev/null 2>&1
systemctl stop desktop 2>/dev/null
sleep 1.5
pkill -x cage 2>/dev/null; pkill -x chromium 2>/dev/null; sleep 0.5
python3 - "$FONTSIZE" <<'PY' 2>/dev/null
import json, os, sys
p = "/root/.config/chromium/Default/Preferences"
size = int(sys.argv[1])
try:
    d = json.load(open(p))
except Exception:
    d = {}
w = d.setdefault("webkit", {}).setdefault("webprefs", {})
if w.get("default_font_size") != size:
    w["default_font_size"] = size
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(d, open(p, "w"))
    print("font-size -> %dpx" % size)
PY
cd /root
setsid dbus-run-session cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' \
  --num-raster-threads=3 --disable-accelerated-2d-canvas \
  about:blank > /tmp/cage.log 2>&1 &
for i in $(seq 1 40); do
  if curl -s --max-time 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
    echo "CDP ready after ${i}x0.5s"; curl -s http://127.0.0.1:9222/json/version; exit 0
  fi
  sleep 0.5
done
echo "TIMEOUT"; tail -20 /tmp/cage.log; exit 1

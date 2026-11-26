#!/bin/bash
# 用法: EXTRA="--num-raster-threads=4" sc2.sh
systemctl mask --runtime desktop >/dev/null 2>&1
systemctl stop desktop 2>/dev/null
sleep 1.5
pkill -x cage 2>/dev/null; pkill -x chromium 2>/dev/null; sleep 1
cd /root
setsid dbus-run-session cage -- chromium \
  --kiosk --no-sandbox --disable-dev-shm-usage \
  --ozone-platform=wayland --remote-debugging-port=9222 \
  --remote-allow-origins='*' $EXTRA file:///tmp/${PAGE:-bench.html} > /tmp/cage.log 2>&1 &
for i in $(seq 1 40); do
  curl -s --max-time 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break
  sleep 0.5
done
echo "EXTRA=[$EXTRA]  CDP ready"
sleep 6   # 让页面画起来

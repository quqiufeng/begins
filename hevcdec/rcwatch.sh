#!/bin/sh
# 验 mpvctl（音量/静音）+ 抓 25s 真实按键
set -u
CTL=/tmp/mpvctl-aarch64
SOCK=/tmp/tvplay.sock

echo "== mpvctl 读音量 =="
MPVCTL_ECHO=1 "$CTL" "$SOCK" '{"command":["get_property","volume"]}' 2>&1

echo "== 走 node key volup（应 +10）=="
sh /tmp/tvplay-node.sh key volup
MPVCTL_ECHO=1 "$CTL" "$SOCK" '{"command":["get_property","volume"]}' 2>&1

echo "== 还原 voldn =="
sh /tmp/tvplay-node.sh key voldn
MPVCTL_ECHO=1 "$CTL" "$SOCK" '{"command":["get_property","volume"]}' 2>&1

echo "== 记下日志行数，等 25s 抓按键 =="
a=$(grep -c '' /tmp/tvplay-rc.log 2>/dev/null)
sleep 25
echo "-- 期��内新增按键事件 --"
tail -n +$((a+1)) /tmp/tvplay-rc.log 2>/dev/null | grep -v "not found"

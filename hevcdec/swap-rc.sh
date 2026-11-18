#!/bin/sh
# 换装修好的 rcinputd：必须先停播放链，才能释放被继承 fd 卡住的 EVIOCGRAB。
# 中途记下当前播放位置，换完接着放。
set -u
NODE=/tmp/tvplay-node.sh
RCPAT='rcinputd-aarch'
. /tmp/tvplay.state 2>/dev/null || { echo "没有 state，放弃"; exit 1; }

NOW=$(date +%s)
if [ "${PAUSE_AT:-0}" -gt 0 ]; then POS=$(( PAUSE_AT - START + OFF )); else POS=$(( NOW - START + OFF )); fi
echo "当前播放位置 ${POS}s"

echo "== 停播放链（释放继承的设备 fd）=="
sh "$NODE" stop
sleep 1

echo "== 停旧守护 =="
pkill -f "$RCPAT" 2>/dev/null; sleep 0.5
pkill -9 -f "$RCPAT" 2>/dev/null; sleep 0.3

echo "== 还有谁攥着 event 设备 =="
for f in /dev/input/event0 /dev/input/event1 /dev/input/event2; do
	echo "-- $f"; fuser "$f" 2>&1 | tr ' ' '\n' | grep -E '^[0-9]+$' | while read -r pid; do
		[ -n "$pid" ] && echo "   pid=$pid $(tr -d '\0' < /proc/$pid/comm 2>/dev/null)"
	done
done

echo "== 换装 =="
[ -f /tmp/rcinputd.new ] && mv -f /tmp/rcinputd.new /tmp/rcinputd-aarch64
chmod +x /tmp/rcinputd-aarch64
: > /tmp/tvplay-rc.log
setsid nohup /tmp/rcinputd-aarch64 >>/tmp/tvplay-rc.log 2>&1 </dev/null &
sleep 1
echo "== 启动日志（应无 WARN grab）=="
cat /tmp/tvplay-rc.log

echo "== 重新起播 @${POS}s =="
enc() { printf '%s' "$1" | base64 -w0; }
sh "$NODE" play "$(enc "${PLAYER:-hevc}")" "$KEYB64" "$(enc "$POS")" \
   "$(enc "${TRACK:-1}")" "$(enc "${AUDIO:-1}")" "$(enc "${FPS:-0}")" "$(enc "${GEO:-$(sh "$NODE" disp 2>/dev/null | cut -d@ -f1)}")"
sleep 8

echo "== 换装后谁攥着 event0（只应有 rcinputd）=="
fuser -v /dev/input/event0 2>&1 | tail -3
echo "== 播放 =="
tail -2 /tmp/tvplay.log

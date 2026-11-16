#!/bin/sh
# /root/rcup 持久副本 → /tmp（/tmp 重启即空，这就是遥控器失灵的根因）
# 只补文件 + 拉起 rcinputd，不动正在播的东西。
set -u
SRC=/root/rcup
for f in rcinputd-aarch64 tvplay-node.sh v4l2hevc-gl-aarch64; do
	[ -f "$SRC/$f" ] || continue
	if ! cmp -s "$SRC/$f" "/tmp/$f" 2>/dev/null; then
		cp -f "$SRC/$f" "/tmp/$f"
		echo "deploy /tmp/$f"
	fi
	chmod +x "/tmp/$f"
done

if ! pgrep -x rcinputd-aarch64 >/dev/null 2>&1; then
	setsid nohup /tmp/rcinputd-aarch64 >>/tmp/tvplay-rc.log 2>&1 </dev/null &
	echo "rcinputd started"
else
	echo "rcinputd already running"
fi

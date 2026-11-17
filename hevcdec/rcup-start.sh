#!/bin/sh
# rcup-start.sh — 盒端：把 /root/rcup 的持久副本补进 /tmp，并拉起遥控器守护。
#
#   sh /tmp/rcup-start.sh        # 缺文件才补，rcinputd 不在才拉（开机用）
#   sh /tmp/rcup-start.sh -r     # 强制重启 rcinputd（换了新二进制后）
#
# 为什么要有它：/tmp 重启即空，二进制和 play.sh 一没，遥控器就"失灵"。
#
# 注意 comm 只有 15 字节：/proc/<pid>/comm 是 "rcinputd-aarch6"，
# pkill -x rcinputd-aarch64 永远匹配不上，旧实例会一直握着 EVIOCGRAB。
set -u
SRC=/root/rcup
FORCE=0
[ "${1:-}" = "-r" ] && FORCE=1

# 只还原部署清单里的东西（deploy.sh 的 BINS/SCRIPTS）。aout/aoutctl 未接链路，
# 不在这里列 —— 列了就会把盒上早就删掉的死文件又「补」回来。
for f in rcinputd-aarch64 v4l2hevc-aarch64 \
         play.sh rcup-start.sh; do
	[ -f "$SRC/$f" ] || continue
	if [ "$FORCE" = 1 ] || ! cmp -s "$SRC/$f" "/tmp/$f" 2>/dev/null; then
		cp -f "$SRC/$f" "/tmp/$f"
		echo "deploy /tmp/$f"
	fi
	chmod +x "/tmp/$f"
done

RUNNING=0
pgrep -x rcinputd-aarch6 >/dev/null 2>&1 && RUNNING=1

if [ "$FORCE" = 1 ] && [ "$RUNNING" = 1 ]; then
	pkill -x rcinputd-aarch6 2>/dev/null
	sleep 0.3
	RUNNING=0
fi

if [ "$RUNNING" = 0 ]; then
	setsid nohup /tmp/rcinputd-aarch64 >>/tmp/tvplay-rc.log 2>&1 </dev/null &
	sleep 0.5
	if pgrep -x rcinputd-aarch6 >/dev/null 2>&1; then
		echo "rcinputd started（按键 → /tmp/play.sh key <动作>）"
	else
		echo "rcinputd FAILED，看 /tmp/tvplay-rc.log"
		exit 1
	fi
else
	echo "rcinputd already running"
fi

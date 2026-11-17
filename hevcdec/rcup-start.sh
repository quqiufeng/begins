#!/bin/sh
# rcup-start.sh — 盒端：从 /root 拉起遥控器守护（x96-rc.service 开机调用）。
#
#   sh /root/rcup-start.sh        # rcinputd 不在才拉（开机用）
#   sh /root/rcup-start.sh -r     # 强制重启（换了新二进制后）
#
# 老版本要先把 /root/rcup 的副本补进 /tmp，因为二进制和 play.sh 都放 /tmp，
# 而 /tmp 是 tmpfs、重启即空 —— 这就是「遥控器第二天失灵」的根因。
# 现在二进制和 play.sh 都直接躺在 /root（见 deploy.sh），重启还在，不用再补。
# 老的 /root/rcup 若还在，就地清掉，免得两份不同步。
#
# 注意 comm 只有 15 字节：/proc/<pid>/comm 是 "rcinputd-aarch6"，
# pkill -x rcinputd-aarch64 永远匹配不上，旧实例会一直握着 EVIOCGRAB。
set -u
HOME_DIR=/root
BIN=$HOME_DIR/rcinputd-aarch64
NODE=$HOME_DIR/play.sh
FORCE=0
[ "${1:-}" = "-r" ] && FORCE=1

[ -x "$BIN" ] || { echo "缺 $BIN（先跑 deploy.sh）"; exit 1; }
chmod +x "$BIN" 2>/dev/null
[ -f "$NODE" ] && chmod +x "$NODE" 2>/dev/null

# 老布局的持久副本：留着只会和 /root 的新文件打架（rcinputd 里写死的还是旧的）
[ -d "$HOME_DIR/rcup" ] && rm -rf "$HOME_DIR/rcup"

RUNNING=0
pgrep -x rcinputd-aarch6 >/dev/null 2>&1 && RUNNING=1

if [ "$FORCE" = 1 ] && [ "$RUNNING" = 1 ]; then
	pkill -x rcinputd-aarch6 2>/dev/null
	sleep 0.3
	RUNNING=0
fi

if [ "$RUNNING" = 0 ]; then
	setsid nohup "$BIN" >>/tmp/tvplay-rc.log 2>&1 </dev/null &
	sleep 0.5
	if pgrep -x rcinputd-aarch6 >/dev/null 2>&1; then
		echo "rcinputd started（按键 → $NODE key <动作>）"
	else
		echo "rcinputd FAILED，看 /tmp/tvplay-rc.log"
		exit 1
	fi
else
	echo "rcinputd already running"
fi

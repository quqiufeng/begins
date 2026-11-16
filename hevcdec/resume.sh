#!/bin/sh
# 清掉半途而废的暂停状态：state 里 PAUSE_AT>0 但进程实际在跑，
# 走 node key toggle 让它按「暂停中→继续」正确修 START。
set -u
S=/tmp/tvplay.state
. "$S" 2>/dev/null || exit 1
if [ "${PAUSE_AT:-0}" -gt 0 ]; then
	echo "state 认为在暂停（PAUSE_AT=$PAUSE_AT），发 resume"
	sh /tmp/tvplay-node.sh key toggle
fi
sleep 6
echo "== state =="
grep -E '^(START|OFF|PAUSE_AT)=' "$S"
echo "== 8s 内是否推进 =="
for i in 1 2 3; do
	tail -1 /tmp/tvplay.log
	sleep 2
done

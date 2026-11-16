#!/bin/sh
# waitsoak.sh SECONDS —— 观察 x96 播放器是否还在出帧，最多等 SECONDS 秒
# 判据：/tmp/tvplay.log 的 mtime（HB 每 10s 一行，持续刷新）；
#       mtime 超过 25s 没更新 = 停帧 → 立刻退出并打 FROZEN（抓取器也同时会抓现场）
T=${1:-100}
LOG=/tmp/tvplay.log
end=$(( $(date +%s) + T ))
frozen=0
while [ "$(date +%s)" -lt "$end" ]; do
	mt=$(stat -c %Y $LOG 2>/dev/null || echo 0)
	idle=$(( $(date +%s) - mt ))
	if [ "$idle" -gt 25 ]; then frozen=1; break; fi
	sleep 5
done
date +%T
grep -aoE "HB t=[0-9]+ au=[0-9]+ got=[0-9]+ out_nfree=[0-9/]+ quiet=[0-9.]+ rec=[0-9]+" $LOG | tail -1
echo "log_idle=${idle}s"
[ $frozen = 1 ] && echo "FROZEN" || echo "OK"

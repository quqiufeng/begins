#!/bin/sh
# abort-loop.sh —— 重放「2560x1440 + 反复 abort」场景，配合 cma-watch 常驻抓泄漏
#
# 用法: abort-loop.sh [轮数] [每轮播放秒数]
#   VID=/root/4k24.mkv GEO=2560x1440 abort-loop.sh 9 4
#
# 每轮：起播 → 播 N 秒 → tvplay-node.sh stop（pkill -9 整条链）→ 记录 CMA 两路读数
#   CmaFree_kB : /proc/meminfo，kB 粒度，全局
#   used_pages : /sys/kernel/debug/cma/reserved/used，页粒度，只算 reserved 区（CMA_DEBUGFS）
# 两个读数都写，互相验证：只看 CmaFree 会被 kB 取整和别的分配者干扰。
set -u
N=${1:-9}
SECS=${2:-4}
E=/tmp/tvplay-node.sh
VID=${VID:-/root/4k24.mkv}
GEO=${GEO:-2560x1440}

enc() { printf '%s' "$1" | base64 -w0; }
free_kb() { awk '/^CmaFree:/{print $2}' /proc/meminfo; }
used_pg() { cat /sys/kernel/debug/cma/reserved/used 2>/dev/null || echo -1; }

[ -x "$E" ] || { echo "缺 $E"; exit 1; }

printf '# 轮次 CmaFree_kB used_pages\n'
printf '%-8s %s %s\n' "base" "$(free_kb)" "$(used_pg)"
for i in $(seq 1 "$N"); do
	sh "$E" play "$(enc hevc)" "$(enc "$VID")" "$(enc 0)" \
		"$(enc 1)" "$(enc 0)" "$(enc 0)" "$(enc "$GEO")" >/dev/null 2>&1
	sleep "$SECS"
	sh "$E" stop >/dev/null 2>&1
	sleep 1
	printf '%-8s %s %s\n' "abort$i" "$(free_kb)" "$(used_pg)"
done
echo "# 结束：进程 $(pgrep -c -f 'v4l2hevc-aarch64' 2>/dev/null) 个解码器残留"

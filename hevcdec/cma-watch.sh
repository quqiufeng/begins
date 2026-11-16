#!/bin/sh
# cma-watch.sh —— CMA 保留区泄漏探测器（零重编内核）
#
# 原理：内核自带 cma_alloc_finish / cma_release tracepoint 已经记录了
#   每一次 CMA 分配的 name/pfn/count/pid。本脚本只做两件事：
#     1) trace_pipe 流式落盘（不用环形缓冲，不丢事件）
#     2) 按 pfn 记账：alloc 加、release 减；跑完后 pfn 仍有余额的
#        就是"分配了没释放"的块，且能直接报出分配它的 pid。
#   这比在内核里加 dev_info 埋点更准，也不用重编。
#
# 用法:
#   cma-watch.sh start     开始常驻采样（raw.log + samples.log）
#   cma-watch.sh stop      停止采样
#   cma-watch.sh report    配对分析：报泄漏块 + pid 归属
#   cma-watch.sh status    采样进程是否在跑
#   cma-watch.sh tail [n]  看最近 n 行采样
set -u
T=${CMAT:-/sys/kernel/tracing}
D=${CMAD:-/root/cmawatch}
RAW=$D/raw.log
SAMP=$D/samples.log

mkdir -p "$D"

# ── 采样器：每秒一行，增量统计（不重复扫描整个文件）──
do_sample() {
	printf '# t_ms CmaFreeKB CmaTotalKB alloc release live dmabuf_objs decoders\n' > "$SAMP"
	a=0; r=0; off=0
	while :; do
		ts=$(date +%s%3N)
		# 偏移必须按「实际读到的字节数」推进：用 stat 的大小当偏移会重复计数
		# （tail -c +N 读到的可能比 stat 拿到的 sz 更远，下轮从 sz 重读重叠段）
		c=$(tail -c +$((off + 1)) "$RAW" 2>/dev/null)
		if [ -n "$c" ]; then
			set -- $(printf '%s\n' "$c" |
				awk '/cma_alloc_finish/{a++} /cma_release/{r++} END{print a+0, r+0}')
			a=$((a + ${1:-0})); r=$((r + ${2:-0}))
			off=$((off + ${#c}))
		fi
		f=$(awk '/^CmaFree:/{print $2}' /proc/meminfo)
		t=$(awk '/^CmaTotal:/{print $2}' /proc/meminfo)
		b=$(awk '/^Total/{print $2}' /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null)
		# 注意: pgrep -c 无匹配时仍打印 0 但退出码为 1，不能写 "|| echo 0"
		# （会把输出拼成两行，坏掉整个采样文件的列对齐）
		p=$(pgrep -c -f 'v4l2hevc-gl-aarch64|ffmpeg -hide_banner' 2>/dev/null) || p=0
		echo "$ts ${f:-0} ${t:-0} $a $r $((a - r)) ${b:-0} ${p:-0}" >> "$SAMP"
		sleep 1
	done
}

do_start() {
	do_stop >/dev/null 2>&1
	: > "$RAW"; : > "$SAMP"
	echo 0 > "$T/tracing_on" 2>/dev/null
	echo > "$T/trace" 2>/dev/null
	if [ ! -d "$T/events/cma" ]; then
		echo "错误: 内核无 cma tracepoint ($T/events/cma)"; exit 1
	fi
	echo 1 > "$T/events/cma/enable"
	echo 1 > "$T/tracing_on"
	setsid cat "$T/trace_pipe" >> "$RAW" 2>/dev/null &
	echo $! > "$D/reader.pid"
	setsid sh "$0" __sample >> "$D/sampler.err" 2>&1 &
	echo $! > "$D/sampler.pid"
	echo "已启动  raw=$RAW  samples=$SAMP"
}

do_stop() {
	# 先关 tracing 再等 reader 把 ring buffer 吐空，最后才杀，避免末行截断
	echo 0 > "$T/tracing_on" 2>/dev/null
	sleep 0.3
	for f in reader sampler; do
		[ -f "$D/$f.pid" ] && { kill "$(cat "$D/$f.pid")" 2>/dev/null; rm -f "$D/$f.pid"; }
	done
	echo 0 > "$T/tracing_on" 2>/dev/null
	echo 0 > "$T/events/cma/enable" 2>/dev/null
}

# ── 配对分析 ──
do_report() {
	[ -s "$RAW" ] || { echo "raw.log 为空，先 start 再跑复现"; return 1; }
	awk '
	{
		# $1 = comm-pid（comm 本身可能含 "-"，pid 取最后一段）
		n = split($1, sp, "-"); pid = sp[n]
		comm = $1; sub(/-[0-9]+$/, "", comm)
		if ($0 ~ /cma_alloc_finish/) {
			match($0, /pfn=0x[0-9a-f]+/); if (!RSTART) next
			p = substr($0, RSTART+4, RLENGTH-4)
			match($0, /count=[0-9]+/); if (!RSTART) next
			c = substr($0, RSTART+6, RLENGTH-6) + 0
			if (!(p in rem)) { rem[p] = 0; own[p] = pid; ownc[p] = comm; base[p] = p }
			rem[p] += c
			if (rem[p] == c) { own[p] = pid; ownc[p] = comm }   # 该 pfn 新块归新 pid
			A += c; NA++
		} else if ($0 ~ /cma_release/) {
			match($0, /pfn=0x[0-9a-f]+/); if (!RSTART) next
			p = substr($0, RSTART+4, RLENGTH-4)
			match($0, /count=[0-9]+/); if (!RSTART) next
			c = substr($0, RSTART+6, RLENGTH-6) + 0
			rem[p] -= c
			R += c; NR2++
		} else if ($0 ~ /pfn=0x/) {
			BAD++
		}
	}
	END {
		printf "===== CMA 总账 =====\n"
		printf "  alloc 调用 %d 次, %d 页 (%.1f MB)\n", NA, A, A*4/1024
		printf "  release 调用 %d 次, %d 页 (%.1f MB)\n", NR2, R, R*4/1024
		printf "  未释放: %d 页 (%.1f MB)\n", A-R, (A-R)*4/1024
		# 截断/异常行必须报出来，否则会被当成「配平」误判为无泄漏
		if (BAD) printf "  [警告] %d 行含 pfn 但解析不出 count（可能被截断，数字偏小）\n", BAD
		if (NR - NA - NR2 - BAD > 0) printf "  [信息] %d 行为 cma_alloc_start 等非记账事件\n", NR-NA-NR2-BAD
		printf "\n"
		# 泄漏块
		ln = 0
		for (p in rem) if (rem[p] > 0) { ln++; L[ln] = p }
		if (ln == 0) { printf "  无未配平块 —— 本次运行 CMA 全部分配都有对应释放\n"; exit }
		printf "===== 未放出块 (top 20, 按页数) =====\n"
		# 简单插入排序取前 20
		for (i = 2; i <= ln; i++) { k = L[i]; j = i-1
			while (j > 0 && rem[L[j]] < rem[k]) { L[j+1] = L[j]; j-- }
			L[j+1] = k }
		for (i = 1; i <= ln && i <= 20; i++) {
			p = L[i]
			printf "  pfn=%-10s %5d 页 (%6.1f MB)  pid=%-6s comm=%s\n", \
				p, rem[p], rem[p]*4/1024, own[p], ownc[p]
			PS[own[p]] += rem[p]; PC[own[p]] = ownc[p]
		}
		printf "\n===== 按 pid 汇总（泄漏页数）=====\n"
		for (p in PS) printf "  pid=%-6s %-20s %5d 页 (%.1f MB)\n", p, PC[p], PS[p], PS[p]*4/1024
	}
	' "$RAW"
	echo
	# 采样曲线摘要
	[ -s "$SAMP" ] && awk '
	/^#/ { next }
	NF < 6 { next }
	{ if (n == 0) { f0 = $2; t0 = $1 }
	  n++; fl = $2; tl = $1
	  if (mn == 0 || $2 < mn) mn = $2
	  if ($2 > mx) mx = $2
	  if (n > 1 && $2 < prev - 1024) drop += prev - $2
	  prev = $2
	  if ($6 > live) live = $6 }
	END { if (n) printf "===== CmaFree 曲线 =====\n  采样 %d 点, 起 %d kB, 止 %d kB, 最低 %d kB, 峰值 %d kB, 累计下降 %d kB (%.1f MB)\n  alloc/release 最大未配平调用数 %d\n", n, f0, fl, mn, mx, drop, drop/1024, live }
	' "$SAMP"
}

case "${1:-status}" in
	start)   do_start ;;
	stop)    do_stop ;;
	report)  do_report ;;
	__sample) do_sample ;;
	status)
		for f in reader sampler; do
			if [ -f "$D/$f.pid" ] && kill -0 "$(cat "$D/$f.pid")" 2>/dev/null; then
				echo "  $f: 运行中 (pid $(cat "$D/$f.pid"))"
			else
				echo "  $f: 未运行"
			fi
		done
		[ -s "$SAMP" ] && echo "  采样点: $(grep -vc '^#' "$SAMP" 2>/dev/null) 行"
		[ -s "$RAW" ] && echo "  事件数: $(wc -l < "$RAW") 行"
		;;
	tail)    tail -"${2:-10}" "$SAMP" 2>/dev/null ;;
	*)       sed -n '2,20p' "$0" ;;
esac

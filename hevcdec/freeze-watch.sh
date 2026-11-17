#!/bin/sh
# 冻结现场抓取器 v2
# 判定只用「au 是否推进」：HB 行 10s 一条，连续两条 au 相同 = 20s 无新帧。
# （v1 用 poll timeout 计数，会误报：drain/reinit 后 poll_timeouts 不清零。）
# 应用侧 STALLSEC 自愈阈值保守，这里 20s 才动手，并记录 rec 是否已自愈。
OUT=/tmp/freeze
mkdir -p $OUT
LOG=/tmp/tvplay.log
prev_au=""
hits=0

snap() {
	ts=$(date +%H%M%S)
	d=$OUT/$ts
	mkdir -p $d
	{
		echo "=== date ==="; date; uptime
		echo "=== player tail ==="; tail -c 2500 $LOG | tr '\r' '\n' | tail -30
		echo "=== dmesg tail ==="; dmesg | tail -50
	} > $d/log.txt 2>&1
	grep -iE "vdec|meson|GIC" /proc/interrupts > $d/irq1.txt
	sleep 1
	grep -iE "vdec|meson|GIC" /proc/interrupts > $d/irq2.txt
	{
		echo "=== kernel threads ==="
		for t in /proc/[0-9]*; do
			c=$(cat $t/comm 2>/dev/null)
			case "$c" in
			*vdec*|*meson*|*esparser*|*irq/*|*kworker*)
				echo "--- $c (${t#/proc/}) ---"
				cat $t/stack 2>/dev/null
				;;
			esac
		done
	} > $d/kstacks.txt 2>&1
	P=$(pgrep -f "v4l2hevc-aarch64" | head -1)
	if [ -n "$P" ]; then
		{
			echo "pid=$P"; cat /proc/$P/wchan 2>/dev/null; echo
			timeout 25 gdb -p $P -batch -ex "bt 12" 2>/dev/null | grep -E "^#"
		} > $d/user.txt 2>&1
	fi
	if [ -e /dev/mem ]; then
		dd if=/dev/mem of=$d/vdec.bin bs=4096 skip=$((0xff620000 / 4096)) count=1 2>/dev/null
		dd if=/dev/mem of=$d/dos.bin bs=4096 skip=$((0xff630000 / 4096)) count=2 2>/dev/null
	fi
	echo "$(date +%H:%M:%S) SNAPSHOT $d" >> /tmp/freeze-watch.log
}

while :; do
	line=$(grep -o "HB t=[0-9]* au=[0-9]*.*" $LOG 2>/dev/null | tail -1)
	if [ -n "$line" ]; then
		au=$(printf '%s' "$line" | sed -n 's/.*au=\([0-9]*\).*/\1/p')
		rec=$(printf '%s' "$line" | sed -n 's/.*rec=\([0-9]*\).*/\1/p')
		if [ -n "$prev_au" ] && [ "$au" = "$prev_au" ]; then
			hits=$((hits + 1))
			echo "$(date +%H:%M:%S) no-progress $hits au=$au rec=$rec :: $line" >> /tmp/freeze-watch.log
			if [ "$hits" -eq 2 ]; then snap; fi
			if [ "$hits" -ge 2 ] && [ $((hits % 15)) -eq 0 ]; then snap; fi
		else
			hits=0
		fi
		prev_au=$au
	fi
	sleep 10
done

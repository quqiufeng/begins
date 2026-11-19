#!/bin/bash
# resident-heal —— 盒子常驻服务兜底（resident-heal.timer 每 10s 跑一次）。
#
# 管两个"底座"服务：
#   desktop —— 屏幕底座（唯一占 KMS 的那个）
#   keybd   —— 遥控/键盘派发底座（GRAB=1 独占 event*，遥控不灵基本就是它躺了）
#
# Restart=always 只管"进程崩了"；管不到这几种：
#   1) 有人 systemctl stop 过（显式意图，systemd 不会自己起来）
#   2) StartLimit 打满后服务变 failed，之后再也不重启
#   3) 迁移脚本 stop 了桌面、自己却没起来（被 Ctrl-C / 报错打断），屏幕全黑
# 这个 timer 把这些都纠回来。
#
# 用法：resident-heal.sh [服务名...]     缺省 = desktop keybd
#
# 让路约定：
#   touch /run/desktop-hold   —— 已知的"我正在用屏幕"，屏幕相关部分完全不插手；
#                                 keybd 不受影响（它不占屏，停了遥控就废了）
#   touch /run/keybd-hold     —— 手工学码/改键位时用，heal 不理 keybd
#   屏幕被别的程序占着（阅读器/播放器/测试程序握着 /dev/dri/card0）也不抢，
#   因为那说明有人正在用屏幕；只有确认是"孤儿残留"（PPID=1、超时仍不退出）
#   才收掉，避免把正常播放/测试打断。
set -u
LOG=/var/log/resident-heal.log
HOLD=/run/desktop-hold
KHOLD=/run/keybd-hold
ORPH=/run/resident-heal.orphan
ORPH_GRACE=${ORPH_GRACE:-90}
say() { echo "[$(date "+%F %T")] $*" >>"$LOG"; }

SERVICES=("$@")
[ ${#SERVICES[@]} -eq 0 ] && SERVICES=(desktop keybd)

want() { local s; for s in "${SERVICES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
alive() { case "$(systemctl is-active "$1" 2>/dev/null)" in
	active|activating|reloading|deactivating) return 0 ;; esac; return 1; }
pullup() {
	local svc=$1 reason=$2
	say "$svc 不在（$reason），拉起"
	systemctl --no-block reset-failed "$svc.service" 2>/dev/null
	systemctl --no-block start "$svc.service"
}

# ---- keybd：纯输入守护，不占屏，逻辑简单 ----
if want keybd; then
	if [ -e "$KHOLD" ]; then
		:
	elif ! alive keybd.service; then
		pullup keybd "$(systemctl is-active keybd.service 2>/dev/null)"
	fi
fi

# ---- desktop：占 KMS，要先确认没人（正常的）在用屏幕 ----
want desktop || exit 0

[ -e "$HOLD" ] && exit 0

alive desktop.service && exit 0

# 找谁握着 KMS（kmshold 的 sleep 是有意的常驻 fd，跳过）
holder=""
for p in /proc/[0-9]*; do
	pid=${p#/proc/}
	comm=$(tr -d "\0" <"$p/comm" 2>/dev/null) || continue
	case "$comm" in sleep|systemd*|bash|sh|kmshold*) continue ;; esac
	for f in "$p"/fd/*; do
		t=$(readlink "$f" 2>/dev/null) || continue
		case "$t" in /dev/dri/card*|/dev/dri/render*) holder="$pid:$comm"; break 2 ;; esac
	done
done

if [ -n "$holder" ]; then
	# 有人占屏：记着，但先不动。超过宽限期还是它，就当残留清掉。
	prev=$(cat "$ORPH" 2>/dev/null)
	:
	ppid=$(awk "{print \$4}" "/proc/${holder%%:*}/stat" 2>/dev/null)
	if [ "${prev%% *}" = "${holder%%:*}" ] && [ -f "$ORPH.t" ]; then
		first=$(cat "$ORPH.t" 2>/dev/null || echo 0)
		age=$(( $(date +%s) - first ))
		if [ "$age" -ge "$ORPH_GRACE" ]; then
			say "KMS 被 $holder 占了 ${age}s（PPID=$ppid），按孤儿收掉"
			kill -9 "${holder%%:*}" 2>/dev/null
			rm -f "$ORPH" "$ORPH.t"
			sleep 1
		else
			exit 0
		fi
	else
		say "KMS 被 $holder 占着（PPID=$ppid），先不动"
		echo "${holder%%:*} $holder" >"$ORPH"
		date +%s >"$ORPH.t"
		[ "$ppid" = 1 ] || rm -f "$ORPH" "$ORPH.t"   # 有爹的交给它爹管
		exit 0
	fi
fi
rm -f "$ORPH" "$ORPH.t"

pullup desktop "$(systemctl is-active desktop.service 2>/dev/null)"

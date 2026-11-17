#!/bin/sh
# play.sh — 一条命令把电影放上屏（X96Max / meson-vdec 硬解 + GLES3 出图）
#
#   ./play.sh 片子.mkv                    # 从头放，前台，Ctrl-C 停
#   ./play.sh 片子.mkv 600                # 从第 600 秒放
#   ./play.sh 片子.mkv 600 120            # 放 2 分钟就停
#   ./play.sh -d 片子.mkv                 # 后台放，然后 ./play.sh status 看进度
#   ./play.sh pause / resume / stop / status
#
# 电影就是「ffmpeg 供流 | 播放器解码上屏」一条管道，这个脚本只做四件事：
# 拼管道、管进程组、清理旧实例、把状态写进 /tmp/play.*。
#
# 为什么必须设这些变量（漏了就是黑屏而不是报错）：
#   PLAY=1     不设则根本不走渲染路径，解码结果落盘，屏幕上什么都不变
#   NOWRITE=1  不设则写 /tmp/out.yuv，4K 约 150MB/s，几秒写满 tmpfs 并拖到 10fps
#   -re        ffmpeg 按片源节拍供流，管道水位可控；播放器另有自己的节拍
#   容器 → Annex-B  ffmpeg -c copy -f hevc，首包才有 start code、SPS 才读得出来
set -u

BIN=${BIN:-/tmp/v4l2hevc-aarch64}
LOG=${LOG:-/tmp/play.log}
PIDF=${PIDF:-/tmp/play.pid}
STATE=${STATE:-/tmp/play.state}
RENDER=${RENDER:-gl}          # gl / drm / auto
SCALE=${SCALE:-fit}           # fit / fill / crop（只对 drm 平面路径生效）
AUDIO=${AUDIO:-1}             # 1=出声：ffmpeg 写 $AFIFO，播放器内建 aout 读出来喂 ALSA
FPS=${FPS:-}                  # 留空=播放器默认 24；填 0 会被 atof 读成 0 卡死节拍
LEAD=${LEAD:-}                # 留空=默认 6 帧
DITHER=${TMDITHER:-}          # 0=关有序抖动
SOCK=${SOCK:-/tmp/play.sock}  # 播放器自己的控制口（音量/静音/暂停/位置走这里）
AFIFO=${AFIFO:-/tmp/play.afifo}  # ffmpeg 写 PCM 的管道，内建 aout 从这读
# ALSA 缓冲（帧数）：太大拖遥控反应，太小 4K+HDR 调色那几帧就把音频线程饿出
# xrun（默认 8192/2048 = 170/42ms，实测一片下来几十次）。16k/4k≈340/85ms 稳得多。
AUDIO_BUF=${AUDIO_BUF:-16384}
AUDIO_PERIOD=${AUDIO_PERIOD:-4096}
DEBUG=0

enc() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }
dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }

usage() {
	cat <<EOF
用法：play.sh [选项] <片源> [起播秒] [时长秒]
      play.sh {pause|resume|stop|status|log}
      play.sh key <动作>      # 遥控器入口：toggle/fwd/back/fwdmore/backmore/volup/voldn/mute/quit

片源可以是 mkv/mp4/ts（走 ffmpeg 解封装）或裸流 .265/.h265/.hevc（直接喂）。

选项：
  -r gl|drm|auto  上屏后端（默认 $RENDER）
  -s fit|fill|crop  缩放模式（默认 $SCALE，仅 drm）
  -f <帧率>       强制节拍帧率（默认读片源/24）
  -a 0|1          是否出声（默认 $AUDIO；ffmpeg 灌 PCM 到 $AFIFO，播放器内建 aout 出声）
  -B <路径>       播放器二进制（默认 $BIN）
  -d              后台放，立即返回（配 status/pause/stop 用）
  -v              前台同时 tail 日志
  -h              本帮助
EOF
}

die() { echo "play.sh: $*" >&2; exit 1; }
say() { echo "play.sh: $*"; }

# ── 进程组操作 ───────────────────────────────────────────────
# 整条管道（ffmpeg + 播放器）用 setsid 起成独立进程组，
# 暂停/停止对「组」发信号：只停播放器会让 ffmpeg 继续灌满管道。
load_state() {
	[ -f "$STATE" ] || return 1
	# shellcheck disable=SC1090
	. "$STATE" 2>/dev/null || return 1
	return 0
}

alive() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] 2>/dev/null; }

group_sig() {   # group_sig <SIG> <pgid>
	_sig=$1; _pg=$2
	[ -n "$_pg" ] || return 0
	_pg=${_pg#-}
	kill -s "$_sig" -- "-$_pg" 2>/dev/null
}

stopped() {     # 进程组是否被 SIGSTOP 冻住：看组长的 State 字段
	_st=$(sed 's/.*) \(.\) .*/\1/' "/proc/$1/stat" 2>/dev/null)
	[ "$_st" = "T" ]
}

# ── 清场 ─────────────────────────────────────────────────────
# 旧实例不杀干净会两个进程抢同一个 DRM master，后起的那条永远不上屏。
cleanup_old() {
	# 必须放在子 shell 里：load_state 是 . 号引入，会把调用者的 SRC/SS/DUR
	# 覆盖成旧 state 的值 —— 那样 seek 重开永远从"上次的起播秒"开始，
	# 屏幕上却已经打印了"跳到 xxxs"（实测快进 1061→1071，实际重开在 900）。
	_old=$( ( load_state && printf '%s %s' "${VPID:-}" "${APID:-}" ) )
	_ovp=${_old%% *}; _oap=${_old##* }
	if [ -n "$_old" ]; then
		group_sig TERM "$_ovp"; group_sig TERM "$_oap"
		sleep 0.2
		group_sig KILL "$_ovp"; group_sig KILL "$_oap"
		rm -f "$STATE"
	fi
	# 兜底：脚本外起的残留（含老版本二进制名 / 老脚本起的裸管道）
	# comm 在核心里只有 15 字节（/proc/<pid>/comm），不加截断 pkill -x 永远匹配不上，
	# 旧实例就一直在抢 DRM master —— 表现是「新起的进程不报错，屏幕黑着」。
	for _p in v4l2hevc-aarch64 v4l2hevc v4l2hevc-gl-aarch64 hevcplay3 hevcplay4; do
		pkill -9 -x "$(printf '%.15s' "$_p")" 2>/dev/null
	done
	pkill -9 -f 'ffmpeg .*-f hevc' 2>/dev/null
	# 上次异常退出会把 fifo 留在原地，ffmpeg 见到就 "File already exists" 收工
	rm -f "$AFIFO"
	# 老链路把声音交给游离的 mpv/mpvctl：不清掉就是两路抢同一个 PCM
	pkill -9 -x mpv 2>/dev/null
	rm -f "$SOCK"
	sleep 0.15
}

# ── 播放 ─────────────────────────────────────────────────────
do_play() {
	SRC=$1
	case "$SRC" in
	http://*|https://*|rtsp://*) ;;
	*) [ -f "$SRC" ] || [ -r "$SRC" ] || die "片源不存在：$SRC" ;;
	esac
	[ -x "$BIN" ] || die "找不到播放器：$BIN（scp 到盒子上，或用 -B 指定）"

	case "$SS" in ''|*[!0-9.]*) die "起播秒不是数字：$SS" ;; esac
	case "$DUR" in ''|*[!0-9.]*) die "时长不是数字：$DUR" ;; esac
	case "$SS" in *.*.*) die "起播秒格式不对：$SS" ;; esac

	case "$SRC" in
	*.265|*.h265|*.hevc|*.bin) NAKED=1 ;;
	*) NAKED=0 ;;
	esac
	# 裸流没有时间戳，不能 seek：宁可拒绝，也别让人以为"跳过去了"
	if [ "$NAKED" = 1 ] && [ "$SS" != "0" ] && [ "$SS" != "0.0" ]; then
		die "裸流（$SRC）不能从 $SS 秒起播，没有时间戳可 seek"
	fi

	if [ -n "$FPS" ]; then
		case "$FPS" in ''|*[!0-9.]*) die "帧率不是数字：$FPS" ;; esac
	fi
	case "$RENDER" in gl|drm|auto) ;; *) die "RENDER 只能是 gl/drm/auto" ;; esac
	case "$SCALE"  in fit|fill|crop) ;; *) die "SCALE 只能是 fit/fill/crop" ;; esac
	case "$AUDIO"  in 0|1) ;; *) die "AUDIO 只能是 0/1" ;; esac

	cleanup_old
	: > "$LOG"

	# DUR=0 意为「放到结尾」：绝不能展开成 -t 0。
	# ffmpeg 的 -t 0 会在 1s 内灌完 14MB 就退出（-re 都失效），
	# 表现是「没声音，几秒后画面也停」。
	DA=""; [ "${DUR:-0}" != "0" ] && DA="-t $DUR"

	# 音轨：声音和画面走同一条 ffmpeg，PCM 写进 $AFIFO，播放器内建 aout
	# 读出来喂 ALSA。同一个 demux、同一个 -ss，音画就此落在同一时钟域
	# （视频配速以 aout 的 played_ms 为主钟）。
	#
	# 为什么要探测：ffmpeg 的 `-map 0:a:0?` 在片源没音轨时会让整个输出报
	# "Output file does not contain any stream" 直接失败 —— 连画面一起没了。
	AF=""; AFIFO_USE=""
	if [ "$AUDIO" = 1 ] && [ "$NAKED" = 0 ]; then
		_ha=0
		if command -v ffprobe >/dev/null 2>&1; then
			if ffprobe -v error -select_streams a:0 -show_entries stream=index \
				-of csv=p=0 "$SRC" 2>/dev/null | grep -q .; then
				_ha=1
			fi
		else
			_ha=1	# 没有 ffprobe：假定有音轨，别把正常的片子搞成静音
		fi
		if [ "$_ha" = 1 ]; then
			rm -f "$AFIFO"
			mkfifo -m 600 "$AFIFO" || die "建不了 $AFIFO"
			AFIFO_USE=$AFIFO
			AF="-map 0:a:0 -f s16le -ar 48000 -ac 2 $AFIFO"
		else
			say "片源没有音轨，只放画面"
		fi
	fi

	# 内层交给 sh 展开：路径里有空格也不会被拆开。
	# set -f：关掉通配，$AF 里的 `0:a:0` 之类不会被当 glob 展开。
	# AUDIO_FIFO 直接 export：写成 `${X:+AUDIO_FIFO=...}` 那个赋值不会生效，
	# 展开出来的是一个「命令名」，报 AUDIO_FIFO=/tmp/play.afifo: not found。
	export SRC SS DUR DA NAKED BIN LOG RENDER SCALE AFIFO_USE SOCK AUDIO
	if [ -n "$AFIFO_USE" ]; then export AUDIO_FIFO="$AFIFO_USE"; else unset AUDIO_FIFO; fi
	export AUDIO_BUF AUDIO_PERIOD
	[ -n "$FPS" ] && export FPS
	[ -n "$LEAD" ] && export LEAD
	[ -n "$DITHER" ] && export TMDITHER="$DITHER"
	export AF

	set -- 'set -uf
if [ "$NAKED" = 1 ]; then
	cat "$SRC"
else
	ffmpeg -hide_banner -loglevel warning -nostdin -y -re \
		${SS:+-ss "$SS"} $DA \
		-i "$SRC" -map 0:v:0 -c:v copy -f hevc - $AF 2>>"$LOG"
fi | PLAY=1 NOWRITE=1 RENDER="$RENDER" SCALE="$SCALE" PLAY_SOCK="$SOCK" \
	"$BIN" - >>"$LOG" 2>&1'

	# </dev/null：不然 ssh 远端起播时子进程握着 stdin，ssh 永远等不到 EOF
	# 外层 sh 也要重定向：否则它握着调用者的 stdout，ssh 远端起播会一直等 EOF
	setsid sh -c "$1" >>"$LOG" 2>&1 </dev/null &
	VPID=$!

	# 声音不再单起进程：播放器内建 aout 直接从 $AFIFO 读 PCM，
	# 遥控器控制也走它自己的 $SOCK（play.sh 用 `$BIN -c ...` 说话）。
	APID=""
	if [ "$AUDIO" = 1 ] && [ -n "$AFIFO_USE" ]; then
		# 控制口没起来就别假装能遥控：音量/暂停/位置全指着它
		_w=0
		while [ "$_w" -lt 20 ]; do
			[ -S "$SOCK" ] && break
			alive "$VPID" || break
			_w=$((_w + 1)); sleep 0.1
		done
		if ! alive "$VPID"; then
			say "警告：播放进程已退出，看 $LOG"
		elif [ ! -S "$SOCK" ]; then
			say "警告：控制口 $SOCK 没起来，遥控器音量/暂停会失效"
		fi
	fi

	# SRC/SOCK/AUDIO 都要写进 state：遥控器 seek 要整条链重开，
	# 重启参数只能从 state 里取（播放进程自己不记得是从哪部片子来的）。
	{
		printf 'VPID=%s\nAPID=%s\nSS=%s\nDUR=%s\nBIN=%s\n' "$VPID" "$APID" "$SS" "$DUR" "$BIN"
		printf 'LOGF=%s\nSOCK=%s\nAUDIO=%s\nRENDER=%s\nSCALE=%s\nFPS=%s\n' \
			"$LOG" "$SOCK" "$AUDIO" "$RENDER" "$SCALE" "${FPS:-}"
		printf 'SRCB64=%s\n' "$(enc "$SRC")"
	} > "$STATE"

	if [ "$DUR" = "0" ] || [ -z "$DUR" ]; then
		say "开始：$SRC  从 ${SS}s 放到结尾，后端 $RENDER"
	else
		say "开始：$SRC  ${SS}s → $((SS + DUR))s（$DUR 秒），后端 $RENDER"
	fi
	sleep 1.5
	# 上屏成功与否只看日志里的这两行，别靠"屏幕亮了没"
	if grep -q '^PLAY: \(plane=\|renderer=\)' "$LOG" 2>/dev/null; then
		sed -n 's/^PLAY: /  /p' "$LOG" | head -1
	else
		say "警告：日志里没有 PLAY: plane=/renderer= 行，可能没上屏"
		say "      先看 $LOG，再查 head -4 /sys/kernel/debug/dri/0/state"
	fi
	return 0
}

# ── 子命令 ───────────────────────────────────────────────────
# 暂停走播放器自己的控制口，不再对进程组发 SIGSTOP：
# STOP 会连 aout 线程和 ffmpeg 一起冻住，位置/hw_ptr 全停摆，之后 resume
# 还容易和 pctl 的暂停计时打架（两处各记一份暂停时长，时间轴就漂）。
# pctl 的 set_paused 会顺手 aout_set_paused，音画一起停，位置也停在该停的
# 地方。没有控制口（老二进制）才退回冻进程组。
pctl() {	# pctl <命令...>
	[ -S "${SOCK:-/nonexist}" ] || return 1
	PCTL_ECHO=1 PLAY_SOCK="$SOCK" "${BIN:-/tmp/v4l2hevc-aarch64}" -c "$@" 2>/dev/null
}

# 当前是不是暂停：优先问播放器（它自己记着 pause 状态），
# 老二进制没法问，才退回"进程组是不是 STOP 的"。
is_paused() {
	case "$(pctl status)" in
	*'"paused":1'*) return 0 ;;
	*'"paused":0'*) return 1 ;;
	esac
	stopped "${VPID:-0}" 2>/dev/null
}

do_pause() {
	load_state || die "没有在放的片子"
	alive "${VPID:-}" || die "播放进程已退出"
	is_paused && { say "已经是暂停状态"; return 0; }
	if pctl pause >/dev/null; then
		say "已暂停"
		return 0
	fi
	group_sig STOP "${VPID:-}"
	say "已暂停（无控制口，冻进程组）"
}

do_resume() {
	load_state || die "没有在放的片子"
	group_sig CONT "${VPID:-}"
	pctl resume >/dev/null 2>&1
	say "已继续"
}

do_stop() {
	if load_state && alive "${VPID:-}"; then
		# 先让播放器自己收尾（它知道要关 aout、还原 DRM），再兜底杀组
		pctl quit >/dev/null 2>&1
		sleep 0.4
		alive "${VPID:-}" && group_sig TERM "${VPID:-}"
		sleep 0.3
		group_sig KILL "${VPID:-}"
	fi
	rm -f "$STATE"
	say "已停止"
}

# 当前位置（秒）：心跳的 t= 是「进程启动后过了多少秒」，不含起播偏移，
# 加回 SS 才是片源位置；它比墙钟准（暂停/卡顿期间不跑偏），有就用它。
pos_of() {
	load_state || return 1
	# 优先问播放器要实时位置：HB 心跳 10s 一条，靠它算位置会一格跳 10 秒，
	# 遥控器连按时"位置没变"的观感就是这么来的。pos_ms 是音频主钟推出来的
	# 播放时间轴（相对起播点），加回 SS 才是片源位置。
	_tm=$(pctl pos | sed -n 's/.*"pos_ms":\([0-9]*\).*/\1/p')
	case "${_tm:-}" in
	'') ;;
	*) awk -v m="$_tm" -v o="${SS:-0}" -v d="${DUR:-0}" 'BEGIN{
	       p = int(m / 1000) + o
	       if (d > 0 && p > o + d) p = o + d
	       printf "%d", p }'; return 0 ;;
	esac
	_pt=$(sed -n 's/.*HB t=\([0-9]*\) au=.*/\1/p' "$LOGF" 2>/dev/null | tail -1)
	if [ -n "${_pt:-}" ]; then
		awk -v t="$_pt" -v o="${SS:-0}" -v d="${DUR:-0}" 'BEGIN{
			p = t + o; if (d > 0 && p > o + d) p = o + d; printf "%d", p }'
	else
		# 还没有一次心跳：只能按墙钟近似（起播时间 + 起播点）
		_now=$(date +%s); _start=$(stat -c %Y "$STATE" 2>/dev/null || echo "$_now")
		awk -v s="$((_now - _start))" -v o="${SS:-0}" -v d="${DUR:-0}" 'BEGIN{
			p = s + o; if (d > 0 && p > o + d) p = o + d; printf "%d", p }'
	fi
}

do_status() {
	load_state || { say "没有在放"; return 0; }
	if ! alive "${VPID:-}"; then
		say "播放进程已退出（看 $LOGF）"; return 0
	fi
	if is_paused; then
		_st="暂停中"
	else
		_st="播放中"
	fi
	_pos=$(pos_of)
	_hb=$(sed -n 's/.*HB t=[0-9]* au=\([0-9]*\).*/au=\1/p' "$LOG" 2>/dev/null | tail -1)
	printf '状态：%s  位置：%ss  后端：%s  %s\n' "$_st" "$_pos" "$RENDER" "${_hb:+解出 $_hb 个 AU}"
	printf '日志：%s\n' "$LOGF"
}

# ── 遥控器动作（rcinputd 每按一次键 exec 一次本脚本）─────────────
# 动作名与 rcinputd.c 的 action_of() 一一对应：
#   toggle 暂停/继续        fwd/back ±10s     fwdmore/backmore ±60s
#   volup/voldn ±10         mute 静音          quit 停播
# 视频这条链没有 IPC，seek 只能整条重开（约 1s 黑屏），所以：
#   ① 重开参数全从 state 取（SRC/SOCK/AUDIO/RENDER/SCALE/FPS）；
#   ② 3s 内的重复 seek 直接丢弃 —— 按住 ▶ 的连发会在松开后逐个补跑，
#      表现就是「按一下，画面消失半天」。
seek_guard() {
	_s=/tmp/play.seek.stamp
	_n=$(date +%s); _p=$(cat "$_s" 2>/dev/null || echo 0)
	case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
	if [ $((_n - _p)) -lt 3 ]; then
		say "seek 合并（距上次 $((_n - _p))s，丢弃连发）"
		return 1
	fi
	echo "$_n" > "$_s"
	return 0
}

# 音量只能在播放器里做（软件增益）：这块板的 ALSA 没有可写的主音量
# （ACODEC 不存在，只有 SPDIF/TDM 的通道音量，动它就是动别的输出路径）。
vol_step() {
	_d=$1
	if [ "${AUDIO:-0}" != 1 ]; then
		say "没有音频输出，音量键忽略"
		return 0
	fi
	# 相对量交给播放器算：这里"读旧值写新值"连按会丢
	_r=$(pctl vol "$_d") || { say "控制口不可用，音量键无法执行"; return 1; }
	_v=$(printf '%s' "$_r" | sed -n 's/.*"vol":\([0-9]*\).*/\1/p')
	say "音量 → ${_v:-?}"
}

do_key() {
	ACT=${1:-}
	load_state || { say "遥控器：没有在放的片子"; return 1; }
	case "$ACT" in
	toggle)
		[ -n "${VPID:-}" ] && alive "$VPID" || { say "遥控器：播放进程已退出"; return 1; }
		if is_paused; then do_resume; else do_pause; fi
		;;
	volup)  vol_step +10 ;;
	voldn)  vol_step -10 ;;
	mute)
		if pctl mute >/dev/null; then
			say "音轨静音切换"
		else
			say "控制口不可用，静音键忽略"
		fi
		;;
	quit)   do_stop ;;
	fwd|back|fwdmore|backmore)
		case "$ACT" in
		fwd) D=10 ;; back) D=-10 ;; fwdmore) D=60 ;; backmore) D=-60 ;;
		esac
		P=$(pos_of); [ -n "$P" ] || P=0
		T=$((P + D)); [ "$T" -lt 0 ] && T=0
		# 已播时长：有 DUR 就只放剩下的，别让"±10s"变成"循环到结尾"
		_r=0
		if [ "${DUR:-0}" -gt 0 ]; then
			_r=$((DUR - (T - SS))); [ "$_r" -le 0 ] && _r=$DUR
		fi
		seek_guard || return 0
		_WAS=0; is_paused && _WAS=1
		say "跳到 ${T}s（原 ${P}s，偏移 $D）"
		SRC=$(dec "${SRCB64:-}")
		[ -n "$SRC" ] || { say "state 里没有片源，无法重开"; return 1; }
		setsid sh "$0" -d -a "${AUDIO:-1}" -r "${RENDER:-gl}" -s "${SCALE:-fit}" \
			${FPS:+-f "$FPS"} -B "${BIN:-/tmp/v4l2hevc-aarch64}" \
			"$SRC" "$T" "$_r" >/dev/null 2>&1 </dev/null
		# 暂停中拖动：重开后再压回去，保持"暂停"语义
		if [ "$_WAS" = 1 ]; then sleep 0.5; load_state && do_pause; fi
		;;
	menu|home) say "动作 $ACT：没有 UI，忽略" ;;
	*) say "遥控器：未知动作 $ACT"; return 1 ;;
	esac
	return 0
}

# ── 参数 ─────────────────────────────────────────────────────
[ $# -gt 0 ] || { usage; exit 1; }

case "$1" in
pause|resume|stop|status|log|key)
	_act=$1; shift
	case "$_act" in
	pause)  do_pause  ;;
	resume) do_resume ;;
	stop)   do_stop   ;;
	status) do_status ;;
	log)    load_state >/dev/null 2>&1; exec tail -f "${LOGF:-$LOG}" ;;
	key)    do_key "${1:-}" ;;
	esac
	exit 0
	;;
esac

BACKGROUND=0
while getopts 'r:s:f:a:B:dvHh' _o 2>/dev/null; do
	case "$_o" in
	r) RENDER=$OPTARG ;;
	s) SCALE=$OPTARG  ;;
	f) FPS=$OPTARG    ;;
	a) AUDIO=$OPTARG  ;;
	B) BIN=$OPTARG    ;;
	d) BACKGROUND=1   ;;
	v) DEBUG=1        ;;
	h) usage; exit 0  ;;
	*) usage; exit 1  ;;
	esac
done
shift $((OPTIND - 1))

[ $# -ge 1 ] || { usage; exit 1; }
SRC=$1
SS=${2:-0}
DUR=${3:-0}

do_play "$SRC" || exit 1

if [ "$BACKGROUND" = 1 ]; then
	say "后台运行，PID $VPID（./play.sh status 查看，stop 停止）"
	exit 0
fi

# 前台：等这条管道结束。Ctrl-C 时整组收掉，别留孤儿进程在唱。
trap 'do_stop; exit 130' INT TERM
[ "$DEBUG" = 1 ] && tail -f "$LOG" &
_TAILPID=$!
while alive "$VPID"; do sleep 0.3; done
[ -n "${_TAILPID:-}" ] && kill "$_TAILPID" 2>/dev/null
do_stop >/dev/null 2>&1
say "播放结束（退出前日志尾部）："
tail -5 "$LOG" 2>/dev/null | sed 's/^/  /'

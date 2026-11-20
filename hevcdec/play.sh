#!/bin/sh
# play.sh — 一条命令把电影放上屏（X96Max / meson-vdec 硬解 + GLES3 出图）
#
#   ./play.sh 片子.mkv                    # 从头放，前台，Ctrl-C 停
#   ./play.sh 片子.mkv 600                # 从第 600 秒放
#   ./play.sh 片子.mkv 600 120            # 放 2 分钟就停
#   ./play.sh -d 片子.mkv                 # 后台放，然后 ./play.sh status 看进度
#   ./play.sh pause / resume / stop / status
#
#   # NAS 上的片子：参数给 NAS 上完整的路径，认证从 .env 里取，不落地直接播
#   ./play.sh /sata11-18072858035/av/Unpai/xxx.mp4
#   ./play.sh -n /sata11-18072858035/av/Unpai/xxx.mp4    # -n 只看解析结果，不放
#   （.env 里要 WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS，见 docs/playback.md）
#
# 电影就是「ffmpeg 供流 | 播放器解码上屏」一条管道，这个脚本只做四件事：
# 拼管道、管进程组、清理旧实例、把状态写进 /tmp/play.*。
#
# 为什么必须设这些变量（漏了就是黑屏而不是报错）：
#   PLAY=1     不设则根本不走渲染路径，解码结果落盘，屏幕上什么都不变
#   NOWRITE=1  老版本必须；现在 PLAY=1 默认就不落盘（显式 OUTYUV 才写），
#              保留只为向下兼容，改默认前漏设过：1080p 写盘把 23.6 拖到 18.2 fps
#   -re        ffmpeg 按片源节拍供流，管道水位可控；播放器另有自己的节拍
#   容器 → Annex-B  ffmpeg -c copy -f hevc，首包才有 start code、SPS 才读得出来
set -u

# 播放器位置：部署在 /root（重启不丢，不再靠 rcup 往 /tmp 补）。
# 老盒子/临时调试的 /tmp 副本仍然认，BIN 显式给了就以它为准。
if [ -z "${BIN:-}" ]; then
	for _b in /root/v4l2hevc-aarch64 /tmp/v4l2hevc-aarch64 \
	          "$(dirname "$0")/v4l2hevc-aarch64" /tmp/v4l2hevc; do
		[ -x "$_b" ] && { BIN=$_b; break; }
	done
	BIN=${BIN:-/root/v4l2hevc-aarch64}
fi
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
# 增益：这块板的 ALSA 主音量写不了（TDMOUT_B Lane 已是 100%，SPDIF 那路
# 0% 是给别的输出路径的），声音大小只能在 PCM 上做。实测片源峰值只剩
# -6.5..-18dBFS、对白 mean -28..-40dB，电视得开到 60 才够响 —— 相当于
# 白白空着 10~20dB 的动态余量。这里统一补 AGAIN dB，再用 alimiter 卡住
# 过冲（只压最响的几个峰，不做整体归一化，不会像 loudnorm 那样吃 CPU）。
AGAIN=${AGAIN:-12}            # dB，0=不补；太大就削波变糊
DRC=${DRC:-0}                 # 0=关掉 AC3/TrueHD 的 dialnorm/DRC（会额外压低音量）
DEBUG=0
DRYRUN=0                      # -n：只解析片源/打印命令，不播

enc() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }
dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# ── NAS 片源（.env）──────────────────────────────────────────
# 片源不必先下载、也不必手拼 URL：参数给 NAS 上的完整路径就够，
# 脚本按 .env 里的 WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS 自己拼出带认证的
# http 源。认证只能内嵌在 URL 里 —— ffmpeg 的 http 协议没有 user/password
# 选项，盒子上也没有 curl 可用（tvplay.sh 用的是同一个写法）。
_SDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
ENVF=${PLAY_ENV:-}          # 显式指定 .env 时优先（PLAY_ENV=/path/.env play.sh ...）

env_find() {                # .env 查找顺序：指定的 → cwd 向上 → 脚本目录向上 → ~/.env
	[ -n "$ENVF" ] && return 0
	_d=$(pwd)
	while :; do
		[ -r "$_d/.env" ] && { ENVF=$_d/.env; return 0; }
		[ "$_d" = / ] && break
		_d=$(dirname "$_d")
	done
	_d=${_SDIR:-.}
	while :; do
		[ -r "$_d/.env" ] && { ENVF=$_d/.env; return 0; }
		[ "$_d" = / ] && break
		_d=$(dirname "$_d")
	done
	for _d in "$HOME/.config/lite/.env" "$HOME/.env"; do
		[ -r "$_d" ] && { ENVF=$_d; return 0; }
	done
	return 1
}

# 只认 KEY=VALUE 单行：值可以带 '...' "..."，也可以裸写后用 # 注释。
# 不 source 整个 .env —— 那是给 mpv/tvplay 用的杂物清单，里面有裸空格值，
# 一把 . 进来就会把 set -u 的 play.sh 打崩。
env_get() {	# env_get <KEY>
	[ -n "$ENVF" ] || return 0
	_v=$(sed -n "s/^[[:space:]]*$1=//p" "$ENVF" 2>/dev/null | tail -n 1)
	case "$_v" in
	\'*) _v=${_v#\'}; _v=${_v%%\'*} ;;
	\"*) _v=${_v#\"}; _v=${_v%%\"*} ;;
	*)   _v=${_v%%#*}; _v=$(printf '%s' "$_v" | sed 's/[[:space:]]*$//') ;;
	esac
	printf '%s' "$_v"
}

nas_setup() {	# 环境变量优先，其次 .env；缺 WEBDAV_URL 就返回 1
	[ -n "${NAS_READY:-}" ] && return 0
	env_find
	NAS_URL=${WEBDAV_URL:-$(env_get WEBDAV_URL)}
	NAS_USER=${WEBDAV_USER:-$(env_get WEBDAV_USER)}
	NAS_PASS=${WEBDAV_PASS:-$(env_get WEBDAV_PASS)}
	NAS_ROOT=${WEBDAV_MOVIES:-$(env_get WEBDAV_MOVIES)}
	NAS_READY=1
	[ -n "$NAS_URL" ] || return 1
	return 0
}

# 逐字节百分号编码：保留 unreserved 和 / 和 %，中文/空格/@ 都转 %XX。
# % 保留是故意的 —— NAS 的 WebDAV href 本来就是 %E5%B0%8F... 这种已编码形式，
# 再转一遍就成了 %25E5（404）。裸路径里真带 % 的片子名极罕见，认了。
url_enc() {
	printf '%s' "$1" | od -An -tu1 -v | tr -s ' \n' '  ' |
		awk '{ for (i = 1; i <= NF; i++) {
			c = $i + 0
			if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
			    c == 45 || c == 46 || c == 95 || c == 126 || c == 47 || c == 37) printf "%c", c
			else printf "%%%02X", c } }'
}

# <host:port>/<path> → http://user:pass@host:port/<enc(path)>
dav_url() {
	_hp=$1
	_hp=${_hp#http://}; _hp=${_hp#https://}
	_h=${_hp%%/*}
	case "$_hp" in */*) _p=/${_hp#*/} ;; *) _p= ;; esac
	printf 'http://%s:%s@%s%s' "$NAS_USER" "$NAS_PASS" "$_h" "$(url_enc "$_p")"
}

# 片源解析：本地文件 > 显式 URL > NAS 完整路径。
# 判据是「文件在本地存不存在」—— 盒子上不可能有 /sata11-... 这个目录，
# 所以这种绝对路径必然是 NAS 上的。
resolve_src() {
	case "$SRC" in
	http://*|https://*|rtsp://*|rtmp://*|udp://*|tcp://*|ftp://*) return 0 ;;
	dav://*)	# dav://host:port/path 直接给完整地址（认证仍然从 .env 来）
		nas_setup || return 0
		SRC=$(dav_url "${SRC#dav://}")
		SRC_REMOTE=1
		return 0
		;;
	esac
	[ -f "$SRC" ] && return 0	# 本地文件优先
	nas_setup || return 0		# 没配 NAS：原样留给后面报「片源不存在」
	case "$SRC" in
	nas:*) _p=${NAS_ROOT}${SRC#nas:} ;;	# nas:/av/x.mp4 = 相对 WEBDAV_MOVIES
	/*)    _p=$SRC ;;
	*)     return 0 ;;
	esac
	SRC=$(dav_url "${NAS_URL#http://}$_p")
	SRC_REMOTE=1
	return 0
}

usage() {
	cat <<EOF
用法：play.sh [选项] <片源> [起播秒] [时长秒]
      play.sh {pause|resume|stop|status|log}
      play.sh key <动作>      # 遥控器入口（动作表见 `play.sh keys`）
      play.sh keys            # 列遥控键位表（键码/动作，来自播放器 rcmap.h）

片源可以是 mkv/mp4/ts（走 ffmpeg 解封装）或裸流 .265/.h265/.hevc（直接喂）。
也可以给 NAS 上完整的路径（/sata11-.../av/xxx.mp4，或 nas:/av/xxx.mp4），
认证从 .env 的 WEBDAV_URL/WEBDAV_USER/WEBDAV_PASS 取，不落地直接播。

选项：
  -r gl|drm|auto  上屏后端（默认 $RENDER）
  -s fit|fill|crop  缩放模式（默认 $SCALE，仅 drm）
  -f <帧率>       强制节拍帧率（默认读片源/24）
  -a 0|1          是否出声（默认 $AUDIO；ffmpeg 灌 PCM 到 $AFIFO，播放器内建 aout 出声）
  -B <路径>       播放器二进制（默认 $BIN）
  -d              后台放，立即返回（配 status/pause/stop 用）
  -v              前台同时 tail 日志
  -n              只把片源解析成最终 URL/命令打出来，不播（查 .env 对不对）
  -h              本帮助
EOF
}

die() { echo "play.sh: $*" >&2; exit 1; }
say() { echo "play.sh: $*"; }

# ── fbcon 让位 ───────────────────────────────────────────────
# seek/fwd 不是原地跳，而是整条链重开：旧进程退出 → DRM master 释放 →
# 内核的 fbdev 客户端立刻把 mesondrmfb 里的 tty1 文本重新推上主 plane，
# 屏幕上就是「命令行界面」一闪；按住快进连发时反复闪。
# 实测（dri/0/state + fbcon 绑/解绑对照）：解绑 fbcon 后，master 释放时
# 没人来抢屏，主 plane 继续引用最后那个 fb → 间隙里画面「冻结在上一帧」，
# 连发 5 次只有 1 帧 10ms 的空档，一帧不黑、不掉文本。
# 代价：解绑期间 HDMI/串口上没有内核 console（日志照样进 $LOG），
#       所以停止/退出必须 rebind，否则崩了就没命令行可看。
vtcon_bind() {
	for _b in /sys/class/vtconsole/vtcon*/bind; do
		[ -e "$_b" ] || continue
		case "$(cat "${_b%/*}/name" 2>/dev/null)" in
		*frame*|*[Ff]bcon*) printf '%s' "$_b"; return 0 ;;
		esac
	done
	return 1
}

fbcon_hold() {
	# 桌面（打开阅读器/播放器的那个进程）已经接管 fbcon 时，不要再插手：
	# 它会在 resume 之后自己 rebind，我们抢先 rebind 就又闪一次。
	[ -e /tmp/desktop-fbcon.owner ] && return 0
	_b=$(vtcon_bind) || return 0
	[ "$(cat "$_b" 2>/dev/null)" = 0 ] && return 0
	[ -w "$_b" ] || { say "提示：$_b 不可写，seek 间隙可能闪回命令行"; return 0; }
	echo 0 > "$_b" 2>/dev/null && say "fbcon 已解绑（seek 间隙不再闪回命令行）"
	return 0
}

fbcon_watch_stop() {
	_wd=/tmp/play.fbcon.wd
	_wpid=$(cat "$_wd" 2>/dev/null)
	[ -n "$_wpid" ] && kill "$_wpid" 2>/dev/null
	rm -f "$_wd" /tmp/play.fbcon.owner
	return 0
}

fbcon_release() {
	fbcon_watch_stop
	# 桌面替我们挡着（它打开阅读器/播放器时 hold 的）：由它在 resume 之后 rebind。
	# 这里抢先 rebind 会正好落在 master 空档里，命令行闪一下、HDMI 重锁存、
	# 电视弹黄条 —— 也就是老版看门狗 8s 阈值抖出来的那个现象。
	[ -e /tmp/desktop-fbcon.owner ] && { say "fbcon 由桌面接管（不在退出时 rebind）"; return 0; }
	_b=$(vtcon_bind) || return 0
	[ "$(cat "$_b" 2>/dev/null)" = 1 ] && return 0
	echo 1 > "$_b" 2>/dev/null && say "fbcon 已重新绑定（命令行恢复）"
	return 0
}

# 看门狗：播放器崩了/被 kill -9 时没人执行 stop，命令行会一直黑着。
#
# 盯的是「这次的播放会话」（play.sh 自己的 pid），不是播放器进程。
# seek/fwd 是整条链重开，播放器会消失好一阵（NAS 上缓冲时能到好几秒），
# 盯播放器就会误判成崩溃 → 把 fbcon 绑回来 → 一次 modeset → HDMI 重新
# 锁存 → 电视弹一次「当前信号信息」黄条。旧版 8s 阈值就是这么抖出黄条的。
# 会话还活着就说明它迟早自己收尾（正常退出走 fbcon_release），不用管；
# 会话真没了（kill -9/崩溃）且连播 3s 没有任何播放器，才 rebind。
#
# owner 文件负责交接：新会话起播时改写 owner 并起自己的看门狗，
# 老看门狗每秒核对一次，发现 owner 不是自己就安静退出 —— 绝不在
# 新会话已经上屏之后再手贱 rebind 一次。
fbcon_watch() {
	# 桌面接管期间不起看门狗：它自己会在 resume 之后就 rebind
	[ -e /tmp/desktop-fbcon.owner ] && return 0
	_b=$(vtcon_bind) || return 0
	[ -w "$_b" ] || return 0
	_wd=/tmp/play.fbcon.wd
	_own=/tmp/play.fbcon.owner
	_self=$$
	fbcon_watch_stop	# 上一会话的看门狗交给这一会话
	printf '%s\n' "$_self" > "$_own"
	setsid sh -c '
self='"$_self"'; bind='"$_b"'; own='"$_own"'
n=0
while :; do
	sleep 1
	[ "$(cat "$own" 2>/dev/null)" = "$self" ] || exit 0
	if kill -0 "$self" 2>/dev/null; then n=0; continue; fi
	if pgrep -x v4l2hevc-aarch6 >/dev/null 2>&1 || \
	   pgrep -x v4l2hevc >/dev/null 2>&1 || \
	   pgrep -x mpv >/dev/null 2>&1; then n=0; continue; fi
	n=$((n + 1))
	[ "$n" -ge 3 ] && { echo 1 > "$bind"; rm -f "$own"; exit 0; }
done' </dev/null >/dev/null 2>&1 &
	echo $! > "$_wd"
	return 0
}

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
	pkill -9 -f 'ffmpeg .*-f h264' 2>/dev/null
	# 音频那条独立 ffmpeg（-vn -f s16le）：漏了它，下次起播会有两路抢 fifo
	pkill -9 -f 'ffmpeg .*-f s16le' 2>/dev/null
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
	SRC_REMOTE=0
	resolve_src		# NAS 完整路径 → 带认证的 http 源（本地文件/显式 URL 原样）
	case "$SRC" in
	http://*|https://*|rtsp://*) ;;
	*) [ -f "$SRC" ] || [ -r "$SRC" ] || die "片源不存在：$SRC$(
		case "$SRC_REMOTE" in 1) echo "（NAS 地址已解析，检查 .env 的 WEBDAV_*）" ;; esac)" ;;
	esac
	[ -x "$BIN" ] || die "找不到播放器：$BIN（scp 到盒子上，或用 -B 指定）"

	case "$SS" in ''|*[!0-9.]*) die "起播秒不是数字：$SS" ;; esac
	case "$DUR" in ''|*[!0-9.]*) die "时长不是数字：$DUR" ;; esac
	case "$SS" in *.*.*) die "起播秒格式不对：$SS" ;; esac

	case "$SRC" in
	*.265|*.h265|*.hevc|*.bin) NAKED=1 ;;
	*.h264|*.264|*.avc)        NAKED=1 ;;
	*) NAKED=0 ;;
	esac

	# NAS 上读片：网络抖一下不该整条链卡死（默认 rw_timeout 是无限等）。
	# -reconnect* 只对 http 输入有意义，本地文件加上也无害。
	# 提到探测之前：下面每多探一次就多一次 http 请求，都得带超时。
	HTTP_OPT=""
	case "$SRC" in
	http://*|https://*)
		HTTP_OPT="-rw_timeout 15000000 -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 4"
		;;
	esac

	# 探测一次视频流（codec + 宽高）。$1 是额外交给 ffprobe 的输入格式。
	# 空输出 = 没有任何 demuxer 认领这个片源。
	probe_video() {
		# shellcheck disable=SC2086
		ffprobe -v error $1 $HTTP_OPT -select_streams v:0 \
			-show_entries stream=codec_name,width,height \
			-of csv=p=0 "$SRC" 2>/dev/null | head -n 1
	}

	# 编码：驱动侧两种都能硬解（meson-vdec 的 sm1/g12 表里 HEVC 和 H.264
	# 都在，固件 g12a_h264.bin 也在盒子上），但**裸流格式必须对得上**：
	# `-f hevc` 喂 H.264 会让 ffmpeg 直接 "Could not write header"，管道
	# 空着就是黑屏 + FAIL stream 空。所以先问 ffprobe 一句，再定 -f。
	# H.264 的宽高解析不了 HEVC 那套 SPS，得由这里传给播放器。
	VC=""; VW=""; VH=""; IN_FMT=""
	if [ "$NAKED" = 0 ] && command -v ffprobe >/dev/null 2>&1; then
		_pv=$(probe_video "")
		# 空 = 自动探测失败。NAS 上有一批 .mkv 其实是 MPEG-TS：自动探测先按
		# 扩展名试 matroska（EBML 解析失败），mpegts 探测又要求文件头就是
		# 0x47 同步字节 —— 有的片子开头带十几字节脏数据，两条路一起挂，
		# ffmpeg 直接 "Invalid data found when processing input" 退出，
		# 管道空转就是黑屏。强给 -f mpegts 后同步字节一扫描就对齐（实测
		# 348/348 命中），所以这里补一次带 -f mpegts 的探测。
		if [ -z "$_pv" ]; then
			_pv=$(probe_video "-f mpegts")
			case "$_pv" in
			h264,*|hevc,*)
				IN_FMT="-f mpegts"
				say "封装：MPEG-TS（扩展名不可信，自动探测失败后强探命中）" ;;
			*) _pv="" ;;
			esac
		fi
		VC=${_pv%%,*}
		_wh=${_pv#*,}
		VW=${_wh%%,*}; VH=${_wh##*,}
		case "$VC" in h264|hevc) ;; *) VC="" ;; esac
		case "$VW$VH" in ''|*[!0-9]*) VW=""; VH="" ;; esac
		# 探测彻底失败：以前是静默黑屏，现在至少说清楚
		if [ -z "$VC" ]; then
			say "警告：片源封装探测失败，按原样交给 ffmpeg（可能黑屏）"
		fi
	fi
	[ -z "$VC" ] && case "$SRC" in *.h264|*.264|*.avc) VC=h264 ;; esac
	[ -z "$VC" ] && VC=hevc
	VF=hevc; VWH=""
	[ "$VC" = h264 ] && { VF=h264; [ -n "$VW" ] && VWH="$VW $VH"; }
	say "编码：$VC（ffmpeg -f $VF）${VWH:+ ${VW}x$VH}${IN_FMT:+  输入 $IN_FMT}"
	# 帧率：播放器配速的分子是"帧号/帧率"，默认 24 是给电影留的。片源
	# 30/25/50fps 时不告诉它就慢 25%～翻倍：24fps 的假设下第 30 帧该在
	# 1.25 s 出现，实际内容里它在 1.0 s —— 画面每秒欠 5 帧，两分钟就差
	# 十秒，听感就是"音频没同步画面"。所以片源自己报多少就是多少，
	# 调用方（桌面/遥控器）不用猜，显式给了 FPS 就以它为准。
	if [ -z "$FPS" ] && [ "$NAKED" = 0 ] && command -v ffprobe >/dev/null 2>&1; then
		_rf=$(ffprobe -v error $IN_FMT $HTTP_OPT -select_streams v:0 \
			-show_entries stream=r_frame_rate -of csv=p=0 "$SRC" 2>/dev/null | head -n 1)
		case "$_rf" in
		*/1) _rf=${_rf%/1} ;;
		*/*) _rf=$(awk -v r="$_rf" 'BEGIN{split(r,a,"/"); if (a[2] > 0) printf "%.3f", a[1]/a[2]}') ;;
		esac
		case "$_rf" in ''|*[!0-9.]*|0|0.000) _rf="" ;; esac
		if [ -n "$_rf" ]; then
			FPS=$_rf
			say "帧率：${FPS}fps（片源报的，配速用）"
		fi
	fi
	# H.264 硬解这块板子是通的（实测 2026-11-19：1080p h264 解 424 帧
	# /14.4s ≈ 29.5 fps，gl 后端正常上屏）。2026-11-19 之前那句"H.264 解不出帧、
	# 只会黑屏"是误判，真因是播放器 spawn_argv 的切词上限只有 32 个 token：
	# NAS 的 reconnect 选项把模板撑到 37 个，截断点正好落在音频的 `-f s16le`，
	# argv 以孤零零的 `-f` 收尾 → ffmpeg 报 "Missing argument for option 'f'"
	# 秒退 → 播放器读到空流 → 黑屏。上限已提到 SPAWN_MAX=128（v4l2hevc.c）。
	# 所以这里不再提前喊"黑屏"，真黑了看 /tmp/play.log 的 ffmpeg 报错。
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

	# -n：只验片源解析（.env 对不对、URL 通不通），不碰屏也不杀旧实例
	if [ "$DRYRUN" = 1 ]; then
		_safe=$(printf '%s' "$SRC" | sed 's#://\([^:/@]*\):[^@]*@#://\1:***@#')
		printf '片源：%s\n' "$_safe"
		[ "$SRC_REMOTE" = 1 ] && printf '来源：NAS %s（认证取 %s）\n' "$NAS_URL" "${ENVF:-环境变量}"
		printf '播放器：%s\n' "$BIN"
		printf '编码：%s\n' "$VC"
		printf '封装：%s\n' "${IN_FMT:-自动探测}"
		printf '命令：ffmpeg -re %s%s-i "%s" -map 0:v:0 -c:v copy -f %s - | %s - %s\n' \
			"${SS:+-ss $SS }" "${IN_FMT:+$IN_FMT }" "$_safe" "$VF" "$BIN" "$VWH"
		return 0
	fi

	fbcon_hold          # 必须在 cleanup_old 之前：老实例退出那一刻就要没人来抢屏
	fbcon_watch
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
		_ha=0; _ac=""
		if command -v ffprobe >/dev/null 2>&1; then
			# shellcheck disable=SC2086
			_a=$(ffprobe -v error $IN_FMT $HTTP_OPT -select_streams a:0 \
				-show_entries stream=index,codec_name \
				-of csv=p=0 "$SRC" 2>/dev/null)
			case "$_a" in
			"") ;;
			*) _ha=1; _ac=${_a#*,} ;;   # "1,aac" -> aac
			esac
		else
			_ha=1	# 没有 ffprobe：假定有音轨，别把正常的片子搞成静音
		fi
		if [ "$_ha" = 1 ]; then
			rm -f "$AFIFO"
			mkfifo -m 600 "$AFIFO" || die "建不了 $AFIFO"
			AFIFO_USE=$AFIFO
			# 音频不再挂在视频那条 ffmpeg 上：同一个进程顺序写两路输出，
			# 视频管道一堵音频就跟着断喂（xrun 每秒一次的根因）。
			# 这里写成独立模板，播放器 fork 第二个 ffmpeg，只吃音频、只写 fifo。
			AF=""
			# 增益链：volume 补偿源本身小的电平，alimiter 只压过冲的峰。
			# level=0 关掉 alimiter 的自动抬电平（那会变成整体归一化，
			# 对白和爆炸的响度关系就乱了）。
			AFA=""
			case "$AGAIN" in
			""|0|0.0|-*) ;;
			*) AFA="-af volume=${AGAIN}dB,alimiter=limit=0.97:level=0:attack=5:release=50" ;;
			esac
			# -drc_scale 是**输入**选项（作用在解码器上），必须排在 -i 前面：
			# 放到 -i 后面会被当成输出选项，ffmpeg 直接报参数错退出，
			# 表现是音频子进程一起就 defunct、整片静音。
			# 它只对 ac3/eac3/truehd/dts 有意义（dialnorm/DRC 会把整条轨压低
			# 好几 dB），对 aac/pcm 挂上去只会换来一句 "has not been used"。
			AFI=""
			case "$_ac" in
			ac3|eac3|truehd|mlp|dts|dca)
				[ "$DRC" = 1 ] && AFI="-drc_scale 1" || AFI="-drc_scale 0" ;;
			esac
			AUDIO_SPAWN="ffmpeg -hide_banner -loglevel warning -nostdin -y -re -ss {SS} $DA $AFI $HTTP_OPT $IN_FMT -i $SRC -vn -map 0:a:0 $AFA -f s16le -ar 48000 -ac 2 $AFIFO"
		else
			say "片源没有音轨，只放画面"
			# 电视上看不见终端：屏幕上也得说一句，否则"按音量键没反应"，
			# 用户会以为遥控器坏了（其实是没音轨，音量本就无处可调）。
			PLAY_OSD="${PLAY_OSD:+$PLAY_OSD  ·  }无音轨 只放画面"
			export PLAY_OSD
		fi
	fi

	# 内层交给 sh 展开：路径里有空格也不会被拆开。
	# set -f：关掉通配，$AF 里的 `0:a:0` 之类不会被当 glob 展开。
	# AUDIO_FIFO 直接 export：写成 `${X:+AUDIO_FIFO=...}` 那个赋值不会生效，
	# 展开出来的是一个「命令名」，报 AUDIO_FIFO=/tmp/play.afifo: not found。
	# 桌面的 run.sh 会 export LD_PRELOAD=/opt/desktop/lib/kmsflip.so（把
	# drmModeSetCrtc 降级成 PageFlip，免得电视弹信号条）。那个 shim 只对桌面
	# 成立，却会被 play.sh 原样继承给播放器：播放器的 SetCrtc 兜底也被改成
	# PageFlip，失败后 shim 直接丢帧不回落 → CRTC 上的 pending flip 永远没人
	# 收尾 → 之后每帧 PageFlip 都 -EBUSY。表现就是上屏 1fps、解码器下游堵住、
	# 音频线程跟着饿出 xrun（听感 = 没声音）。播放器自己管 DRM，这里必须清掉。
	unset LD_PRELOAD KMSFLIP KMSFLIP_LOG

	export SRC SS DUR DA NAKED BIN LOG RENDER SCALE AFIFO_USE SOCK AUDIO HTTP_OPT
	export VC VF VWH IN_FMT CODEC=""
	[ "$VC" = h264 ] && CODEC=h264
	export CODEC
	if [ -n "$AFIFO_USE" ]; then export AUDIO_FIFO="$AFIFO_USE"; else unset AUDIO_FIFO; fi
	export AUDIO_BUF AUDIO_PERIOD

	# 声卡没加载就等于彻底没声音：axg-sound-card 是 =m，开机没人 modprobe，
	# 播放器只会打一行 "AUDIO: 声卡打不开" 然后只放画面（2026-11-19 重启后
	# /proc/asound/cards 是空的，就是这么哑掉的）。这里兜一下，别静默。
	if [ "$AUDIO" = 1 ]; then
		_i=0
		while [ ! -e /proc/asound/card0 ] && [ "$_i" -lt 15 ]; do
			[ "$_i" = 0 ] && modprobe snd_soc_meson_axg_sound_card 2>/dev/null
			_i=$((_i + 1)); sleep 0.2
		done
		[ -e /proc/asound/card0 ] || say "警告：声卡没起来（modprobe axg_sound_card 失败），只放画面"
	fi
	[ -n "$FPS" ] && export FPS
	[ -n "$LEAD" ] && export LEAD
	[ -n "$DITHER" ] && export TMDITHER="$DITHER"
	export AF
	[ -n "${AUDIO_SPAWN:-}" ] && export AUDIO_SPAWN

	# ── spawn 模式：ffmpeg 收成播放器的子进程（design §5.4、§6.2）──
	# 只有 spawn 才谈得上这三件事（都是实测过、不是推测）：
	#   ① seek 就地跳：kill 子进程 + 新 -ss 重开 + L2 重建会话，
	#      DRM/GL 不放手 → 屏幕不黑，buffer 不重建；
	#   ② 供流饿死自愈（STARVESEC）：ffmpeg 活着但不吐字节时能就地重连；
	#   ③ 片尾/上游死能分开：EOF 后 waitpid 得到 ffmpeg 的退出码。
	# 模板按空白切词后 execvp 直接起（不过 shell），所以：
	#   - 片源/fifo 路径里不能有空白（含空格就退回管道模式）；
	#   - 不能靠重定向，stderr 直接继承播放器的（外层已 >>"$LOG"）。
	# 上游死（播放器 exit 3）后壳要重连，位置只能靠播放器落的这个文件：
	# 控制口 socket 随进程一起消失，问不到 pos()。
	POSFILE=${POSFILE:-${STATE}.pos}
	export POSFILE
	rm -f "$POSFILE" 2>/dev/null

	SPAWNED=0
	if [ "$NAKED" = 0 ] && [ "${OPIPE:-0}" != 1 ]; then
		case "$SRC$AFIFO_USE" in
		*[[:space:]]*)
			say "片源/fifo 路径含空格：退回管道模式（spawn 模板不分词）" ;;
		*)
			export SPAWN="ffmpeg -hide_banner -loglevel warning -nostdin -y -re -ss {SS} $DA $HTTP_OPT $IN_FMT -i $SRC -map 0:v:0 -c:v copy -f $VF -"
			export SS DUR
			SPAWNED=1 ;;
		esac
	fi
	[ "$SPAWNED" = 1 ] && say "链路：spawn（ffmpeg 是播放器的子进程，seek 就地跳）"

	# 壳侧重连（design §1.6 剩的那条）：spawn 模式下播放器能拿到 ffmpeg 的
	# 退出码，非 0 就 exit 3；这里读到 3 就拿播放器落下的 POSFILE 当新 -ss
	# 整条链重开——片尾（ffmpeg 正常收尾，exit 0）不会走到这里。
	# 连续 3 次还死就放弃，不然网络彻底断了会原地空转。
	RECONNECT_MAX=${RECONNECT_MAX:-3}
	if [ "$SPAWNED" = 1 ]; then
		set -- 'rc=0; _try=0
while :; do
	PLAY=1 NOWRITE=1 RENDER="$RENDER" SCALE="$SCALE" PLAY_SOCK="$SOCK" \
		"$BIN" - '"$VWH"' >>"$LOG" 2>&1
	rc=$?
	[ "$rc" = 3 ] || break
	_try=$((_try + 1))
	if [ "$_try" -gt '"$RECONNECT_MAX"' ]; then
		echo "UPSTREAM: 连续 $_try 次上游死，放弃重连" >>"$LOG"
		break
	fi
	_p=$(cat "$POSFILE" 2>/dev/null | tr -d " ")
	case "$_p" in ""|*[!0-9.]*) _p=$SS ;; esac
	SS=$_p
	echo "UPSTREAM: 壳就地重连，从 ${SS}s 重开（第 $_try 次）" >>"$LOG"
	sed -i "s/^SS=.*/SS=$SS/" "'"$STATE"'"
	sleep 0.3
done
exit $rc'
	else
		set -- 'set -uf
if [ "$NAKED" = 1 ]; then
	cat "$SRC"
else
	ffmpeg -hide_banner -loglevel warning -nostdin -y -re \
		${SS:+-ss "$SS"} $DA $HTTP_OPT $IN_FMT \
		-i "$SRC" -map 0:v:0 -c:v copy -f "$VF" - $AF 2>>"$LOG"
fi | PLAY=1 NOWRITE=1 RENDER="$RENDER" SCALE="$SCALE" PLAY_SOCK="$SOCK" \
	"$BIN" - $VWH >>"$LOG" 2>&1'
	fi

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
	umask 077	# state 里存着带凭据的源地址（SRCB64），别人别读
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
	# 上屏判据只认渲染器握手的这两行，别靠"屏幕亮了没"：
	#   RENDER: gl (caps hdr)            ← 后端初始化完立刻打，1.5s 时必有
	#   RENDER: mode=gles tonemap=… src= ← 首帧配置完打
	# PLAY: renderer= 是播完才出的收尾统计，拿它当判据必然误报（老版本的
	# PLAY: plane= 更是早就不打了）。三者都认，只为兼容旧二进制。
	if grep -qE '^RENDER: [A-Za-z0-9_]+ \(caps|^RENDER: mode=|^PLAY: (plane=|renderer=|submit=)' "$LOG" 2>/dev/null; then
		grep -m2 -E '^RENDER: ([A-Za-z0-9_]+ \(caps|mode=)' "$LOG" | sed 's/^RENDER: /  /'
		grep -m1 -E '^PLAY: ' "$LOG" | sed 's/^PLAY: /  /'
	else
		say "警告：日志里没有 RENDER: <后端> (caps …) 行，渲染器没起来，可能没上屏"
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
	PCTL_ECHO=1 PLAY_SOCK="$SOCK" "$BIN" -c "$@" 2>/dev/null
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
	fbcon_release        # 停止后把命令行还给人
	say "已停止"
}

# 当前位置（秒）：心跳的 t= 是「进程启动后过了多少秒」，不含起播偏移，
# 加回 SS 才是片源位置；它比墙钟准（暂停/卡顿期间不跑偏），有就用它。
pos_of() {
	load_state || return 1
	# 优先问播放器要实时位置：HB 心跳 10s 一条，靠它算位置会一格跳 10 秒，
	# 遥控器连按时"位置没变"的观感就是这么来的。pos_ms 是音频主钟推出来的
	# 播放时间轴，而且是**绝对**的（播放器把时钟原点挪到了 -SS：
	# `g_t_clock0 = t_play0 - g_ss0`），这里再加 SS 就是双算——起播 40s
	# 会被显示成 80s。下面靠 HB 的 t= 是相对量，才需要补 SS。
	_tm=$(pctl pos | sed -n 's/.*"pos_ms":\([0-9]*\).*/\1/p')
	case "${_tm:-}" in
	'') ;;
	*) awk -v m="$_tm" -v o="${SS:-0}" -v d="${DUR:-0}" 'BEGIN{
	       p = int(m / 1000)
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

# ── 遥控键位表 ──────────────────────────────────────────────
# 键码 → 动作只有一处定义：播放器源码里的 rcmap.h。脚本不抄表，
# 运行时用 `player -K` 问播放器要（二进制里编进去的就是同一份）。
keys() {
	[ -x "$BIN" ] || { say "找不到播放器 $BIN，列不出键位表"; return 1; }
	"$BIN" -K
}

# 表里出现过的动作名（去重，保持首次出现顺序）
actions() {
	keys 2>/dev/null | awk -F'\t' '!/^#/ && NF>=3 && !seen[$3]++ {print $3}'
}

# ── 遥控器动作（按一次键 exec 一次本脚本）────────────────────
# 动作名与 rcmap.h 里的动作一致：
#   toggle 暂停/继续        fwd/back ±10s     fwdmore/backmore ±60s
#   volup/voldn ±10         mute 静音          quit 停播
# 视频这条链没有 IPC，seek 只能整条重开（约 1s 黑屏），所以：
#   ① 重开参数全从 state 取（SRC/SOCK/AUDIO/RENDER/SCALE/FPS）；
#   ② 3s 内的重复 seek 直接丢弃 —— 按住 ▶ 的连发会在松开后逐个补跑，
#      表现就是「按一下，画面消失半天」。
# 秒 → 屏幕上的位置：>1h 给 h:mm:ss，否则 mm:ss
fmt_pos() {
	_t=${1:-0}
	case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
	_h=$((_t / 3600)); _m=$(((_t % 3600) / 60)); _s=$((_t % 60))
	if [ "$_h" -gt 0 ]; then
		printf '%d:%02d:%02d' "$_h" "$_m" "$_s"
	else
		printf '%02d:%02d' "$_m" "$_s"
	fi
}

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

# 就地跳（design §5.4）：spawn 模式下 ffmpeg 是播放器的子进程，播放器自己
# 能 kill 它、带新 -ss 重开、顺手重建 V4L2 会话 —— DRM/GL 一路不放手，屏幕
# 不黑、buffer 不重建。控制口直接接住就别重开整条链（返回 0 = 已接管）。
# 接不住（非 spawn 模式、老二进制、socket 不通）返回 1，调用方退回整链重开。
seek_inplace() {
	_r=$(pctl "$1" "$2" 2>/dev/null) || return 1
	case "$_r" in
	*'"seek":"abs"'*|*'"seek":"inplace"'*) return 0 ;;
	esac
	return 1
}

# 音量只能在播放器里做（软件增益）：这块板的 ALSA 没有可写的主音量
# （ACODEC 不存在，只有 SPDIF/TDM 的通道音量，动它就是动别的输出路径；
#  TDMOUT_B 那四路 Lane 实测已经都在 100%，硬件侧没有余量了）。
# 所以两层：起播时 ffmpeg 补 AGAIN dB（对全片恒定的电平补偿），遥控器
# 的 ±10 再在播放器里做 0..200 的线性增益（>100 会削波，临时救急用）。
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
	seekto:*)
		# 绝对跳（pctl 把 "seekto 秒" / "seek 0" 转成这个）：整链重开，
		# 目标就是给的秒数，不再拿当前 pos 相加。
		T=${ACT#*:}
		case "$T" in ''|*[!0-9]*) say "seekto 参数不对：$ACT"; return 1 ;; esac
		[ "$T" -lt 0 ] && T=0
		P=$(pos_of); [ -n "$P" ] || P=0
		_r=0
		if [ "${DUR:-0}" -gt 0 ]; then
			[ "$T" -ge "$DUR" ] && T=$((DUR - 1))
			_r=$((DUR - (T - SS))); [ "$_r" -le 0 ] && _r=$DUR
		fi
		if seek_inplace seekto "$T"; then
			say "跳到 ${T}s（绝对，原 ${P}s，就地跳，屏幕不黑）"
			return 0
		fi
		seek_guard || return 0
		_WAS=0; is_paused && _WAS=1
		say "跳到 ${T}s（绝对，原 ${P}s）"
		SRC=$(dec "${SRCB64:-}")
		[ -n "$SRC" ] || { say "state 里没有片源，无法重开"; return 1; }
		PLAY_OSD="位置 $(fmt_pos "$T")"
		export PLAY_OSD
		setsid sh "$0" -d -a "${AUDIO:-1}" -r "${RENDER:-gl}" -s "${SCALE:-fit}" \
			${FPS:+-f "$FPS"} -B "$BIN" \
			"$SRC" "$T" "$_r" >/dev/null 2>&1 </dev/null
		if [ "$_WAS" = 1 ]; then sleep 0.5; load_state && do_pause; fi
		;;
	fwd|back|fwdmore|backmore|fwd:*|back:*)
		# 也认「fwd:<秒>」「back:<秒>」这种带秒数的形式（pctl 的 seek N 转出来）：
		# 播放器没有 IPC，seek 只能整链重开，秒数由调用方给，档位别写死在两档。
		case "$ACT" in
		fwd) D=10 ;; back) D=-10 ;; fwdmore) D=60 ;; backmore) D=-60 ;;
		fwd:*)  D=${ACT#*:}; case "$D" in ''|*[!0-9]*) D=10 ;; esac ;;
		back:*) D=${ACT#*:}; case "$D" in ''|*[!0-9]*) D=10 ;; esac; D=$((0 - D)) ;;
		esac
		P=$(pos_of); [ -n "$P" ] || P=0
		T=$((P + D)); [ "$T" -lt 0 ] && T=0
		# 已播时长：有 DUR 就只放剩下的，别让"±10s"变成"循环到结尾"
		_r=0
		if [ "${DUR:-0}" -gt 0 ]; then
			_r=$((DUR - (T - SS))); [ "$_r" -le 0 ] && _r=$DUR
		fi
		# 偏移量交给播放器算：它有连续 seek 的基准链（末次目标），
		# 这里用 pos_of() 的旧位置起算会连按跳错。
		if seek_inplace seek "$D"; then
			say "跳 ${D}s（就地跳，屏幕不黑）"
			return 0
		fi
		seek_guard || return 0
		_WAS=0; is_paused && _WAS=1
		say "跳到 ${T}s（原 ${P}s，偏移 $D）"
		SRC=$(dec "${SRCB64:-}")
		[ -n "$SRC" ] || { say "state 里没有片源，无法重开"; return 1; }
		# 新实例起来先报一句"跳到哪儿了"：seek 期间屏幕黑 ~1s，
		# 没有这句用户分不清"按上了"和"没反应"。
		PLAY_OSD="位置 $(fmt_pos "$T")"
		export PLAY_OSD
		setsid sh "$0" -d -a "${AUDIO:-1}" -r "${RENDER:-gl}" -s "${SCALE:-fit}" \
			${FPS:+-f "$FPS"} -B "$BIN" \
			"$SRC" "$T" "$_r" >/dev/null 2>&1 </dev/null
		# 暂停中拖动：重开后再压回去，保持"暂停"语义
		if [ "$_WAS" = 1 ]; then sleep 0.5; load_state && do_pause; fi
		;;
	menu|home) say "动作 $ACT：没有 UI，忽略" ;;
	*) say "遥控器：未知动作 $ACT（可用：$(actions | tr '\n' ' ')）"; return 1 ;;
	esac
	return 0
}

# ── 参数 ─────────────────────────────────────────────────────
[ $# -gt 0 ] || { usage; exit 1; }

case "$1" in
pause|resume|stop|status|log|key|keys)
	_act=$1; shift
	case "$_act" in
	pause)  do_pause  ;;
	resume) do_resume ;;
	stop)   do_stop   ;;
	status) do_status ;;
	log)    load_state >/dev/null 2>&1; exec tail -f "${LOGF:-$LOG}" ;;
	key)    do_key "${1:-}" ;;
	keys)   keys ;;
	esac
	exit 0
	;;
esac

BACKGROUND=0
while getopts 'r:s:f:a:B:dnvHh' _o 2>/dev/null; do
	case "$_o" in
	r) RENDER=$OPTARG ;;
	s) SCALE=$OPTARG  ;;
	f) FPS=$OPTARG    ;;
	a) AUDIO=$OPTARG  ;;
	B) BIN=$OPTARG    ;;
	n) DRYRUN=1       ;;	# 只解析片源，不播
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
[ "$DRYRUN" = 1 ] && exit 0     # -n 只看解析结果，没有进程要等

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

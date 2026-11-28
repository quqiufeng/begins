#!/bin/sh
# /root/music.sh — 全屏音乐播放器（桌面「音乐」图标调它）
#
# 流程（用户 2026-11-28 定的顺序，别改回去）：
#   1) 按配置的曲库目录扫一遍 NAS，把歌单写到 /root（默认 /root/music.m3u）
#   2) 再起 mpv：独占 DRM 直出显示器，音频走 USB 声卡
# mpv 出图是频谱条 + 左上角播放列表 OSD（pl-osd.lua）；遥控由 keybd 的
# apps/music.lua 走下面的 IPC 控制口，不靠 evdev 抢设备：
#   OK=播放/暂停  左右=上一首/下一首  音量±  静音  返回=退出（桌面自动回来）
#
# 环境变量（都可覆盖，调试用）：
#   MUSIC_DIR      曲库目录，默认 dav://192.168.1.53:5005/sata11-18072858035/mp3/无损
#                  （也认 /sata11-... 纯路径和 http://host:port/path）
#   MUSIC_PLAYLIST 歌单落点，默认 /root/music.m3u
#   MUSIC_REGEN    0=直接用现成歌单，不重扫（默认 1=每次都重扫）
#   MUSIC_SOCK     控制口，默认 /tmp/m.sock（要和 keybd apps/music.lua 一致）
#   MUSIC_AO       ALSA 设备，默认 alsa/plughw:CARD=LC2100,DEV=0（USB 声卡）
#   MUSIC_VOL      初始音量，默认 50
set -u

DIR=${MUSIC_DIR:-dav://192.168.1.53:5005/sata11-18072858035/mp3/无损}
# 歌单生成器是 LuaJIT + libcurl FFI（复用桌面 core/dav.lua），不需要 python3
LUAJIT=${MUSIC_LUA:-${LUAJIT:-}}
if [ -z "$LUAJIT" ]; then
	for c in /usr/local/bin/luajit /opt/desktop/bin/luajit /opt/reader/bin/luajit /usr/bin/luajit; do
		[ -x "$c" ] && LUAJIT=$c && break
	done
fi
LIST=${MUSIC_PLAYLIST:-/root/music.m3u}
GEN=${MUSIC_GEN:-/root/gen-music-playlist.lua}
SOCK=${MUSIC_SOCK:-/tmp/m.sock}
DEV=${MUSIC_AO:-alsa/plughw:CARD=LC2100,DEV=0}
VOL=${MUSIC_VOL:-50}

# 凭据：mpv 自己不读 .env，这里补给它（歌单里不留密码）
[ -f /root/.env ] && . /root/.env 2>/dev/null || true

say() { echo "music.sh: $*" >&2; }

# 上一轮留下的 socket：mpv 启动时自己会 unlink，别提前删（可能正在播）
rm -f "$SOCK.stale" 2>/dev/null || true

# ---- 1) 先生成歌单，落盘到 /root ----
if [ "${MUSIC_REGEN:-1}" != 0 ] && [ -f "$GEN" ] && [ -n "$LUAJIT" ]; then
	TMP="$LIST.tmp.$$"
	if "$LUAJIT" "$GEN" "$DIR" >"$TMP" 2>/tmp/music-gen.err; then
		mv -f "$TMP" "$LIST"
		chmod 600 "$LIST" 2>/dev/null || true
		say "歌单已更新：$LIST（$(($(wc -l <"$LIST") - 1)) 首）"
	else
		rm -f "$TMP"
		say "歌单生成失败（$DIR），看 /tmp/music-gen.err；沿用旧歌单"
	fi
elif [ -z "$LUAJIT" ]; then
	say "找不到 luajit，跳过重扫歌单（用现成的 $LIST）"
fi

if [ ! -s "$LIST" ]; then
	echo "music.sh: 歌单不存在或为空：$LIST" >&2
	exit 1
fi

# ---- 2) 起 mpv：DRM 直出 + USB 出声 ----
# 频谱：音频流 asplit 出视觉支路 → showfreqs 画 640x360 → 屏幕放大到 1440p
LAVFI='[aid1]asplit[ao][vv];[vv]showfreqs=s=640x360:mode=bar:ascale=log:fscale=log,format=yuv420p,fps=6[vo]'

AUTH=""
if [ -n "${WEBDAV_USER:-}" ]; then
	AUTH="Authorization: Basic $(printf '%s:%s' "$WEBDAV_USER" "${WEBDAV_PASS:-}" | base64 -w0)"
fi

exec mpv --no-config --vo=gpu --gpu-context=drm --fs --osc=no \
	--ao=alsa --audio-device="$DEV" --volume="$VOL" \
	--http-header-fields="$AUTH" \
	--lavfi-complex="$LAVFI" \
	--osd-level=0 --osd-font="${OSD_FONT:-TsangerJinKai02}" \
	--script=/root/pl-osd.lua \
	--playlist="$LIST" --shuffle --loop-playlist=inf \
	--cache=yes --cache-secs=60 \
	--input-ipc-server="$SOCK"

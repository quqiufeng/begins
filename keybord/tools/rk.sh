#!/bin/bash
# rk.sh — 按遥控器键（走盒子上的 keybd socket），随后截图回本地
#
#   ./rk.sh down ok ok            # 依次按 down、ok、ok
#   ./rk.sh down x3               # down 按 3 次
#   ./rk.sh --no-shot down ok     # 只按键，不截图
#   HOST=192.168.1.121 PORT=22 ./rk.sh ok
#
# 截图落在 $OUT（默认 /tmp/r/last.png），走 reader 的 app.capture（与真机同一条路径）。
set -u

HOST=${HOST:-192.168.1.121}
PORT=${PORT:-22}
LUAJIT=${LUAJIT:-/opt/reader/bin/luajit}   # 系统 luajit deb 已卸载
DEST=${DEST:-/opt/keybord}
OUT=${OUT:-/tmp/r/last.png}
SHOT=1

while [ $# -gt 0 ] && [[ $1 == --* ]]; do
	case $1 in
	--no-shot) SHOT=0 ;;
	*) echo "未知选项: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ $# -eq 0 ]; then
	sed -n '2,10p' "$0" >&2
	exit 2
fi

H=root@$HOST
mkdir -p "$(dirname "$OUT")"

# 盒子上跑一小段 lua：把一条 key 请求丢给 keybd.sock
keyreq() {
	timeout 15 ssh -n -p "$PORT" "$H" \
		"cd $DEST && $LUAJIT -e 'local s=require(\"sock\"); print(s.req(\"/tmp/keybd.sock\", [[{\"cmd\":\"key\",\"name\":\"$1\"}]], 4000))'"
}

while [ $# -gt 0 ]; do
	k=$1; shift
	n=1
	if [ $# -gt 0 ] && [[ $1 == x* ]]; then n=${1#x}; shift; fi
	for ((i = 0; i < n; i++)); do
		keyreq "$k" | sed "s/^/  [$k] /"
		sleep 0.2
	done
done

[ "$SHOT" = 0 ] && exit 0

timeout 20 ssh -n -p "$PORT" "$H" \
	"cd $DEST && $LUAJIT -e 'local a=require(\"apps.reader\"); local s=require(\"sock\"); print(s.req(a.socket, [[{\"cmd\":\"call\",\"fn\":\"app.capture\",\"args\":{\"path\":\"/tmp/r0.png\"}}]], 6000))'" >/dev/null

if timeout 20 scp -q -P "$PORT" "$H:/tmp/r0.png" "$OUT"; then
	echo "shot -> $OUT"
else
	echo "截图失败（$H:/tmp/r0.png 没取到）" >&2
	exit 1
fi

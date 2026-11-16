#!/bin/sh
# 本地测试用：从 60s 起播（v5 架构）
N=/tmp/tvplay-node.sh
b64() { printf '%s' "$1" | base64 -w0; }
U=$(sed -n 's/^KEYB64=//p' /tmp/tvplay.state)
setsid nohup sh "$N" play "$(b64 hw)" "$U" "$(b64 60)" "$(b64 1)" "$(b64 1)" \
  "$(b64 23.976)" "$(b64 2560x1440)" >/tmp/play.out 2>&1 </dev/null &
sleep 7
echo "=== 进程 ==="
ps w | grep -E 'v4l2hevc-gl|ffmpeg -hide|sleep 999999999' | grep -v grep | cut -c1-110
echo "=== fifo ==="
ls -l /tmp/tvplay.vfifo
echo "=== 哑写者持有的 fd ==="
for p in $(pgrep -f 'sleep 999999999'); do
	echo -n "pid $p: "; ls -l /proc/$p/fd/9 2>/dev/null | sed 's/.*-> //'
done
echo "=== 解码器 pid ==="
pgrep -f v4l2hevc-gl
echo "=== 位置 ==="
sh "$N" state | cut -d' ' -f1-3
echo "=== log 尾部 ==="
tail -12 /tmp/tvplay.log

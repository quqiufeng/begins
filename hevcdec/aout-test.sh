#!/bin/sh
# aout-test.sh — 在盒子上验收 aout：出声、位置、音量、暂停、xrun、漂移。
#   ./aout-test.sh [秒数]
# 前提：声卡空闲（mpv/v4l2hevc 都别占）。TONE 不存在就自己生成。
set -u
SECS=${1:-8}
TONE=${TONE:-/tmp/tone48k.raw}
AOUT=${AOUT:-/tmp/aout-aarch64}
CTL=${CTL:-/tmp/aoutctl-aarch64}

if [ ! -f "$TONE" ]; then
	echo "缺 $TONE（48k/2ch/s16le 的原始 PCM），先造一个再跑" >&2
	exit 1
fi
if pgrep -f "mpv --no-config" >/dev/null 2>&1; then
	echo "mpv 还占着 hw:0,0，先停掉" >&2
	exit 1
fi

echo "== 1. 起播（buffer/period 用默认 170/43 ms）=="
$AOUT < "$TONE" 2>/tmp/aout.err &
APID=$!
sleep 1.5
cat /tmp/aout.err
$CTL status

echo
echo "== 2. 音量：连按 6 次 -5（§1.12 的 mpvctl 在这里会丢）=="
i=0
while [ $i -lt 6 ]; do $CTL vol -5 >/dev/null; i=$((i+1)); done
$CTL status | tr ',' '\n' | grep '"vol"'
$CTL vol 100 >/dev/null

echo
echo "== 3. 暂停 2 秒：位置应冻住、xrun 不涨 =="
$CTL pause >/dev/null
P1=$($CTL status | sed 's/.*"played_ms":\([0-9]*\).*/\1/')
sleep 2
P2=$($CTL status | sed 's/.*"played_ms":\([0-9]*\).*/\1/')
X=$($CTL status | sed 's/.*"xrun":\([0-9]*\).*/\1/')
echo "暂停前 ${P1} ms / 暂停 2s 后 ${P2} ms / xrun=$X"
$CTL resume >/dev/null

echo
echo "== 4. 播完统计（应 ≈ $SECS 秒、xrun 少、差 <1%）=="
wait $APID
cat /tmp/aout.err
echo "退出码=$?"

echo
echo "== 5. 空输入立即 EOF 不应留 socket =="
ls -l /tmp/aout.sock 2>&1 | tail -1

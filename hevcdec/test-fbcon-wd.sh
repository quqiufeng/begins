#!/bin/sh
# fbcon 看门狗回归测试：全部在沙箱里跑（假 bind 文件 + 假 pgrep），
# 不碰真的 /sys/class/vtconsole，也不影响正在播放的会话。
set -u
T=/tmp/t; mkdir -p "$T/bin"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-/root/play.sh}
BIND=$T/fake-bind
echo 0 > "$BIND"

# 假 pgrep：永远"没找到播放器"，这样测的就纯粹是会话存活判定
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pgrep"; chmod +x "$T/bin/pgrep"
export PATH=$T/bin:$PATH

sed -n '/^vtcon_bind()/,/^}/p;/^fbcon_hold()/,/^}/p;/^fbcon_watch_stop()/,/^}/p;/^fbcon_release()/,/^}/p;/^fbcon_watch()/,/^}/p' "$SRC" > "$T/lib.sh"
grep -q 'fbcon_watch_stop' "$T/lib.sh" || { echo "FAIL: 抽不出函数"; exit 1; }

# 起一个"播放会话"：源入 lib，用假 bind，然后 hold+watch 并存活 $1 秒
session() {
	# 注意重定向：否则后台会话继承命令替换的管道，$(...) 会一直等它退出
	sh -c '. '"$T"'/lib.sh; vtcon_bind() { echo '"$BIND"'; }; say() { :; }; fbcon_hold; fbcon_watch; sleep '"$1"'' </dev/null >/dev/null 2>&1 &
	echo $!
}

pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS $1 (bind=$2)"; pass=$((pass+1)); else echo "  FAIL $1 期望 $3 实得 $2"; fail=$((fail+1)); fi; }

echo "T1 会话活着 + 播放器不在（模拟长时间 seek 缓冲）→ 不许 rebind"
echo 0 > "$BIND"
S=$(session 30); sleep 6      # 查的时候会话必须还活着，别让检查拖到它死之后
chk T1 "$(cat "$BIND")" 0
kill "$S" 2>/dev/null; wait "$S" 2>/dev/null
rm -f /tmp/play.fbcon.wd /tmp/play.fbcon.owner

echo "T2 会话被 kill -9 + 无播放器 → 3s 内 rebind"
echo 0 > "$BIND"
S=$(session 60); sleep 2
kill -9 "$S" 2>/dev/null; sleep 5
chk T2 "$(cat "$BIND")" 1
rm -f /tmp/play.fbcon.wd /tmp/play.fbcon.owner

echo "T3 新会话接管（老会话死掉）→ 老看门狗退出，不许 rebind"
echo 0 > "$BIND"
SA=$(session 3); sleep 1
SB=$(session 30); sleep 7     # A 早已死透，B 仍活着且已接管 owner
chk T3 "$(cat "$BIND")" 0
kill "$SB" 2>/dev/null; wait "$SB" 2>/dev/null

echo "T4 正常退出走 fbcon_release → bind=1 且看门狗被清掉"
echo 0 > "$BIND"
sh -c '. '"$T"'/lib.sh; vtcon_bind() { echo '"$BIND"'; }; say() { :; }; fbcon_hold; fbcon_watch; fbcon_release'
chk T4 "$(cat "$BIND")" 1
[ -f /tmp/play.fbcon.wd ] && { echo "  FAIL T4b 看门狗残留"; fail=$((fail+1)); } || { echo "  PASS T4b 看门狗已清理"; pass=$((pass+1)); }

rm -f "$BIND" /tmp/play.fbcon.wd /tmp/play.fbcon.owner
echo "结果：$pass 通过 / $fail 失败"
[ "$fail" = 0 ]

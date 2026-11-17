#!/bin/sh
# deploy.sh — 编译 + 推盒子 + 拉起守护，一条命令到底
#
#   ./deploy.sh                    # make CROSS=1（播放器 + rcd）→ 推 → 重启 rcinputd
#   ./deploy.sh -n                 # 跳过编译，只推现有 *_aarch64（老行为）
#   ./deploy.sh -p 片子 [秒]       # 推完直接开播（带声音）
#   ./deploy.sh -p 片子 -s 1200    # 同上，指定起播秒
#
# 为什么编译放这里：BINS 里的二进制少了/旧了，脚本原来只会喊「先 make」，
# 然后你还是得自己敲两条 make。现在默认就编，编不过直接停，不会推半套上去。
#
# 为什么要落两份：/tmp 重启即空（这就是「遥控器第二天失灵」的根因），
# 所以同步一份到 /root/rcup，开机由 rcup-start.sh 补回 /tmp。
set -u
BOX=${BOX:-x96}
DIR=$(cd "$(dirname "$0")" && pwd)
# 声音已经并进播放器（aout.c 用 -DAOUT_EMBED 编进 v4l2hevc），
# mpv/mpvctl 都不再参与播放链路，从清单里去掉：少推 1MB，也少一层误判。
BINS="v4l2hevc-aarch64 rcinputd-aarch64"
# 只推「开机链路真正用到」的两个：play.sh（rcinputd 按键回调）
# + rcup-start.sh（x96-rc.service 开机还原 /tmp 并拉起 rcinputd）。
# tvplay-node.sh 是老链路，rc-up.sh 自己都写着已下线 → 不再推。
SCRIPTS="play.sh rcup-start.sh"

PLAY=0; SRC=; SS=0; BUILD=1
while getopts 'np:s:h' _o 2>/dev/null; do
	case "$_o" in
	n) BUILD=0 ;;
	p) PLAY=1; SRC=$OPTARG ;;
	s) SS=$OPTARG ;;
	h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] && [ "$PLAY" = 0 ] && { SRC=$1; PLAY=1; SS=${2:-0}; }

say() { echo "deploy: $*"; }

cd "$DIR" || exit 1

# ---------------------------------------------------------------- 1) 编译
if [ "$BUILD" = 1 ]; then
	command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
		say "缺交叉编译器 aarch64-linux-gnu-gcc（apt install gcc-aarch64-linux-gnu）"
		say "只想推现有二进制就加 -n"
		exit 1
	}
	say "编译播放器 → make CROSS=1"
	make CROSS=1 || { say "播放器编译失败，已中止（盒子上什么都没动）"; exit 1; }
	# 不编 aout：它不在 BINS 里（见文件头注释）。要单独测就手动 make CROSS=1 aout。
	say "编译 rcinputd → make CROSS=1 rcd"
	make CROSS=1 rcd || { say "rcinputd 编译失败，已中止（盒子上什么都没动）"; exit 1; }
else
	say "跳过编译（-n），直接推现有二进制"
fi

for f in $BINS $SCRIPTS; do
	[ -f "$DIR/$f" ] || { say "缺文件 $f（先 make CROSS=1 && make CROSS=1 rcd）"; exit 1; }
done

say "产物：$(cd "$DIR" && md5sum $BINS | awk '{printf "%s=%s ", substr($1,1,8), $2}')"

# ------------------------------------------------------- 2) 停守护 + 推文件
# scp 是 open(O_WRONLY|O_TRUNC)，对着「正在执行的二进制」会 ETXTBSY（报 "Failure"）。
# 两个对策，按被打扰的代价分：
#   rcinputd  → 直接停掉（它没有状态，rcup-start.sh -r 会拉起来）
#   播放器    → 只 rm -f 不 kill：unlink 掉文件名，运行中的进程继续用旧 inode 放，
#                scp 建新文件，画面声音一条不断，下次 seek 重开自然用上新二进制。
# 停守护只能用「comm 匹配」：pkill -f 的模式串出现在远端 bash -c 自己的命令行里，
# 会把这个 ssh 会话自己杀掉（rm 根本没轮到执行，scp 接着报 Failure）。
ssh "$BOX" 'pkill -x rcinputd-aarch6 2>/dev/null
sleep 0.2
rm -f /tmp/v4l2hevc-aarch64 /tmp/mpvctl-aarch64 /tmp/rcinputd-aarch64
ls /tmp/*-aarch64 2>/dev/null
exit 0'

say "推文件 → $BOX:/tmp"
scp -q $(
	for f in $BINS $SCRIPTS; do printf '%s ' "$DIR/$f"; done
) "$BOX:/tmp/" || exit 1

# ------------------------------------------------ 3) 持久副本 + 重启守护
ssh "$BOX" 'set -u
chmod +x /tmp/v4l2hevc-aarch64 /tmp/rcinputd-aarch64 \
          /tmp/play.sh /tmp/rcup-start.sh
# 持久副本：/tmp 会被清空，开机靠 rcup-start.sh 补回来
mkdir -p /root/rcup
# 写死清单，不能写 $BINS/SCRIPTS：这段在 ssh 的「单引号」里跑，是远端 shell，
# 本地变量根本不会展开（set -u 下会直接 unbound variable）。改 BINS 时记得同步这里。
for f in v4l2hevc-aarch64 rcinputd-aarch64 \
         play.sh rcup-start.sh; do
	cp -f "/tmp/$f" "/root/rcup/$f"
done
# 重启守护：pkill 一律按「15 字节 comm」匹配，别用 -f —— 那样会连
# 这条 ssh 自己的命令行一起匹配上，把本次部署直接杀掉（exit 255）。
sh /tmp/rcup-start.sh -r
' || exit 1

say "部署完成（/tmp + /root/rcup 各一份，守护已重启）"

# ----------------------------------------------------------- 4) 可选开播
if [ "$PLAY" = 1 ]; then
	[ -n "$SRC" ] || { say "没给片源"; exit 1; }
	say "开播：$SRC @ ${SS}s"
	ssh "$BOX" "sh /tmp/play.sh -d \"$SRC\" $SS"
	sleep 2
	ssh "$BOX" 'sh /tmp/play.sh status; echo "--- 音频进程："; pgrep -a mpv | head -3'
fi

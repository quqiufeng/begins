#!/bin/sh
# deploy.sh — 编译 + 推盒子 + 拉起守护，一条命令到底
#
#   ./deploy.sh                    # 播放器 + rcd + 桌面 + 遥控器(keybord) + 浏览器脚本 → 推 → 重启守护
#   ./deploy.sh -n                 # 跳过编译，只推现有产物（老行为）
#   ./deploy.sh -D                 # 只发播放器链路，跳过桌面（改播放器时常用来省一次重启）
#   ./deploy.sh -K                 # 跳过遥控器（keybord → /opt/keybord）
#   ./deploy.sh -C                 # 跳过浏览器脚本（cog → /root/cog，含 startcage.sh）
#   ./deploy.sh -X                 # 跳过浏览器调试脚本（cdp → /root/cdp）
#   ./deploy.sh -p 片子 [秒]       # 推完直接开播（带声音）
#   ./deploy.sh -p 片子 -s 1200    # 同上，指定起播秒
#
# 为什么编译放这里：BINS 里的二进制少了/旧了，脚本原来只会喊「先 make」，
# 然后你还是得自己敲两条 make。现在默认就编，编不过直接停，不会推半套上去。
#
# 桌面（/opt/desktop）也在这里发：Lua 代码不用编译，整套 tar 过去即可；
# 只有 kmsflip.so 要交叉编译。run.sh 和 .env（WebDAV 口令）只存在于盒子上，
# 本地没有这两个文件，所以按目录树推过去不会碰它们 —— 千万别改成 rsync --delete。
#
# 落点只有 /root 一份：二进制、play.sh、rcup-start.sh 全在 /root（ext4，重启不丢）。
# 老版本推 /tmp + 再同步一份 /root/rcup 开机补回，那是 /tmp 是 tmpfs 的权宜之计；
# 现在不需要补，两份反而会不同步（rcinputd 里写死的 play.sh 路径就对不上）。
set -u
BOX=${BOX:-x96}
DIR=$(cd "$(dirname "$0")" && pwd)
# 声音已经并进播放器（aout.c 用 -DAOUT_EMBED 编进 v4l2hevc），
# mpv/mpvctl 都不再参与播放链路，从清单里去掉：少推 1MB，也少一层误判。
BINS="v4l2hevc-aarch64 rcinputd-aarch64"
# play.sh：rcinputd 按键回调（默认 /root/play.sh）
# rcup-start.sh：x96-rc.service 开机拉起 rcinputd
# tvplay-node.sh 是老链路，rc-up.sh 自己都写着已下线 → 不再推。
# rollback-6.18.sh：内核回滚脚本（盒上一直有、但以前没进仓也没推 → 重建要手抄）。
SCRIPTS="play.sh rcup-start.sh rollback-6.18.sh"
# 桌面：整棵源码树，加上交叉编译出来的 kmsflip.so（→ /opt/desktop/lib/）。
# 只列真正属于源码的条目，/opt/desktop 下的 run.sh、.env、lib/ 由盒子自己管。
DESKTOP_D="$DIR/../desktop"
DESK_ITEMS="assets config.lua core ffi main.lua tools ui util"
# 遥控器：keybord 全是 Lua（不用编译），要编的只有它 FFI 用的 libpctl.so
# （hevcdec/pctl_ffi.c → libpctl-aarch64.so → 盒子上叫 /opt/keybord/libpctl.so）。
# 落点 /opt/keybord，由 keybd.service 常驻；它就是遥控器的最终实现，
# 老的 rcinputd 只在 keybd 没接管时才拉（见 3) 里的判断）。
KEYBORD_D="$DIR/../keybord"
KEYB_ITEMS="act.lua config.lua evdev.lua explore.lua keybd.lua keynames.lua pctl.lua sock.lua apps keys maps tools"
PCTL_SO="$DIR/libpctl-aarch64.so"

PLAY=0; SRC=; SS=0; BUILD=1; DESK=1; KEYB=1; COG=1; CDP=1
while getopts 'nDKCXp:s:h' _o 2>/dev/null; do
	case "$_o" in
	n) BUILD=0 ;;
	D) DESK=0 ;;
	K) KEYB=0 ;;
	C) COG=0 ;;
	X) CDP=0 ;;
	p) PLAY=1; SRC=$OPTARG ;;
	s) SS=$OPTARG ;;
	h) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] && [ "$PLAY" = 0 ] && { SRC=$1; PLAY=1; SS=${2:-0}; }

say() { echo "deploy: $*"; }

cd "$DIR" || exit 1

# --------------------------------------------------- 0) 先探盒子要哪种平面
# 播放器二进制没法一套通吃：V4L2 平面模式（CAP_T/OUT_T）是编译期常量，
# meson(121) 只收 MPLANE，cedrus(123) 只收单平面，同一份源码编不出两种。
# 所以先探驱动再决定编不编/推哪个 —— 别再像 11-25 那样把单平面推给 121，
# 盒子上直接 S_FMT OUT EINVAL、整条播放链断掉（docs/box-matrix.md §2/§4）。
# 探测失败（老盒子没 sysfs 名字）时按 BOX 名兜底，仍不确定才认 PLANE 变量。
MPLANE_BIN="$DIR/dist/hevcdec-20261119-1949-84d7124/v4l2hevc-aarch64"
BOX_DRV=$(ssh "$BOX" 'cat /sys/class/video4linux/video0/name 2>/dev/null' 2>/dev/null)
case "$BOX_DRV" in
*meson*)		BOX_PLANE=mplane ;;
*cedrus*|*sunxi*)	BOX_PLANE=single ;;
*)	case "$BOX" in
	x96*) BOX_PLANE=mplane ;;
	*)    BOX_PLANE=single ;;
	esac ;;
esac
[ -n "${PLANE:-}" ] && BOX_PLANE=$PLANE
if [ "$BOX_PLANE" = mplane ]; then
	[ -f "$MPLANE_BIN" ] || { say "缺 MPLANE 二进制 $MPLANE_BIN"; exit 1; }
	PLAYER_SRC=$MPLANE_BIN
else
	PLAYER_SRC="$DIR/v4l2hevc-aarch64"
fi
say "盒子 $BOX 驱动=${BOX_DRV:-未知} → 平面=$BOX_PLANE，播放器 $(md5sum "$PLAYER_SRC" | cut -c1-8)"

# ---------------------------------------------------------------- 1) 编译
if [ "$BUILD" = 1 ]; then
	command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
		say "缺交叉编译器 aarch64-linux-gnu-gcc（apt install gcc-aarch64-linux-gnu）"
		say "只想推现有二进制就加 -n"
		exit 1
	}
	say "编译 rcinputd → make CROSS=1 rcd"
	make CROSS=1 rcd || { say "rcinputd 编译失败，已中止（盒子上什么都没动）"; exit 1; }
	if [ "$BOX_PLANE" = single ]; then
		say "编译播放器（单平面）→ make CROSS=1"
		make CROSS=1 || { say "播放器编译失败，已中止（盒子上什么都没动）"; exit 1; }
		# 不编 aout：它不在 BINS 里（见文件头注释）。要单独测就手动 make CROSS=1 aout。
	else
		say "盒子是 MPLANE → 不编本地单平面播放器，推熟好版 $(basename "$MPLANE_BIN")"
	fi
	if [ "$DESK" = 1 ]; then
		# 桌面只有 kmsflip.so 是 C；产物固定落在 /tmp/kmsflip.so（见该脚本）。
		say "编译桌面 LD_PRELOAD → desktop/tools/build-kmsflip.sh"
		sh "$DESKTOP_D/tools/build-kmsflip.sh" ||
			{ say "kmsflip.so 编译失败，已中止（盒子上什么都没动）"; exit 1; }
	fi
	if [ "$KEYB" = 1 ]; then
		# 遥控器唯一的 C 产物：keybord/pctl.lua 用 FFI 直连播放器控制面。
		say "编译遥控器 FFI → make CROSS=1 pctlffi"
		make CROSS=1 pctlffi || { say "libpctl.so 编译失败，已中止（盒子上什么都没动）"; exit 1; }
	fi
else
	say "跳过编译（-n），直接推现有产物"
fi

for f in $BINS $SCRIPTS; do
	# mplane 盒子推的是熟好版播放器，本地单平面 v4l2hevc-aarch64 不必存在
	[ "$f" = v4l2hevc-aarch64 ] && [ "$BOX_PLANE" = mplane ] && continue
	[ -f "$DIR/$f" ] || { say "缺文件 $f（先 make CROSS=1 && make CROSS=1 rcd）"; exit 1; }
done
if [ "$KEYB" = 1 ]; then
	for f in $KEYB_ITEMS; do
		[ -e "$KEYBORD_D/$f" ] || { say "缺遥控器条目 keybord/$f"; exit 1; }
	done
	[ -f "$PCTL_SO" ] || { say "缺 $PCTL_SO（make CROSS=1 pctlffi，或别加 -n）"; exit 1; }
fi

say "产物：播放器=$(md5sum "$PLAYER_SRC" | cut -c1-8) $(cd "$DIR" && md5sum rcinputd-aarch64 | awk '{printf "rcinputd=%s", substr($1,1,8)}')"

# ------------------------------------------------------- 2) 停守护 + 推文件
# scp 是 open(O_WRONLY|O_TRUNC)，对着「正在执行的二进制」会 ETXTBSY（报 "Failure"）。
# 两个对策，按被打扰的代价分：
#   rcinputd  → 直接停掉（它没有状态，rcup-start.sh -r 会拉起来）
#   播放器    → 只 rm -f 不 kill：unlink 掉文件名，运行中的进程继续用旧 inode 放，
#                scp 建新文件，画面声音一条不断，下次 seek 重开自然用上新二进制。
# 停守护只能用「comm 匹配」：pkill -f 的模式串出现在远端 bash -c 自己的命令行里，
# 会把这个 ssh 会话自己杀掉（rm 根本没轮到执行，scp 接着报 Failure）。
# 顺手清掉 /tmp 的老副本：留着会让人以为 play.sh/播放器还有第二份，排查时误导。
ssh "$BOX" 'pkill -x rcinputd-aarch6 2>/dev/null
sleep 0.2
rm -f /root/v4l2hevc-aarch64 /root/rcinputd-aarch64
rm -f /tmp/v4l2hevc-aarch64 /tmp/rcinputd-aarch64 /tmp/mpvctl-aarch64
rm -f /tmp/play.sh /tmp/rcup-start.sh
rm -rf /root/rcup
exit 0'

say "推文件 → $BOX:/root"
scp -q $(
	for f in $BINS $SCRIPTS; do
		case "$f" in
		v4l2hevc-aarch64) printf '%s ' "$PLAYER_SRC" ;;
		*)                printf '%s ' "$DIR/$f" ;;
		esac
	done
) "$BOX:/root/" || exit 1

# ------------------------------------------------ 3) 落权限 + 重启守护
ssh "$BOX" 'set -u
chmod 755 /root/v4l2hevc-aarch64 /root/rcinputd-aarch64 \
          /root/play.sh /root/rcup-start.sh /root/rollback-6.18.sh
# 开机服务指向还是老路径（/root/rcup/rcup-start.sh）就改过来，
# 不然重启后又去跑那份已经被删的副本，遥控器照样失灵。
if grep -q "/root/rcup/" /etc/systemd/system/x96-rc.service 2>/dev/null; then
	sed -i "s|/root/rcup/|/root/|g" /etc/systemd/system/x96-rc.service
	systemctl daemon-reload 2>/dev/null
	echo "x96-rc.service → /root/rcup-start.sh"
fi
# 重启守护：pkill 一律按「15 字节 comm」匹配，别用 -f —— 那样会连
# 这条 ssh 自己的命令行一起匹配上，把本次部署直接杀掉（exit 255）。
# keybord 接管后 rcinputd 就是多余的那一份：两个守护抢同一批 evdev，
# 谁先抓谁赢（keybd 抓不到就完全没按键）。所以 keybd.service 已启用时
# 干脆不拉 rcinputd；要回退成老链路就 systemctl disable keybd。
if systemctl is-enabled keybd.service >/dev/null 2>&1; then
	echo "遥控器由 keybd.service 接管 → 不拉 rcinputd"
	# || true 是必须的：pkill 没匹配到人（已经退了）返回 1，会把整段 ssh
	# 的退出码带成 1，deploy 就停在这儿，后面的桌面/遥控器一节都不跑。
	pkill -x rcinputd-aarch6 2>/dev/null || true
else
	sh /root/rcup-start.sh -r
fi
exit 0
' || exit 1

say "部署完成（/root 一份，守护已重启）"

# ------------------------------------------------- 4) 桌面（/opt/desktop）
# 一条命令发全套：播放器改了、桌面改了都是一次 deploy。
# 两种「只发一半」的入口：-D 跳过本节；-n 只推现有产物不编译。
if [ "$DESK" = 1 ]; then
	for f in $DESK_ITEMS; do
		[ -e "$DESKTOP_D/$f" ] || { say "缺桌面条目 desktop/$f"; exit 1; }
	done
	KMS=/tmp/kmsflip.so
	[ -f "$KMS" ] || { say "缺 $KMS（先 sh desktop/tools/build-kmsflip.sh，或别加 -n）"; exit 1; }

	# 用 tar 不用 rsync：盒子上没装 rsync；也正因为没有 --delete 语义，
	# 这里只覆盖列表内的源码条目，run.sh / .env / lib/ 永远不被动到。
	# tar 里带的是文件 mtime，源码没改就字节一致 —— 可以直接拿 md5 判「要不要重启」。
	TAR=/tmp/desktop-deploy.tar
	tar -C "$DESKTOP_D" -cf "$TAR" $DESK_ITEMS || exit 1
	TARMD5=$(md5sum "$TAR" | cut -c1-32)
	KMSMD5=$(md5sum "$KMS" | cut -c1-32)
	say "桌面产物：tree=$TARMD5 kmsflip=$KMSMD5"

	# 三行固定输出（文件不在就是 "-"），这样字段不会错位。
	# 标记文件里存的是 tar 的 md5，所以取 cat 而不是 md5sum —— 后者得到的是
	# 「摘要文本的摘要」，和 TARMD5 永不相等，会每次白重发+重启桌面。
	R=$(ssh "$BOX" '[ -f /opt/desktop/.deploy.tar.md5 ] && cat /opt/desktop/.deploy.tar.md5 || echo -
if [ -f /opt/desktop/lib/kmsflip.so ]; then md5sum /opt/desktop/lib/kmsflip.so | cut -c1-32; else echo -; fi
systemctl is-active desktop 2>/dev/null || true')
	R_TAR=$(printf '%s\n' "$R" | sed -n 1p)
	R_KMS=$(printf '%s\n' "$R" | sed -n 2p)
	R_ACT=$(printf '%s\n' "$R" | sed -n 3p)

	if [ "$R_TAR" = "$TARMD5" ] && [ "$R_KMS" = "$KMSMD5" ] && [ "$R_ACT" = active ]; then
		say "桌面无变化且正在运行 → 跳过推送与重启"
	else
		ssh "$BOX" 'cat > /tmp/desktop-deploy.tar' < "$TAR" || exit 1
		scp -q "$KMS" "$BOX:/tmp/kmsflip.so.new" || exit 1
		ssh "$BOX" 'set -eu
		# run.sh 只在盒子上（含 KMSFLIP/LD_PRELOAD 与内存参数），本脚本不生成它。
		# 万一被人删了就别重启，否则桌面起不来只剩黑屏。
		[ -f /opt/desktop/run.sh ] || { echo "缺 /opt/desktop/run.sh，已中止" >&2; exit 1; }
		# --no-same-owner：tar 是以 root 解，没这个开关会把 local uid 1000 写上去。
		tar --no-same-owner -C /opt/desktop -xf /tmp/desktop-deploy.tar
		mkdir -p /opt/desktop/lib
		install -m0755 /tmp/kmsflip.so.new /opt/desktop/lib/kmsflip.so
		rm -f /tmp/desktop-deploy.tar /tmp/kmsflip.so.new
		echo "桌面代码已落盘"' || exit 1

		# 重启桌面。KillMode=process 只杀桌面本身；正在跑的播放器/阅读器会被
		# 一起收掉（它们是桌面的子进程），迭代期这正是想要的干净状态。
		ssh "$BOX" 'systemctl restart desktop; sleep 3; systemctl is-active desktop' || {
			say "桌面重启失败，看 journalctl -u desktop -n 30"
			exit 1
		}
		# 只有起来了才写标记，失败下次还会重发。
		ssh "$BOX" "printf '%s\n' $TARMD5 > /opt/desktop/.deploy.tar.md5"
		say "桌面已发布并重启（$BOX:/opt/desktop）"
	fi
else
	say "跳过桌面（-D）"
fi

# ------------------------------------------------- 5) 遥控器（/opt/keybord）
# 遥控器整条链路的真源在 keybord/：keybd.lua 独占 evdev、判前台、
# 按 keys/<app>.lua 的写死键表分发 → apps/<app>.lua 走 app 自己的 socket。
# 全是 Lua，唯一的 C 产物是 pctl.lua 用的 libpctl.so（上面已编好）。
# 落点 /opt/keybord，跑在盒子上那份自编译 luajit（/opt/reader/bin/luajit）。
if [ "$KEYB" = 1 ]; then
	# 和桌面同一套 tar + md5 标记的手法：源码没改就不推、不重启
	# （keybd 重启要重新 grab，一秒钟内按键全丢，没必要白丢）。
	# 只覆盖列表内的条目，盒子上多出来的东西（libpctl.so、日志）不碰。
	TAR=/tmp/keybord-deploy.tar
	tar -C "$KEYBORD_D" -cf "$TAR" $KEYB_ITEMS || exit 1
	KEYBMD5=$(md5sum "$TAR" | cut -c1-32)
	SOMD5=$(md5sum "$PCTL_SO" | cut -c1-32)
	say "遥控器产物：tree=$KEYBMD5 libpctl=$SOMD5"

	R=$(ssh "$BOX" '[ -f /opt/keybord/.deploy.tar.md5 ] && cat /opt/keybord/.deploy.tar.md5 || echo -
if [ -f /opt/keybord/libpctl.so ]; then md5sum /opt/keybord/libpctl.so | cut -c1-32; else echo -; fi
systemctl is-active keybd 2>/dev/null || true')
	R_TAR=$(printf '%s\n' "$R" | sed -n 1p)
	R_SO=$(printf '%s\n' "$R" | sed -n 2p)
	R_ACT=$(printf '%s\n' "$R" | sed -n 3p)

	if [ "$R_TAR" = "$KEYBMD5" ] && [ "$R_SO" = "$SOMD5" ] && [ "$R_ACT" = active ]; then
		say "遥控器无变化且正在运行 → 跳过推送与重启"
	else
		ssh "$BOX" 'mkdir -p /opt/keybord/apps /opt/keybord/keys /opt/keybord/maps /opt/keybord/tools'
		ssh "$BOX" 'cat > /tmp/keybord-deploy.tar' < "$TAR" || exit 1
		# .so 先落 .new 再 install：keybd 的每次按键都会 fork 一条 luajit 去
		# ffi.load 它，直接覆盖正在映射的文件会 ETXTBSY/半截 so。
		scp -q "$PCTL_SO" "$BOX:/tmp/libpctl.so.new" || exit 1
		ssh "$BOX" 'set -eu
		# --no-same-owner：tar 以 root 解，否则会把本地 uid 1000 带上去
		tar --no-same-owner -C /opt/keybord -xf /tmp/keybord-deploy.tar
		install -m0755 /tmp/libpctl.so.new /opt/keybord/libpctl.so
		rm -f /tmp/keybord-deploy.tar /tmp/libpctl.so.new
		echo "遥控器代码已落盘"' || exit 1

		# 单元文件只在盒子上（含 luajit 路径与环境变量）。没了就按 keybord
		# 的约定补一份，别指望 install.sh —— 那个是从开发机 scp 过去的。
		UNIT=/etc/systemd/system/keybd.service
		ssh "$BOX" "set -eu
		if [ ! -f $UNIT ]; then
			cat > $UNIT <<'EOF'
[Unit]
Description=keybd remote/keyboard dispatcher (LuaJIT, per-app automation)
After=multi-user.target

[Service]
Type=simple
WorkingDirectory=/opt/keybord
Environment=KEYBD_ROOT=/opt/keybord
Environment=LOG=/tmp/keybd.log
Environment=GRAB=1
Environment=REPEAT_MS=220
Environment=DEDUP_MS=40
Environment=DISPATCH=exec
ExecStart=/opt/reader/bin/luajit /opt/keybord/keybd.lua
Restart=always
RestartSec=2
StandardOutput=append:/tmp/keybd.log
StandardError=append:/tmp/keybd.log

[Install]
WantedBy=multi-user.target
EOF
			systemctl daemon-reload
			echo 'keybd.service 已补写'
		fi
		# 老守护必须先退：它握着同一批 evdev，keybd 抢不到 grab 就一个键都不认。
		systemctl disable --now x96-rc.service 2>/dev/null || true
		pkill -x rcinputd-aarch6 2>/dev/null || true
		systemctl enable keybd.service >/dev/null 2>&1 || true
		systemctl restart keybd.service
		sleep 1.5
		systemctl is-active keybd.service" || {
			say "遥控器重启失败，看 tail -30 /tmp/keybd.log"
			exit 1
		}
		ssh "$BOX" "printf '%s\n' $KEYBMD5 > /opt/keybord/.deploy.tar.md5"
		say "遥控器已发布并重启（$BOX:/opt/keybord）"
	fi

	# 只读自检 1：evdev 独占是否成功。这一行失败=全盘没按键，比什么都重要。
	# 只读自检 2：用盒子自己的 luajit 真加载 keybord/pctl.lua（即 libpctl.so），
	# 打印 version。.so 架构不对/符号缺/装成半截，都会在这里当场露出来，
	# 而不是等用户按遥控器时才发现「没反应」。
	ssh "$BOX" 'tail -60 /tmp/keybd.log 2>/dev/null | grep -E "apps:|grab=|ready" | tail -12' |
		sed 's/^/  /'
	FFI_OUT=$(ssh "$BOX" 'cd /opt/keybord && /opt/reader/bin/luajit -e "
package.path=\"/opt/keybord/?.lua;\"..package.path
local p=require(\"pctl\")
print((p.ffi and \"ok\" or \"FAIL\")..\" libpctl=\"..tostring(p.version))
" 2>&1')
	case "$FFI_OUT" in
	ok*) say "遥控器 FFI 自检：$FFI_OUT" ;;
	*) say "遥控器 FFI 自检失败：$FFI_OUT"; exit 1 ;;
	esac
else
	say "跳过遥控器（-K）"
fi

# --------------------------------------------- 6) 浏览器直出脚本（/root/cog）
# cog（WPE WebKit）是第四种直出 app：和桌面/阅读器/播放器一样独占 DRM master，
# 谁要显示谁 start（box-cog.sh start 会 mask --runtime desktop 抢 DRM，stop 再还原）。
# 这里只发脚本本身 —— /usr/bin/cog 是 apt 包，不在这儿装（盒子上没有就跳过，
# 免得推一份跑不起来的东西上去）。不重启用任何守护：cog 不是常驻服务。
if [ "$COG" = 1 ]; then
	COG_D="$DIR/../tools/cog"
	# startcage.sh：cage+chromium 的启动脚本（掩掉 desktop、修字号、setsid 起 kiosk）。
	#   以前只在盒上 /root/startcage.sh，仓库没有 → 换台盒子就得手抄，这次一并收进来。
	#   落点是 /root/cog/，同时在 /root/startcage.sh 放一个转发壳，老的敲法照旧能用。
	# cog.lua：开发机侧 LuaJIT 遥控（start/open/shot/stop），盒子上用不到但同源一份，
	#   保证「盒上跑的东西仓库里都有」这条不留例外。
	COG_ITEMS="box-cog.sh startcage.sh cog.lua"
	for f in $COG_ITEMS; do
		[ -f "$COG_D/$f" ] || { say "缺浏览器条目 tools/cog/$f"; exit 1; }
	done
	# 没装 cog 也照推：startcage.sh 走的是 cage+chromium，跟 cog 没关系，
	# 以前拿 cog 当整段开关，结果新盒子上连 startcage 都发不过去。
	if ! ssh "$BOX" 'command -v cog >/dev/null 2>&1'; then
		say "提示：盒子没装 cog（apt install cog），box-cog.sh 暂时跑不起来"
	fi
	TAR=/tmp/cog-deploy.tar
	tar -C "$COG_D" -cf "$TAR" $COG_ITEMS || exit 1
	COGMD5=$(md5sum "$TAR" | cut -c1-32)
	R=$(ssh "$BOX" '[ -f /root/cog/.deploy.tar.md5 ] && cat /root/cog/.deploy.tar.md5 || echo -')
	if [ "$R" = "$COGMD5" ]; then
		say "浏览器脚本无变化 → 跳过推送"
	else
		ssh "$BOX" 'mkdir -p /root/cog'
		ssh "$BOX" 'cat > /tmp/cog-deploy.tar' < "$TAR" || exit 1
		ssh "$BOX" 'set -eu
		tar --no-same-owner -C /root/cog -xf /tmp/cog-deploy.tar
		rm -f /tmp/cog-deploy.tar
		chmod 755 /root/cog/box-cog.sh /root/cog/startcage.sh
		# 老敲法 /root/startcage.sh 留着，但只做转发 —— 实体只有 /root/cog 一份，
		# 两份同源文件迟早会改歪（rcup 那次就是）。
		printf "#!/bin/sh\nexec /root/cog/startcage.sh \"\$@\"\n" > /root/startcage.sh
		chmod 755 /root/startcage.sh
		echo "浏览器脚本已落盘"' || exit 1
		ssh "$BOX" "printf '%s\n' $COGMD5 > /root/cog/.deploy.tar.md5"
		say "浏览器脚本已发布（$BOX:/root/cog，/root/startcage.sh 为转发壳）"
	fi
else
	say "跳过浏览器（-C）"
fi

# --------------------------------------------- 7) 浏览器调试脚本（/root/cdp）
# cdp_do.lua 是盒子侧的控制入口（连 127.0.0.1:9222 的 CDP，@nav/@key/@shot/@js…），
# prof.sh/sc2.sh/measure.sh 是配套的抓帧与性能测量，几个 html 是压测页。
# 以前这些只躺在盒子的 /tmp（tmpfs，重启就没），等于每次重来都要重写一遍。
if [ "$CDP" = 1 ]; then
	CDP_D="$DIR/../tools/cdp"
	CDP_ITEMS="cdp_do.lua prof.sh sc2.sh measure.sh bench.html bench2.html vid.html probe.html"
	for f in $CDP_ITEMS; do
		[ -f "$CDP_D/$f" ] || { say "缺调试条目 tools/cdp/$f"; exit 1; }
	done
	TAR=/tmp/cdp-deploy.tar
	tar -C "$CDP_D" -cf "$TAR" $CDP_ITEMS || exit 1
	CDPMD5=$(md5sum "$TAR" | cut -c1-32)
	R=$(ssh "$BOX" '[ -f /root/cdp/.deploy.tar.md5 ] && cat /root/cdp/.deploy.tar.md5 || echo -')
	if [ "$R" = "$CDPMD5" ]; then
		say "调试脚本无变化 → 跳过推送"
	else
		ssh "$BOX" 'mkdir -p /root/cdp'
		ssh "$BOX" 'cat > /tmp/cdp-deploy.tar' < "$TAR" || exit 1
		ssh "$BOX" 'set -eu
		tar --no-same-owner -C /root/cdp -xf /tmp/cdp-deploy.tar
		rm -f /tmp/cdp-deploy.tar
		chmod 755 /root/cdp/prof.sh /root/cdp/sc2.sh /root/cdp/measure.sh
		chmod 644 /root/cdp/cdp_do.lua /root/cdp/*.html
		echo "调试脚本已落盘"' || exit 1
		ssh "$BOX" "printf '%s\n' $CDPMD5 > /root/cdp/.deploy.tar.md5"
		say "调试脚本已发布（$BOX:/root/cdp）"
	fi
else
	say "跳过调试脚本（-X）"
fi

# ----------------------------------------------------------- 8) 可选开播
if [ "$PLAY" = 1 ]; then
	[ -n "$SRC" ] || { say "没给片源"; exit 1; }
	say "开播：$SRC @ ${SS}s"
	ssh "$BOX" "sh /root/play.sh -d \"$SRC\" $SS"
	sleep 2
	ssh "$BOX" 'sh /root/play.sh status'
fi

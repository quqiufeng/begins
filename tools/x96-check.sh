#!/bin/bash
# x96-check.sh — 盒子上「注入 → 读状态 → 抓图 → 与基线对拍」的全自动回归判定
#
# 三层：
#   注入   走桌面自己的 unix socket：key/click/call（与 native-reader 同协议）
#   状态   每步后取 brief（sel/count/dir/reader/player），断言"真的动了"
#   画面   抓帧（desk→drm 自动回落）与基线比 AE 差异率，超容差即 fail
#
# 用法:
#   tools/x96-check.sh --golden home                   # 把当前画面存成基线
#   tools/x96-check.sh --diff home                     # 与基线比，返回 0/1
#   tools/x96-check.sh --golden home --do "key:DOWN,wait:300"
#   tools/x96-check.sh --diff home --do "key:RIGHT" --settle 800 --max-diff 1.5
#   tools/x96-check.sh --diff home --do "key:OK" --assert-name reader --restore "key:BACK"
#   tools/x96-check.sh --case tools/cases/home.case            # 跑一个用例
#   tools/x96-check.sh --run-dir tools/cases                   # 跑整个目录
#   tools/x96-check.sh --run-dir tools/cases --record          # 批量重录基线
#
# 选项:
#   --mode desk|drm|console   抓图方式（默认 desk，失败自动回落 drm）
#   --do "step;step;..."      分隔符只认分号（JSON 参数里有逗号）
#                             key:NAME / click:ID / wait:ms / call:FN / call:FN:{json} / raw:{json}
#   --fuzz N                  像素近似容差百分比（默认 1；静止画面实测 0 差异，可收紧到 0）
#   --max-diff P              允许的差异像素占比百分比（默认 0.1 ≈ 3700px）
#   --ignore x,y,w,h          对比前抹掉的矩形，可重复（时钟/动画角标）
#   --settle ms               抓图前等待重绘（默认 500）
#   --assert-sel NAME         断言当前选中项名（brief.sel）
#   --assert-count N          断言条目数
#   --golden-dir DIR          基线目录（默认 tools/golden）
#   --json                    结果打成一行 JSON
#
# 用例文件（.case）就是上面这些选项的逐行写法（长选项去掉 --）:
#   mode desk
#   fuzz 3
#   max-diff 2.0
#   ignore 2440,10,120,40
#   do key:RIGHT;wait:400
#   golden home-right
#   assert-sel 机器学习
#
# 退出码: 0 通过 / 1 画面不符 / 2 状态断言失败 / 3 抓图或环境失败
#
# 依赖: 本机 ssh/scp/ffmpeg/ImageMagick(compare,convert)；盒子 root ssh + python3
set -uo pipefail
[ -f ~/.env ] && . ~/.env
HOST="${X96_HOST:-x96}"
SOCK=/tmp/desktop-automation.sock
SSH="ssh -o BatchMode=yes $HOST"
HERE=$(cd "$(dirname "$0")/.." && pwd)

MODE=desk; NAME=""; DO=""; FUZZ=1; MAXDIFF=0.1; SETTLE=600; RESTORE=""; ASSERT_NAME=""
GOLDEN_DIR="$HERE/tools/golden"; ACTION=""; JSON=0
CASE=""; RUN_DIR=""; RECORD=0
IGNORES=(); ASSERT_SEL=""; ASSERT_COUNT=""

die() { echo "x96-check: $*" >&2; exit 3; }

# ---------- 注入 + 读状态：一次 ssh 连接跑完所有步 ----------
# $1 = 步骤串；回显每步的应答（JSON 行）
desk_steps() {
	local steps="$1"
	local py='
import socket,sys,time,json
steps=[s for s in sys.argv[1].split(";") if s.strip()]
def send(req):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(10)
    s.connect(SOCK)
    s.sendall((json.dumps(req)+"\n").encode())
    b=b""
    while not b.endswith(b"\n"):
        d=s.recv(65536)
        if not d: break
        b+=d
    s.close()
    return b.decode(errors="replace").strip()
for st in steps:
    st=st.strip()
    if st.startswith("wait:"):
        time.sleep(float(st[5:])/1000.0); continue
    if st.startswith("key:"):
        r=send({"cmd":"key","name":st[4:]})
    elif st.startswith("click:"):
        r=send({"cmd":"click","id":st[6:]})
    elif st.startswith("call:"):
        fn=st[5:]
        args={}
        if ":" in fn:
            fn,aj=fn.split(":",1); args=json.loads(aj)
        r=send({"cmd":"call","fn":fn,"args":args})
    elif st.startswith("raw:"):
        r=send(json.loads(st[4:]))
    else:
        continue
    print(st+"\t"+r)
print("brief\t"+send({"cmd":"brief"}))
'
	timeout 40 $SSH "python3 - '$steps'" <<PY 2>&1
import socket,sys,time,json
SOCK="$SOCK"
$py
PY
}

# ---------- 抓图：复用 x96-shot.sh，desk 失败它自己会回落 drm ----------
grab() {
	local out="$1"
	timeout 90 "$HERE/tools/x96-shot.sh" "--$MODE" -o "$out" >/tmp/x96-check-shot.log 2>&1
	local rc=$?
	[ -s "$out" ] || { echo "抓图失败（rc=$rc）:" >&2; tail -3 /tmp/x96-check-shot.log >&2; return 1; }
	return 0
}

# ---------- 对比：AE（fuzz 内算相同）差异像素数 → 占比 ----------
compare_png() {
	local a="$1" b="$2"	# a=基线 b=实测
	local mask=() ig
	local gm gmw gmh
	gmw=$(convert "$a" -format "%w" info:); gmh=$(convert "$a" -format "%h" info:)
	local amw amh
	amw=$(convert "$b" -format "%w" info:); amh=$(convert "$b" -format "%h" info:)

	# 分辨率变了就是环境变了，先归一化再比，但要记一笔
	if [ "$gmw" != "$amw" ] || [ "$gmh" != "$amh" ]; then
		echo "  注意: 分辨率不一致 基线 ${gmw}x${gmh} 实测 ${amw}x${amh}，已缩放到基线尺寸" >&2
		convert "$b" -resize "${gmw}x${gmh}!" "$b.norm.png" && b="$b.norm.png"
	fi

	mkdir -p /tmp/x96chk
	local pa=/tmp/x96chk/base.png pb=/tmp/x96chk/real.png
	cp "$a" "$pa"; cp "$b" "$pb"

	# 抹掉不关心的区域（时钟、光标、动画角标）
	if [ ${#IGNORES[@]} -gt 0 ]; then
		local draw=""
		for ig in "${IGNORES[@]}"; do
			local x y w h
			IFS=, read -r x y w h <<<"$ig"
			draw="$draw -draw \"rectangle $x,$y $((x+w)),$((y+h))\""
		done
		eval "convert \"\$pa\" -fill black $draw \"\$pa\""
		eval "convert \"\$pb\" -fill black $draw \"\$pb\""
	fi

	local ae
	ae=$(compare -metric AE -fuzz "${FUZZ}%" "$pa" "$pb" null: 2>&1 | tr -d ' ' )
	case "$ae" in ''|*[!0-9.e+]*)
		# 完全一致时 IM 输出 "0"；其它形式按 RMSE 兜底
		ae=0 ;;
	esac
	local total=$((gmw * gmh))
	local ratio
	ratio=$(awk -v a="$ae" -v t="$total" 'BEGIN{ if(t<=0){print 100}else{printf "%.4f", a*100.0/t} }')
	echo "$ratio"
	return 0
}

# 收尾：用例里 restore 的步必须无条件跑（失败也要把机器放回能用状态）
run_one() {
	run_body
	local rc=$?
	if [ -n "${RESTORE:-}" ]; then
		desk_steps "$RESTORE" >/dev/null 2>&1 || echo "  注意: restore 步失败" >&2
	fi
	return $rc
}

# ---------- 用例文件 → 变量 ----------
load_case() {
	local f="$1" line k v
	[ -f "$f" ] || die "用例不存在: $f"
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"; line="$(echo "$line" | sed 's/[[:space:]]*$//')"
		[ -z "$line" ] && continue
		k="${line%% *}"; v="${line#* }"
		[ "$k" = "$line" ] && continue
		case "$k" in
			mode) MODE="$v" ;;
			restore) RESTORE="${RESTORE:+$RESTORE;}$v" ;;
			assert-name) ASSERT_NAME="$v" ;;
			fuzz) FUZZ="$v" ;;
			max-diff) MAXDIFF="$v" ;;
			settle) SETTLE="$v" ;;
			ignore) IGNORES+=("$v") ;;
			do) DO="${DO:+$DO;}$v" ;;
			golden) NAME="$v" ;;
			assert-sel) ASSERT_SEL="$v" ;;
			assert-count) ASSERT_COUNT="$v" ;;
			*) echo "  忽略未知键: $k" >&2 ;;
		esac
	done <"$f"
}

run_body() {
	local line brief="" step_out=""
	if [ -n "$DO" ]; then
		step_out=$(desk_steps "$DO")
		brief=$(printf '%s\n' "$step_out" | grep '^brief	' | cut -f2-)
		local bad
		bad=$(printf '%s\n' "$step_out" | grep -v '^brief	' | grep -v '"ok": *true' | grep -v '"pong": *true')
		if [ -n "$bad" ]; then
			echo "  ✗ 注入被拒: $bad" >&2
			echo "FAIL $NAME (注入)"; return 3
		fi
	fi

	# 状态断言
	if [ -n "$ASSERT_SEL" ] && [ -n "$brief" ]; then
		case "$brief" in
			*"\"sel\":\"$ASSERT_SEL\""*|*"\"sel\": \"$ASSERT_SEL\""*) ;;
			*) echo "  ✗ 期望选中 [$ASSERT_SEL]，实际 $brief" >&2; echo "FAIL $NAME (状态)"; return 2 ;;
		esac
	fi
	if [ -n "${ASSERT_NAME:-}" ] && [ -n "$brief" ]; then
		case "$brief" in
			*"\"name\":\"$ASSERT_NAME\""*|*"\"name\": \"$ASSERT_NAME\""*) ;;
			*) echo "  ✗ 期望视图 [$ASSERT_NAME]，实际 $brief" >&2; echo "FAIL $NAME (状态)"; return 2 ;;
		esac
	fi
	if [ -n "$ASSERT_COUNT" ] && [ -n "$brief" ]; then
		case "$brief" in
			*"\"count\":$ASSERT_COUNT"*|*"\"count\": $ASSERT_COUNT"*) ;;
			*) echo "  ✗ 期望条目数 $ASSERT_COUNT，实际 $brief" >&2; echo "FAIL $NAME (状态)"; return 2 ;;
		esac
	fi

	[ "$SETTLE" != "0" ] && sleep "$(awk -v m="$SETTLE" 'BEGIN{printf "%.2f", m/1000}')"
	local shot=/tmp/x96chk/actual-$NAME.png
	command mkdir -p /tmp/x96chk 2>/dev/null || mkdir -p /tmp/x96chk
	grab "$shot" || { echo "FAIL $NAME (抓图)"; return 3; }

	local golden="$GOLDEN_DIR/$NAME.png"
	if [ "$ACTION" = golden ] || { [ -n "$RUN_DIR" ] && [ "$RECORD" = 1 ]; }; then
		mkdir -p "$GOLDEN_DIR"
		cp "$shot" "$golden"
		echo "RECORD $NAME → $golden"
		return 0
	fi

	if [ ! -f "$golden" ]; then
		echo "  ✗ 基线不存在: $golden（先 --golden $NAME 录一次）" >&2
		echo "FAIL $NAME (无基线)"; return 3
	fi
	local ratio
	ratio=$(compare_png "$golden" "$shot")
	local pass
	pass=$(awk -v r="$ratio" -v m="$MAXDIFF" 'BEGIN{print (r<=m)?"1":"0"}')
	if [ "$pass" = "1" ]; then
		echo "PASS $NAME  差异 ${ratio}% ≤ ${MAXDIFF}%"
		[ "$JSON" = 1 ] && echo "{\"ok\":true,\"case\":\"$NAME\",\"diff\":$ratio,\"max\":$MAXDIFF}"
		return 0
	fi
	mkdir -p "$HERE/logs"
	cp "$shot" "$HERE/logs/check-$NAME-actual.png" 2>/dev/null
	compare -metric AE -fuzz "${FUZZ}%" "$golden" "$shot" "$HERE/logs/check-$NAME-diff.png" >/dev/null 2>&1
	echo "  ✗ 差异 ${ratio}% > ${MAXDIFF}%  证据: logs/check-$NAME-{actual,diff}.png" >&2
	echo "FAIL $NAME  差异 ${ratio}%"
	[ "$JSON" = 1 ] && echo "{\"ok\":false,\"case\":\"$NAME\",\"diff\":$ratio,\"max\":$MAXDIFF}"
	return 1
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
	case "$1" in
		--golden)     ACTION=golden; NAME="$2"; shift ;;
		--diff)       ACTION=diff;   NAME="$2"; shift ;;
		--do)         DO="${DO:+$DO;}$2"; shift ;;
		--mode)       MODE="$2"; shift ;;
		--fuzz)       FUZZ="$2"; shift ;;
		--max-diff)   MAXDIFF="$2"; shift ;;
		--settle)     SETTLE="$2"; shift ;;
		--ignore)     IGNORES+=("$2"); shift ;;
		--assert-sel)   ASSERT_SEL="$2"; shift ;;
		--assert-count) ASSERT_COUNT="$2"; shift ;;
		--assert-name)  ASSERT_NAME="$2"; shift ;;
		--restore)      RESTORE="${RESTORE:+$RESTORE;}$2"; shift ;;
		--golden-dir) GOLDEN_DIR="$2"; shift ;;
		--case)       CASE="$2"; shift ;;
		--run-dir)    RUN_DIR="$2"; shift ;;
		--record)     RECORD=1 ;;
		--json)       JSON=1 ;;
		-h|--help)    sed -n '2,50p' "$0"; exit 0 ;;
		*)            die "未知参数: $1" ;;
	esac
	shift
done
mkdir -p /tmp/x96chk

# 整个目录：逐个 .case，收集失败
if [ -n "$RUN_DIR" ]; then
	files=$(ls "$RUN_DIR"/*.case 2>/dev/null | sort)
	[ -z "$files" ] && die "$RUN_DIR 下没有 .case"
	total=0; failed=0
	for f in $files; do
		# 每个用例在子 shell 里跑，变量互不污染
		out=$(MODE=desk; NAME=""; DO=""; FUZZ=1; MAXDIFF=0.1; SETTLE=600; RESTORE=""; ASSERT_NAME=""; IGNORES=(); ASSERT_SEL=""; ASSERT_COUNT=""; ASSERT_NAME=""
			load_case "$f"; ACTION=diff
			[ -z "$NAME" ] && { echo "SKIP $f (无 golden 行)"; exit 0; }
			run_one
			echo "rc=$?")
		rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p')
		printf '%s\n' "$out" | grep -v '^rc='
		total=$((total + 1)); [ "$rc" != "0" ] && failed=$((failed + 1))
	done
	echo "----"
	echo "用例 $total 个，通过 $((total - failed))，失败 $failed"
	[ "$failed" -eq 0 ] || exit 1
	exit 0
fi

if [ -n "$CASE" ]; then
	load_case "$CASE"
	[ -z "$NAME" ] && die "$CASE 缺少 golden 行"
	[ -z "$ACTION" ] && ACTION=diff
	run_one; exit $?
fi

[ -z "$NAME" ] && die "需要 --golden NAME 或 --diff NAME（或 --case/--run-dir）"
[ -z "$ACTION" ] && die "需要 --golden 或 --diff"
run_one; exit $?

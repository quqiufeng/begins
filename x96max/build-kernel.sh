#!/usr/bin/env bash
# build-kernel.sh — 单独编译内核（X96max.md §19.3），两套各自独立产物树
#
# 用途：改配置/裁剪后快速验证能不能编过、编多久（可用 cp Image 到 U 盘 p1 直接试）。
# 不生成 initrd、不打包、不做镜像 —— 那些交给 pack-kernel.sh / rebuild-from-zero.sh。
#
# 用法：
#   ./x96max/build-kernel.sh              # 全量版（默认）：config-...-full + src-full → kbuild-7.2.12
#   ./x96max/build-kernel.sh --trim       # 裁剪版：config-...-trim + src-trim → kbuild-trim
#   ./x96max/build-kernel.sh --mode trim  # 同上（另一种写法）
#   ./x96max/build-kernel.sh my.config    # 用指定 .config（仍按 MODE 选源码树/产物树）
#   ./x96max/build-kernel.sh -n           # 只打印解析出的路径/校验，不编译
#   ./x96max/build-kernel.sh --clean-src  # 编完删掉按需解压出来的全量树（省 1.x G）
#   JOBS=6 ./x96max/build-kernel.sh --trim
#   两套的固定入口：./x96max/full/build-kernel.sh、./x96max/trim/build-kernel.sh
#
# 参数由 lib/mode.sh 统一决定（两套成对，不会串）：
#   MODE  CFG(=kernel/config-7.2.12-x96-<MODE>)  KSRC                 OUT
#   full  config-7.2.12-x96-full                 src-full(按需解压)    kbuild-7.2.12
#   trim  config-7.2.12-x96-trim                 src-trim             kbuild-trim
# KNAME：full=7.2.12-x96  trim=7.2.12-x96-trim（与 CONFIG_LOCALVERSION 对应）
# 可用 X96_KOUT / X96_KSRC / X96_CFG 覆盖路径。
# trim 套开跑前先过裁剪审计（tools/trim/audit_stubs.py）；确知无害可 X96_SKIP_AUDIT=1 跳过。
#
# 产物：$OUT/{arch/arm64/boot/Image, .../meson-g12a-x96-max.dtb, modules/, System.map}
# 结果：$ROOT/logs/build-<MODE>-<ts>.log，以及 $OUT/.build-rc / .build-sec（退出码/耗时秒）
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SELF_DIR/lib/mode.sh"

M=${X96_CFG_MODE:-full}; DRY=0; POS=(); CLEAN_SRC=${X96_CLEAN_SRC:-0}
# `--mode <v>` 先归一成 --mode=<v>：下面 for 循环里 shift 不会跳过下一轮的迭代项，
# 裸值会被再扫一遍当多余参数（rebuild-from-zero 的 19.5 阶段就是这么挂的）。
_argv=(); while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) _argv+=("--mode=${2:?--mode 需要 full|trim}"); shift 2 ;;
    *)      _argv+=("$1"); shift ;;
  esac
done; set -- "${_argv[@]}"
for a in "$@"; do
  case $a in
    --trim|-t)    M=trim ;;
    --full)       M=full ;;
    --mode=*)     M=${a#*=} ;;
    -n|--dry-run) DRY=1 ;;
    --clean-src)  CLEAN_SRC=1 ;;
    --keep-src)   CLEAN_SRC=0 ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,"");print;next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           echo "未知选项: $a（试 --help）" >&2; exit 2 ;;
    *)            POS+=("$a") ;;
  esac
done
x96_mode "$M"
JOBS=${JOBS:-$(nproc)}
[[ -n ${POS[0]:-} ]] && CFG=${POS[0]}

LOG=${LOG:-$ROOT/logs/build-$MODE-$(date +%m%d-%H%M).log}
[[ -f $CFG ]] || { echo "缺 config: $CFG" >&2; exit 2; }
command -v aarch64-linux-gnu-gcc >/dev/null || { echo "缺 aarch64-linux-gnu-gcc" >&2; exit 2; }

S1=$(sha256sum "$CFG" | cut -c1-12)
[[ -n $CFG_ARCHIVE ]] && {
  S3=$(sha256sum "$CFG_ARCHIVE" | cut -c1-12)
  if [[ $S1 == "$S3" ]]; then echo "  归档 $(basename "$CFG_ARCHIVE") 一致（$S3）"
  elif x96_cfg_same "$CFG" "$CFG_ARCHIVE"; then echo "  归档 $(basename "$CFG_ARCHIVE") 字节不同但语义一致（$S3 vs $S1）"
  else echo "  归档 $(basename "$CFG_ARCHIVE") 不一致（$S3 ≠ $S1）"; fi
} || { [[ $MODE == trim ]] && echo "  警告：configs/ 里没有 trim 归档（唯一该留的那份）" || echo "  full 不归档（configs/ 只留 trim）；入口 $CFG"; }
echo "MODE=$MODE  CFG=$CFG ($S1)  KSRC=$KSRC  OUT=$OUT  JOBS=$JOBS  LOG=$LOG"
if [[ -f $OUT/.config ]]; then
  S2=$(sha256sum "$OUT/.config" | cut -c1-12)
  [[ $S1 == "$S2" ]] && echo "  .config 与上次一致（$S2）：增量编译" \
                     || echo "  .config 有变（$S2 → $S1）：将覆盖并 olddefconfig"
fi
if [[ $DRY -eq 1 ]]; then
  if [[ -f $KSRC/Makefile ]]; then echo "  源码树已就绪：$KSRC（$(du -sh "$KSRC" | cut -f1)）"
  elif [[ $MODE == full ]]; then echo "  源码树缺失，开跑时会从 $SRC_XZ 现解压到 $KSRC"
  else echo "  警告：缺裁剪源码树 $KSRC（解压源码包还原不出来，需 gen-trim.sh 重生成）"; fi
  echo "  dry-run：不写 $OUT/.config、不编译。去掉 -n 即开跑。"
  exit 0
fi

# 全量套：源码树不存在就地解压（不再要求常驻一份 src-linux）
x96_ensure_src || exit 2
# trim 套：先审计「被剥空的目录 / 被剥掉的 Makefile 行」，非 0 立刻停（X96_SKIP_AUDIT=1 跳过）
x96_audit_trim || exit 2

mkdir -p "$OUT" "$(dirname "$LOG")"
cp "$CFG" "$OUT/.config"

S=$(date +%s)
set +e
(
  cd "$KSRC"
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image modules
  # 注意：裁剪树已删 arch/arm/boot/dts、arch/riscv/boot/dts（省 29M），
  #       所以只能按「单 dtb 目标」编，绝不能 `make dtbs`（全量会直接报错）。
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- amlogic/meson-g12a-x96-max.dtb
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="$OUT/modules" modules_install
) >"$LOG" 2>&1
rc=$?
set -e
SEC=$(( $(date +%s) - S ))
echo "$rc"  > "$OUT/.build-rc"
echo "$SEC" > "$OUT/.build-sec"

grep -E '^CONFIG_LOCALVERSION=' "$OUT/.config" || true
if [[ $rc -eq 0 ]]; then
  ls -l "$OUT/arch/arm64/boot/Image" \
        "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" 2>/dev/null || true
  du -sh "$OUT/modules/lib/modules/$KNAME" 2>/dev/null || true
  echo "OK 编译成功  MODE=$MODE  耗时 ${SEC}s（$((SEC/60))分$((SEC%60))秒）  rc=0"
  x96_drop_src "$CLEAN_SRC"
else
  echo "X 编译失败 rc=$rc  MODE=$MODE  耗时 ${SEC}s，见 $LOG" >&2
  grep -iE 'error:|Error [0-9]|No rule' "$LOG" | head -20 >&2 || true
  exit $rc
fi

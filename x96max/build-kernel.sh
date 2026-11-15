#!/usr/bin/env bash
# build-kernel.sh — 单独编译内核（§19.3），带计时与独立日志
#
# 用途：改配置/裁剪后快速验证能不能编过、编多久（可用 cp Image 到 U 盘 p1 直接试）。
# 不生成 initrd、不打包、不做镜像 —— 那些交给 pack-kernel.sh / rebuild-from-zero.sh。
#
# 用法：
#   ./x96max/build-kernel.sh                     # 用 kernel/config-7.2.12-x96 编
#   ./x96max/build-kernel.sh my.config           # 用指定 .config
#   JOBS=6 ./x96max/build-kernel.sh              # 限并发（默认 nproc）
#
# 产物：$OUT/{arch/arm64/boot/Image, .../meson-g12a-x96-max.dtb, modules/, System.map}
# 结果：$OUT/../../logs/build-<ts>.log，以及 $OUT/.build-rc / .build-sec（退出码/耗时秒）
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${X96_BUILD_ROOT:-/x96-build}
KNAME=${X96_KNAME:-7.2.12-x96}
KV=${KNAME%-x96}
OUT=${X96_KOUT:-$ROOT/kbuild-$KV}
KSRC=${X96_KSRC:-$ROOT/src-linux}
JOBS=${JOBS:-$(nproc)}
CFG=${1:-$SELF_DIR/kernel/config-$KNAME}
LOG=${LOG:-$ROOT/logs/build-$(date +%m%d-%H%M).log}

[[ -f $CFG ]] || { echo "缺 config: $CFG" >&2; exit 2; }
[[ -d $KSRC ]] || { echo "缺内核源码树: $KSRC" >&2; exit 2; }
command -v aarch64-linux-gnu-gcc >/dev/null || { echo "缺 aarch64-linux-gnu-gcc" >&2; exit 2; }

mkdir -p "$OUT" "$(dirname "$LOG")"
cp "$CFG" "$OUT/.config"
echo "CFG=$CFG  KSRC=$KSRC  OUT=$OUT  JOBS=$JOBS  LOG=$LOG"

S=$(date +%s)
set +e
(
  cd "$KSRC"
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image modules
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
  echo "OK 编译成功  耗时 ${SEC}s（$((SEC/60))分$((SEC%60))秒）  rc=0"
else
  echo "X 编译失败 rc=$rc  耗时 ${SEC}s，见 $LOG" >&2
  grep -iE 'error:|Error [0-9]|No rule' "$LOG" | head -20 >&2 || true
  exit $rc
fi

#!/usr/bin/env bash
# preflight.sh — 从零重建前的只读自检（X96max.md §0.2 第 0 步）
# 只检查前置，不改任何文件；任何一项 FAIL 就不要往下走。
#
#   ./x96max/preflight.sh
#   X96_BUILD_ROOT=/other ./x96max/preflight.sh
#
# 退出码：0=全过；1=有 FAIL（逐条打印）
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$SELF_DIR")
ROOT=${X96_BUILD_ROOT:-/x96-build}
S=$ROOT/src-linux
KNAME=${X96_KNAME:-7.2.12-x96}
CFG=$SELF_DIR/kernel/config-$KNAME
CFG2=$REPO/configs/config-$KNAME-20261115
SRC_XZ=/opt/linux/src/linux-7.2.12.tar.xz

P=0; F=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; P=$((P+1));
       else printf '  FAIL %s\n' "$1"; F=$((F+1)); fi; }

echo "== preflight: ROOT=$ROOT KNAME=$KNAME =="

# --- 源码树（裁剪树，含 §5.4 的 usb-storage 修复）---
ck "源码树 $S 存在"                 "test -d $S"
ck "drivers/usb/storage 目录"       "test -d $S/drivers/usb/storage"
ck "Kconfig 钩子 source storage"    "grep -q 'storage/Kconfig' $S/drivers/usb/Kconfig"
ck "Makefile 钩子 obj USB_STORAGE"  "grep -q 'CONFIG_USB_STORAGE.*storage/' $S/drivers/usb/Makefile"

# --- 配置（唯一入口：x96max/kernel/config-*）---
ck "配置存在 $CFG"                  "test -f $CFG"
ck "CONFIG_USB_STORAGE=y"           "grep -qx CONFIG_USB_STORAGE=y $CFG"
ck "FAT/MSDOS/VFAT 三连 =y"         "[ \$(grep -cE '^CONFIG_(FAT_FS|MSDOS_FS|VFAT_FS)=y' $CFG) = 3 ]"
ck "两份配置同源（diff -q）"        "diff -q $CFG $CFG2"

# --- 素材与工具链 ---
ck "完整源码包 $SRC_XZ"             "test -f $SRC_XZ"
for t in aarch64-linux-gnu-gcc qemu-aarch64-static mkimage zstd sudo; do
  ck "工具 $t"                      "command -v $t"
done

# --- 脚本可执行 ---
for s in rebuild-from-zero.sh pack-kernel.sh write-card.sh patch-bootargs.sh; do
  ck "可执行 $s"                    "test -x $SELF_DIR/$s"
done
ck "patch-bootargs 支持 --usb-fix"  "grep -q -- '--usb-fix' $SELF_DIR/patch-bootargs.sh"

echo "== 通过 $P / 失败 $F =="
[[ $F -eq 0 ]] || { echo "有 FAIL：先修前置，别开始重建（见 X96max.md §0.2）" >&2; exit 1; }
echo "前置全绿，可开始：./x96max/rebuild-from-zero.sh"

#!/usr/bin/env bash
# preflight.sh — 从零重建前的只读自检（X96max.md §0.2 第 0 步）
# 只检查前置，不改任何文件；任何一项 FAIL 就不要往下走。
#
#   ./x96max/preflight.sh             # 查全量套（config-7.2.12-x96-full + src-full 按需解压）
#   ./x96max/preflight.sh --trim      # 查裁剪套（config-7.2.12-x96-trim + src-trim，名字自动找）
#   ./x96max/full/preflight.sh        # 两套固定入口
#   ./x96max/trim/preflight.sh
#   X96_BUILD_ROOT=/other ./x96max/preflight.sh
#   X96_CFG_MODE=trim ./x96max/preflight.sh    # 等价于 --trim
#
# 退出码：0=全过；1=有 FAIL（逐条打印）
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SELF_DIR/lib/mode.sh"

M=${X96_CFG_MODE:-full}
for a in "$@"; do case $a in --trim) M=trim ;; --full) M=full ;; --mode=*) M=${a#*=} ;; esac; done
x96_mode "$M" || exit 2
S=$KSRC
CFG2=$CFG_ARCHIVE
SRC_XZ=/opt/linux/src/linux-$KV.tar.xz

P=0; F=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; P=$((P+1));
       else printf '  FAIL %s\n' "$1"; F=$((F+1)); fi; }

echo "== preflight: MODE=$MODE KNAME=$KNAME ROOT=$ROOT =="
x96_mode_show | sed 's/^/   /'

# --- 源码树 ---
# full：树不是必备资产，缺了 x96_ensure_src 会从源码包现解压（约 9s / 1.8G），
#       所以这里只要求「包在」，树在场时才做内容抽检。
# trim：裁剪树是「解压+裁剪」的产物，解压还原不出来 → 必须存在（x96_pick_trim_src 自动找）。
ck "源码包 $SRC_XZ"                 "test -f $SRC_XZ"
if [[ -f $S/Makefile ]]; then
  ck "源码树 $S 已就绪"             "test -d $S"
  ck "drivers/usb/storage 目录"     "test -d $S/drivers/usb/storage"
  ck "Kconfig 钩子 source storage"  "grep -q 'storage/Kconfig' $S/drivers/usb/Kconfig"
  ck "Makefile 钩子 obj USB_STORAGE" "grep -q 'CONFIG_USB_STORAGE.*storage/' $S/drivers/usb/Makefile"
  [[ $MODE == full && -f $S/.x96-extracted ]] && echo "  note $S 是解压缓存（可删，编前会再现解压）"
else
  if [[ $MODE == full ]]; then
    echo "  ok   源码树 $S 缺席 → 开跑时从源码包现解压"
  else
    ck "裁剪源码树 $S 存在"         "test -d $S"
  fi
fi
if [[ $MODE == trim ]]; then
  ck "裁剪痕迹（trim-tools 标记）"   "test -f $S/.trimmed || test -f $ROOT/trim-tools/disable.list"
fi

# --- 配置（唯一入口：x96max/kernel/config-$KV-x96-$MODE）---
ck "配置存在 $CFG"                  "test -f $CFG"
LV=$(printf 'CONFIG_LOCALVERSION="-%s"' "${KNAME#$KV-}")
ck "CONFIG_LOCALVERSION=$LV 对得上 KNAME=$KNAME" "grep -qxF '$LV' '$CFG'"
ck "CONFIG_USB_STORAGE=y"           "grep -qx CONFIG_USB_STORAGE=y $CFG"
ck "FAT/MSDOS/VFAT 三连 =y"         "[ \$(grep -cE '^CONFIG_(FAT_FS|MSDOS_FS|VFAT_FS)=y' $CFG) = 3 ]"
ck "归档存在 $CFG2"                 "test -f $CFG2"
ck "两份配置同源（diff -q）"        "diff -q $CFG $CFG2"

# --- 裁剪审计（trim 套；build-kernel/rebuild-from-zero 开跑前也拦一次）---
if [[ $MODE == trim && -d $S ]]; then
  ck "裁剪审计 audit_stubs.py（无活符号住空壳目录）" \
     "KTREE=$S KCFG=$CFG python3 $HOME/kernel/tools/trim/audit_stubs.py"
fi

# --- 素材与工具链 ---
for t in aarch64-linux-gnu-gcc qemu-aarch64-static mkimage zstd sudo; do
  ck "工具 $t"                      "command -v $t"
done

# --- 脚本可执行 ---
for s in rebuild-from-zero.sh pack-kernel.sh write-card.sh patch-bootargs.sh lib/mode.sh; do
  ck "存在 $s"                      "test -f $SELF_DIR/$s"
done
for s in preflight build-kernel pack-kernel rebuild-from-zero build-image; do
  ck "两套入口 $s.sh（full/trim）" "test -f $SELF_DIR/full/$s.sh && test -f $SELF_DIR/trim/$s.sh"
done
ck "patch-bootargs 支持 --usb-fix"  "grep -q -- '--usb-fix' $SELF_DIR/patch-bootargs.sh"

# --- 参数解析：`--mode <v>` 分离写法必须真的吃值 ---
# 三个脚本用 `for a in "$@"` 遍历，里面 shift 跳不过下一轮迭代项，裸值会被当成
# 多余参数再扫一遍（pack-kernel 曾因此让 19.5 阶段直接报「多余参数: trim」）。
# 用 -n/--dry-run 真跑一遍解析路径：退出码 0 且输出里 MODE=trim 才算过。
for s in pack-kernel build-kernel; do
  ck "$s.sh --mode trim -n 解析正确" \
     "out=\$($SELF_DIR/$s.sh --mode trim -n 2>&1) && grep -q 'MODE=trim' <<<\"\$out\""
  ck "$s.sh --mode=trim 等号写法可用" \
     "out=\$($SELF_DIR/$s.sh --mode=trim -n 2>&1) && grep -q 'MODE=trim' <<<\"\$out\""
done
ck "flash-p1.sh --mode trim 解析正确（-n 免 root）" \
   "out=\$($SELF_DIR/flash-p1.sh --mode trim -n 2>&1); grep -q 'MODE=trim' <<<\"\$out\""

echo "== 通过 $P / 失败 $F =="
[[ $F -eq 0 ]] || { echo "有 FAIL：先修前置，别开始重建（见 X96max.md §0.2）" >&2; exit 1; }
echo "前置全绿，可开始：./x96max/$MODE/rebuild-from-zero.sh"

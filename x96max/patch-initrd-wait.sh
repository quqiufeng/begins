#!/usr/bin/env bash
# patch-initrd-wait.sh —— 把 initramfs 里 scripts/local 的等待窗口从 30s 放宽到 90s
#
# 为什么：x96max 用 USB 读卡器启动时，sda 在 t=37.5s 才枚举出来，而
#   init:        starttime=$(_uptime); starttime=$((starttime+1))   # 先记起点
#                if [ "$ROOTDELAY" ]; then sleep "$ROOTDELAY"; fi   # 后睡眠
#   scripts/local: slumber=30
#                if [ "${ROOTDELAY:-0}" -gt $slumber ]; then slumber=$ROOTDELAY; fi
# 即 "超时 = max(30, rootdelay)"，且 sleep 发生在计时窗口**之内**。所以
# rootdelay=15 不会加长等待，只是从 30s 预算里挖掉 15s —— 越调越糟。
#
# 改法：直接抬 slumber。不改 uEnv.txt，不依赖任何启动参数。
#
# 用法：
#   ./x96max/patch-initrd-wait.sh <initrd.img|uInitrd> [-o 输出] [--secs N] [--inplace]
#   给出 uInitrd（uImage，64 字节头）会自动重打包成 uInitrd
#
# 例：sudo ./x96max/patch-initrd-wait.sh /x96-build/initrd.img-7.2.12-x96
#     sudo ./x96max/patch-initrd-wait.sh /media/u/BOOT/uInitrd --inplace
set -euo pipefail

SECS=90
IN=""
OUT=""
INPLACE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -o) OUT=$2; shift 2 ;;
    --secs) SECS=$2; shift 2 ;;
    --inplace) INPLACE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) IN=$1; shift ;;
  esac
done
[[ -n $IN ]] || { echo "用法: $0 <initrd.img|uInitrd> [-o 输出] [--secs N] [--inplace]" >&2; exit 2; }
[[ -f $IN ]] || { echo "没有这个文件: $IN" >&2; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
IMG=$IN
IS_UIMAGE=0

# uImage 头 = 64 字节，magic 0x27051956（大端）
if [[ $(stat -c%s "$IN") -gt 64 ]] && \
   [[ $(xxd -p -l4 "$IN") == 27051956 ]]; then
  IS_UIMAGE=1
  echo "  输入是 u-boot uImage，剥头解压"
  dd if="$IN" of="$WORK/payload.gz" bs=64 skip=1 status=none
  IMG=$WORK/payload.gz
  if ! gzip -t "$IMG" 2>/dev/null; then
    echo "  ⚠ 头部之后不是 gzip（可能是 .xz/.zstd），本脚本只处理 gzip" >&2; exit 1
  fi
fi
TARGET=$WORK/initrd.img
gzip -dc "$IMG" > "$TARGET" || { echo "解压失败" >&2; exit 1; }

mkdir -p "$WORK/root"
( cd "$WORK/root" && cpio -idm --quiet < "$TARGET" ) 2>/dev/null || {
  echo "cpio 解包失败（不是 newc initramfs？）" >&2; exit 1; }

SL=$WORK/root/scripts/local
[[ -f $SL ]] || { echo "initramfs 里没有 scripts/local，跳过" >&2; exit 1; }

OLD=$(grep -oP '^\t+slumber=\K[0-9]+' "$SL" | head -1 || true)
echo "  原 slumber = ${OLD:-未找到}"
if [[ -z ${OLD:-} ]]; then
  echo "⚠ 没匹配到 'slumber=<n>'，initramfs-tools 版本可能变了，人工确认：$SL" >&2; exit 1
fi
sed -i -E "s/^(\t+)slumber=[0-9]+$/\1slumber=$SECS/" "$SL"
NEW=$(grep -oP '^\t+slumber=\K[0-9]+' "$SL" | head -1)
echo "  新 slumber = $NEW"

# 注意：cpio 不能吃 NUL 分隔的名单（要 --null），这里用换行分隔
( cd "$WORK/root" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --quiet ) \
  | gzip -9 > "$WORK/new.gz"
SZ=$(stat -c%s "$WORK/new.gz")
echo "  重打包: $SZ 字节（原 $(stat -c%s "$TARGET")）"
(( SZ > 1048576 )) || { echo "重打包产物过小($SZ)，cpio 出错，未写入任何东西" >&2; exit 1; }

if (( IS_UIMAGE )); then
  command -v mkimage >/dev/null || { echo "缺 mkimage（apt install u-boot-tools）" >&2; exit 1; }
  mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
    -d "$WORK/new.gz" "$WORK/out" >/dev/null
else
  cp "$WORK/new.gz" "$WORK/out"
fi

# 回读自检：改的东西真的在里面
mkdir -p "$WORK/chk"
( cd "$WORK/chk" && if (( IS_UIMAGE )); then dd if="$WORK/out" bs=64 skip=1 status=none | gzip -dc | cpio -idm --quiet; else gzip -dc "$WORK/out" | cpio -idm --quiet; fi ) 2>/dev/null
[[ $(grep -oP '^\t+slumber=\K[0-9]+' "$WORK/chk/scripts/local" | head -1) == "$SECS" ]] \
  || { echo "回读自检失败，未写入任何东西" >&2; exit 1; }
echo "  ✔ 回读自检通过"

if (( INPLACE )); then OUT=$IN; fi
if [[ -z $OUT ]]; then
  OUT=$WORK/out
  echo "  (未给 -o，结果在 $OUT —— 临时目录会被删，请带 -o 或 --inplace)"
  cp "$WORK/out" ./patched-uInitrd 2>/dev/null || true
  OUT=$(pwd)/patched-uInitrd
fi
sudo cp "$WORK/out" "$OUT" 2>/dev/null || cp "$WORK/out" "$OUT"
sync
echo "  → $OUT"
sha256sum "$OUT"

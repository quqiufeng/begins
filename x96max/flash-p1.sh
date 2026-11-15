#!/usr/bin/env bash
# flash-p1.sh — 把新 Image 写进 U 盘/SD 卡的 boot 分区（p1），快速试跑内核用。
#
# 和 write-card.sh 的区别：write-card.sh 写整盘镜像（新卡/换系统），
# 本脚本只替换已启动 U 盘上的内核，几秒完成，用于改配置后的迭代验证。
#
# 用法: sudo ./x96max/flash-p1.sh [新Image路径] [-y|--yes] [-n|--dry-run]
# 定位：默认按 rootfs 分区的 **label（ROOTFS）** 找父磁盘，再写该磁盘的 p1
#       —— 不用猜 /dev/sdX，也不会因为 write-card.sh 重写镜像换了 UUID 就失配。
#       显式给了 X96_ROOT_UUID 时才按 UUID 找（同 label 有多张卡时用它区分）。
#
# 环境变量：
#   X96_ROOT_UUID   按 UUID 精确定位 rootfs（可选；给了就不再按 label 猜）
#   X96_ROOT_LABEL  按 label 定位（默认 ROOTFS，和 write-card.sh 写出的镜像一致）
#   X96_BUILD_ROOT  构建目录（默认 /x96-build）
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SELF_DIR/lib/mode.sh"
M=${X96_CFG_MODE:-full}
ASSUME_YES=0
DRY_RUN=0
ARGS=()
# `--mode <v>` 先归一成 --mode=<v>：下面 for 循环里 shift 不会跳过下一轮的迭代项，
# 裸值会被再扫一遍当多余参数（rebuild-from-zero 的 19.5 阶段就是这么挂的）。
_argv=(); while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) _argv+=("--mode=${2:?--mode 需要 full|trim}"); shift 2 ;;
    *)      _argv+=("$1"); shift ;;
  esac
done; set -- "${_argv[@]}"
for a in "$@"; do case "$a" in
  -y|--yes)   ASSUME_YES=1 ;;
  -n|--dry-run) DRY_RUN=1 ;;
  --trim|-t)  M=trim ;;
  --full)     M=full ;;
  --mode=*)   M=${a#*=} ;;
  *)          ARGS+=("$a") ;;
esac; done
x96_mode "$M" || exit 2
echo "MODE=$MODE KNAME=$KNAME OUT=$OUT"
NEW=${ARGS[0]:-$OUT/arch/arm64/boot/Image}
ROOT_UUID=${X96_ROOT_UUID:-}
ROOT_LABEL=${X96_ROOT_LABEL:-ROOTFS}

[ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 ${ARGS[0]:-}"; exit 1; }
[ -f "$NEW" ] || { echo "找不到新内核: $NEW"; exit 1; }
echo "=== 新内核 ==="; ls -l "$NEW" | awk '{print "  "$5" bytes  "$9}'; sha256sum "$NEW" | sed 's/^/  /'
echo "  usb-storage 字符串数: $(strings "$NEW" | grep -cxE 'usb-storage')"
echo; echo "=== 定位 U 盘 ==="
if [ -n "$ROOT_UUID" ]; then
  HOW="UUID=$ROOT_UUID"; CANDS=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
else
  HOW="LABEL=$ROOT_LABEL"; CANDS=$(blkid -t "LABEL=$ROOT_LABEL" -o device 2>/dev/null || true)
fi
echo "  查找方式: $HOW"
SYS_DISK=$(lsblk -sno NAME "$(findmnt -no SOURCE /)" 2>/dev/null | tail -1 || true)
ROOTDEV=""
for d in $CANDS; do
  [ -b "$d" ] || continue
  pk=$(lsblk -no PKNAME "$d" 2>/dev/null || true); [ -n "$pk" ] || continue
  case "$pk" in loop*) echo "  ! 跳过 $d（父设备是 $pk，镜像挂载不是卡）"; continue ;; esac
  if [ "$pk" = "$SYS_DISK" ]; then echo "  ! 跳过 $d（在系统盘 $pk 上）"; continue; fi
  if [ -n "$ROOTDEV" ]; then
    echo "  X 命中多个候选分区: $ROOTDEV 和 $d" >&2
    echo "    同 label 有多张卡时用 UUID 指定:  X96_ROOT_UUID=$(blkid -o value -s UUID "$ROOTDEV") sudo $0 $NEW" >&2
    exit 1
  fi
  ROOTDEV=$d
done
[ -n "$ROOTDEV" ] || {
  echo "  X 没找到 rootfs 分区（$HOW）——U 盘插好了吗？"
  echo "    换过卡/重写过镜像：默认按 label 找，一般无需设置；"
  echo "    若你的卡 label 不是 $ROOT_LABEL，用 X96_ROOT_LABEL=<label> 或 X96_ROOT_UUID=<uuid> 指定。"
  echo "    当前所有分区的 label/UUID:"
  lsblk -lnpo NAME,LABEL,UUID,FSTYPE | grep -v loop | sed 's/^/      /'
  exit 1
}
echo "  rootfs: $ROOTDEV  (label=$(blkid -o value -s LABEL "$ROOTDEV" 2>/dev/null || echo -) uuid=$(blkid -o value -s UUID "$ROOTDEV" 2>/dev/null || echo -))"
DISK=/dev/$(basename "$(lsblk -no PKNAME "$ROOTDEV")")
echo "  父磁盘: $DISK"; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$DISK" | sed 's/^/    /'
P1=""; for c in "${DISK}p1" "${DISK}1"; do [ -b "$c" ] && P1=$c && break; done
[ -n "$P1" ] || { echo "  X 找不到第一个分区"; exit 1; }
P1FS=$(lsblk -no FSTYPE "$P1" 2>/dev/null | head -1)
echo "  boot 分区: $P1 (${P1FS:-未知})"
[ "$P1FS" = "vfat" ] || echo "  ! 注意：p1 不是 vfat（$P1FS），确认没写错盘"
if [ "$DRY_RUN" = 1 ]; then
  echo; echo "  --dry-run: 只定位不写入。将把"
  echo "    $(ls -l "$NEW" | awk '{print $5}') bytes  $NEW"
  echo "  写进 $P1（备份为 $ROOT/U-backup-Image-<时间戳>）"
  exit 0
fi
if [ "$ASSUME_YES" = 1 ]; then echo "  --yes: 跳过确认"; else
  echo; read -r -p "确认写到 $P1 ? [yes/NO] " ok; [ "$ok" = "yes" ] || { echo "已取消"; exit 1; }
fi
EXIST=$(findmnt -no TARGET "$P1" 2>/dev/null || true)
WE_MOUNTED=0
if [ -n "$EXIST" ]; then MNT=$EXIST; echo "  p1 已挂载于 $MNT，直接用（写完不卸载）"
else MNT=$(mktemp -d); WE_MOUNTED=1; mount "$P1" "$MNT"; fi
cleanup() { [ "$WE_MOUNTED" = 1 ] && umount "$MNT" 2>/dev/null || true; [ "$WE_MOUNTED" = 1 ] && rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
echo "=== 分区内现有文件 ==="; ls -l "$MNT" | sed 's/^/  /'
STAMP=$(date +%Y%m%d-%H%M%S)
for f in Image zImage; do [ -f "$MNT/$f" ] && cp -a "$MNT/$f" "$ROOT/U-backup-$f-$STAMP" && echo "  备份 $f -> $ROOT/U-backup-$f-$STAMP"; done
TARGET=""
if   [ -f "$MNT/Image" ];  then TARGET="$MNT/Image"
elif [ -f "$MNT/zImage" ]; then TARGET="$MNT/zImage"
else TARGET="$MNT/Image"; fi
echo "=== 写入 -> $TARGET ==="; cp "$NEW" "$TARGET"; sync
a=$(sha256sum "$NEW" | cut -d' ' -f1); b=$(sha256sum "$TARGET" | cut -d' ' -f1)
echo "  源: $a"; echo "  盘: $b"; [ "$a" = "$b" ] && echo "  OK 一致" || { echo "  X 不一致"; exit 1; }
echo "=== uInitrd / dtb 在场确认 ==="; ls -l "$MNT"/uInitrd* "$MNT"/dtb 2>/dev/null | sed 's/^/  /' || true
sync; echo; echo "完成。安全卸载后拔 U 盘。"

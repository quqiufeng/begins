#!/usr/bin/env bash
# flash-p1.sh — 把新 Image 写进 U 盘/SD 卡的 boot 分区（p1），快速试跑内核用。
#
# 和 write-card.sh 的区别：write-card.sh 写整盘镜像（新卡/换系统），
# 本脚本只替换已启动 U 盘上的内核，几秒完成，用于改配置后的迭代验证。
#
# 用法: sudo ./x96max/flash-p1.sh [新Image路径]
# 定位：用 rootfs 的 UUID 找父磁盘，再写该磁盘的 p1 —— 不用猜 /dev/sdX。
#
# 环境变量：
#   X96_ROOT_UUID   现有 rootfs 分区 UUID（默认见下，换卡后要改）
#   X96_BUILD_ROOT  构建目录（默认 /x96-build）
set -euo pipefail

ROOT=${X96_BUILD_ROOT:-/x96-build}
KNAME=${X96_KNAME:-7.2.12-x96}
KV=${KNAME%-x96}
NEW=${1:-${X96_KOUT:-$ROOT/kbuild-$KV}/arch/arm64/boot/Image}
ROOT_UUID=${X96_ROOT_UUID:-d764b7d9-bec8-4214-ac1b-165bb24e2ca0}

[ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 ${1:-}"; exit 1; }
[ -f "$NEW" ] || { echo "找不到新内核: $NEW"; exit 1; }
echo "=== 新内核 ==="; ls -l "$NEW" | awk '{print "  "$5" bytes  "$9}'; sha256sum "$NEW" | sed 's/^/  /'
echo "  usb-storage 字符串数: $(strings "$NEW" | grep -cxE 'usb-storage')"
echo; echo "=== 定位 U 盘 ==="
ROOTDEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$ROOTDEV" ] || { echo "  X 没找到 UUID=$ROOT_UUID 的分区——U 盘插好了吗？（换过卡要设 X96_ROOT_UUID）"; exit 1; }
echo "  rootfs: $ROOTDEV"
DISK=/dev/$(basename "$(lsblk -no PKNAME "$ROOTDEV")")
echo "  父磁盘: $DISK"; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$DISK" | sed 's/^/    /'
P1=""; for c in "${DISK}p1" "${DISK}1"; do [ -b "$c" ] && P1=$c && break; done
[ -n "$P1" ] || { echo "  X 找不到第一个分区"; exit 1; }
echo "  boot 分区: $P1 ($(blkid -o value -s FSTYPE "$P1" 2>/dev/null))"
echo; read -r -p "确认写到 $P1 ? [yes/NO] " ok; [ "$ok" = "yes" ] || { echo "已取消"; exit 1; }
MNT=$(mktemp -d); trap 'umount "$MNT" 2>/dev/null||true; rmdir "$MNT" 2>/dev/null||true' EXIT
mount "$P1" "$MNT"
echo "=== 分区内现有文件 ==="; ls -l "$MNT" | sed 's/^/  /'
STAMP=$(date +%Y%m%d-%H%M%S)
for f in Image zImage; do [ -f "$MNT/$f" ] && cp -a "$MNT/$f" "$ROOT/U-backup-$f-$STAMP" && echo "  备份 $f -> $ROOT/U-backup-$f-$STAMP"; done
TARGET=""; [ -f "$MNT/Image" ] && TARGET="$MNT/Image"; [ -z "$TARGET" ] && [ -f "$MNT/zImage" ] && TARGET="$MNT/zImage"
[ -n "$TARGET" ] || TARGET="$MNT/Image"
echo "=== 写入 -> $TARGET ==="; cp "$NEW" "$TARGET"; sync
a=$(sha256sum "$NEW" | cut -d' ' -f1); b=$(sha256sum "$TARGET" | cut -d' ' -f1)
echo "  源: $a"; echo "  盘: $b"; [ "$a" = "$b" ] && echo "  OK 一致" || { echo "  X 不一致"; exit 1; }
echo "=== uInitrd / dtb 在场确认 ==="; ls -l "$MNT"/uInitrd* "$MNT"/dtb 2>/dev/null | sed 's/^/  /' || true
sync; echo; echo "完成。安全卸载后拔 U 盘。"

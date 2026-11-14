#!/usr/bin/env bash
# 自造 rebuild 所需的“基础镜像”容器。
# 为什么需要：ophub rebuild 的 extract_armbian() 只从基础镜像里取一个可挂载的
# ext4 rootfs + /etc/os-release；make_image() 会用 parted 重造整个分区表
# (skip=4MiB / msdos / fat32 boot)。所以不需要官方通用 arm64 镜像，
# 只要一个装了源码 rootfs 的 ext4 分区即可。
set -euo pipefail

ROOT=/x96-build
SIZE_MB=${SIZE_MB:-2560}
OUTIMG=${OUTIMG:-$ROOT/base-own.img}
BOOTBAK=$ROOT/base-boot-backup

ROOTFS=$(ls -1t "$ROOT"/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst 2>/dev/null | head -1 || true)
[[ -n "$ROOTFS" ]] || { echo "missing source-built rootfs (run compile.sh x96-source rootfs)"; exit 1; }
[[ -d "$BOOTBAK" ]] || { echo "missing $BOOTBAK"; exit 1; }
echo "ROOTFS=$ROOTFS"

sudo -n true || { echo "passwordless sudo required"; exit 1; }

rm -f "$OUTIMG"
truncate -s "${SIZE_MB}M" "$OUTIMG"
parted -s "$OUTIMG" mklabel msdos
parted -s "$OUTIMG" mkpart primary ext4 4MiB 100%
LOOP=$(sudo losetup -Pf --show "$OUTIMG")
sleep 1
sudo mkfs.ext4 -q -F -L armbi_root "${LOOP}p1"

MNT=/mnt/x96base
sudo mkdir -p "$MNT"
sudo mount "${LOOP}p1" "$MNT"
zstd -dc "$ROOTFS" | sudo tar -xpf - --numeric-owner --xattrs --xattrs-include='*' -C "$MNT"

# rebuild 会 rm -rf boot/* 后用内核包填充；这里先放基础启动文件，
# 与文档 §19.2 恢复 base-boot-backup 的做法一致。
sudo mkdir -p "$MNT/boot"
sudo rsync -a "$BOOTBAK"/ "$MNT/boot"/
# 源码 rootfs 是空目录结构，rebuild 需要这两个目录存在
sudo mkdir -p "$MNT/usr/lib/modules" "$MNT/usr/src"

echo '--- os-release 校验（rebuild 要 ID / VERSION_CODENAME） ---'
sudo grep -E '^(ID|VERSION_CODENAME)=' "$MNT/etc/os-release"
echo '--- 已装包数 ---'
sudo chroot "$MNT" /usr/bin/qemu-aarch64-static /bin/bash -c "dpkg -l 2>/dev/null | grep -c '^ii'" || true

sudo umount "$MNT"
sudo losetup -d "$LOOP"
echo "BASE=$OUTIMG ($(du -h "$OUTIMG" | cut -f1))"

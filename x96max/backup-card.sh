#!/bin/bash
# 备份一张「已验证可启动」的 U 盘/SD 卡为可还原镜像（只读设备，不写卡）。
#
# 为什么这么做（对应 X96max.md §10.1.3/§10.1.4）：
#  1) 桌面 udisks2 会在 device 事件里把分区 rw 挂上 -> ext4 日志回放 -> 经不稳读路径
#     写回错字节，把垃圾固化成真损坏。所以先关 automount + stop udisks2，trap 恢复。
#  2) 备份的正确性判据不是裸盘 cmp（读卡器大块读会返回相同错字节），而是：
#     把备份解开成 loop -> ro,noload 挂载 -> 与卡上 ro,noload 挂载逐文件 sha256 对拍。
set -euo pipefail

DEV=${1:?用法: backup-card.sh /dev/sdX [输出目录]}
OUT=${2:-/home/quqiufeng/x96-backup/usb-stick-$(date +%Y%m%d-%H%M)}

[ -b "$DEV" ] || { echo "不是块设备: $DEV" >&2; exit 2; }
case "$DEV" in
  *[0-9]) echo "拒绝分区设备 $DEV，要给整盘 /dev/sdX" >&2; exit 2;;
esac

AM=$(gsettings get org.gnome.desktop.media-handling automount 2>/dev/null || echo true)
AMO=$(gsettings get org.gnome.desktop.media-handling automount-open 2>/dev/null || echo true)
restore() {
  gsettings set org.gnome.desktop.media-handling automount "$AM"              2>/dev/null || true
  gsettings set org.gnome.desktop.media-handling automount-open "$AMO"        2>/dev/null || true
  systemctl start udisks2 2>/dev/null || true
}
trap restore EXIT

mkdir -p "$OUT"
sudo gsettings set org.gnome.desktop.media-handling automount false
sudo gsettings set org.gnome.desktop.media-handling automount-open false
sudo systemctl stop udisks2 || true

# 确认没有任何分区挂着
mnt=$(lsblk -lno MOUNTPOINTS "$DEV" 2>/dev/null | grep -v '^$' || true)
[ -z "$mnt" ] || { echo "仍有挂载点，先 umount: $mnt" >&2; exit 2; }
echo "✔ $DEV 未挂载，开始只读备份"

sudo sfdisk -d "$DEV" | tee "$OUT/sdb.sfdisk"

# 前 4MiB 裸区：U-Boot + 分区表，不在任何分区内，必须单独存
sudo dd if="$DEV" of="$OUT/bootarea-4MiB.img" bs=512 count=8192 status=progress
# 分区按分区表逐段读
for n in $(lsblk -lno NAME,PARTN "$DEV" | awk 'NF==2 {print $1}'); do
  echo "--- /dev/$n"
  sudo dd if="/dev/$n" of="$OUT/${n}.img" bs=4M conv=fsync status=progress
done

echo "=== 压缩 ==="
for f in "$OUT"/*.img; do gzip -9 -T0 "$f"; done
( cd "$OUT" && sha256sum ./* > SHA256SUMS && cat SHA256SUMS )
echo "✔ 备份完成: $OUT"

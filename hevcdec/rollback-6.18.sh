#!/bin/bash
# 若 eMMC 上的 7.2.12 起不来：插 SD 卡启动本系统，再跑本脚本
# 用法: bash /root/rollback-6.18.sh [eMMC 的 p1 挂载点，默认自动找]
set -e
M="${1:-}"
if [ -z "$M" ]; then
  for p in /dev/mmcblk2p1 /dev/mmcblk1p1 /dev/sda1; do
    [ -b "$p" ] || continue
    mkdir -p /mnt/emmcboot
    mount -o rw "$p" /mnt/emmcboot 2>/dev/null && { M=/mnt/emmcboot; break; }
  done
fi
[ -n "$M" ] || { echo "找不到 eMMC boot 分区，请手动指定"; exit 1; }
echo "恢复 6.18 到 $M ..."
cp -f "$M/Image.bak-6.18"   "$M/Image"
cp -f "$M/uInitrd.bak-6.18" "$M/uInitrd"
cp -f "$M/dtb/allwinner/sun50i-h618-x98h-100mb.dtb.bak-6.18" \
      "$M/dtb/allwinner/sun50i-h618-x98h-100mb.dtb"
sync
md5sum "$M/Image"
echo "完成，关机拔 SD 卡再上电即为 6.18"

#!/usr/bin/env bash
# 真启动验证：busybox initramfs + virtio-blk ext4，断言挂载成功。
# 用法: tools/trim/verify-boot.sh [bzImage路径]
# 两条硬规矩: ① QEMU 必须 -cpu max（内核按 -march=native 编译）
#             ② init 里必须手动 mount devtmpfs，否则看不到 /dev/vda
set -euo pipefail
BZ=${1:-$HOME/kernel/src/linux-7.2.12/arch/x86/boot/bzImage}
IR=/tmp/trim-ir; IMG=/tmp/trim-disk.img; LOG=/tmp/trim-boot.log

rm -rf "$IR"; mkdir -p "$IR"/{bin,lib,lib64,proc,sys,dev,mnt}
cp "$(command -v busybox)" "$IR/bin/"
for l in $(ldd "$(command -v busybox)" | grep -oE '/[^ ]+\.so[^ ]*'); do
  mkdir -p "$IR$(dirname "$l")"; cp "$l" "$IR$l" 2>/dev/null || true
done
cat > "$IR/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t devtmpfs none /dev
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox echo "=== initramfs up ==="
/bin/busybox mkdir -p /mnt
if /bin/busybox mount -t ext4 /dev/vda /mnt; then echo TEST:EXT4-MOUNT-OK; else echo TEST:EXT4-MOUNT-FAIL; fi
/bin/busybox cat /proc/mounts | /bin/busybox grep vda || true
/bin/busybox echo TEST:DONE
/bin/busybox poweroff -f
INIT
chmod +x "$IR/init"
(cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip -1 > /tmp/trim-initramfs.cpio.gz)

[ -f "$IMG" ] || { dd if=/dev/zero of="$IMG" bs=1M count=32 status=none; mkfs.ext4 -q -F "$IMG"; }

timeout 120 qemu-system-x86_64 -cpu max -kernel "$BZ" -initrd /tmp/trim-initramfs.cpio.gz \
  -drive file="$IMG",if=virtio,format=raw -append "console=ttyS0 rdinit=/init panic=-1" \
  -nographic -no-reboot -m 512 -smp 2 > "$LOG" 2>&1 || true

tr -d '\000' < "$LOG" | grep -aE "Linux version|virtio_blk|8250|EXT4-fs|TEST:" | head -10
if tr -d '\000' < "$LOG" | grep -aq "TEST:EXT4-MOUNT-OK"; then
  echo "== PASS：内核能挂 ext4（virtio-blk + 8250 + initramfs 均正常）=="
else
  echo "== FAIL：见 $LOG =="; exit 1
fi

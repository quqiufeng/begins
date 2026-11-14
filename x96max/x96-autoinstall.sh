#!/bin/sh
set -eu
LOG=/var/log/x96-autoinstall.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) x96-autoinstall ==="

ROOT=$(findmnt -no SOURCE /)
BASE=$(basename "$ROOT" | sed -E 's/p[0-9]+$//')

# Already running from eMMC? skip (and mark done).
if [ -e "/sys/block/$BASE/boot0" ] || [ -e "/sys/block/${BASE}boot0" ]; then
  echo "root is eMMC ($ROOT), skip"
  touch /etc/x96-autoinstall.done
  exit 0
fi

# No eMMC present? skip and retry on next boot.
if ! lsblk -l -o NAME | grep -qE 'mmcblk[0-9]+boot0'; then
  echo "no eMMC found, skip"
  exit 0
fi

if [ -f /etc/x96-autoinstall.done ]; then
  echo "already installed, skip"
  exit 0
fi

sleep 3
echo "running armbian-install -m yes -a no (301 / ext4)"
printf '301\n1\n' | /usr/sbin/armbian-install -m yes -a no

touch /etc/x96-autoinstall.done
sync
echo "=== install done, poweroff ==="
systemctl poweroff

#!/bin/sh
# X96 Max (S905X2) 首启自动装配到 eMMC。
#
# 两个必须记住的坑（都是真机上踩出来的，别"优化"掉）：
#  1) armbian-install 的 check_depends 会 which 9 个命令，缺任何一个就 apt-get
#     update/install。apt-get 会读走我们的 stdin，导致后面的 `read boxid` 拿到
#     EOF -> "Input error, exit!" 或 "DTB file not found"。所以这里先自检依赖，
#     缺就大声报错退出，绝不交给 apt（而且本 service 只在 local-fs.target 之后跑，
#     那时压根没网，apt 装不上）。
#  2) done 标记只能在 armbian-install 真正成功后写。旧版无条件 touch done，
#     装失败也会写道「已完成」然后关机，下次开机直接 skip —— 静默装死。
set -u
LOG=/var/log/x96-autoinstall.log
DONE=/etc/x96-autoinstall.done
# 301 = X96-Max-4GB/Tx5-Max(s905x2, 4GB/1Gb-Nic)；2GB 版用 302。
BOXID=${X96_BOXID:-301}
# 1 = ext4, 2 = btrfs
FILETYPE=${X96_FILETYPE:-1}

exec >>"$LOG" 2>&1
log() { echo "[$(date -Is)] $*"; }
log "=== x96-autoinstall start (boxid=$BOXID filetype=$FILETYPE) ==="

[ -e "$DONE" ] && { log "already installed, skip"; exit 0; }

ROOT=$(findmnt -no SOURCE / 2>/dev/null || echo "")
BASE=$(basename "${ROOT:-none}" | sed -E 's/p[0-9]+$//')
log "root=$ROOT base=$BASE"

# 已经跑在 eMMC 上 = 装好了
if [ -e "/sys/block/$BASE/boot0" ] || [ -e "/sys/block/${BASE}boot0" ]; then
  log "root is eMMC, mark done"
  touch "$DONE"; exit 0
fi

# 没有 eMMC 就下次开机再试，不写 done
if ! lsblk -l -o NAME | grep -qE 'mmcblk[0-9]+boot0'; then
  log "no eMMC boot0 found, retry next boot"
  exit 0
fi

# 依赖自检：宁可报错也不让 apt 吃 stdin
missing=""
for c in hexdump parted mkfs.vfat mkfs.ext4 mkfs.btrfs losetup fdisk lsblk tar dbus-uuidgen ampart; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  msg="x96-autoinstall FATAL: missing tools:$missing (image is broken, re-flash SD)"
  log "$msg"
  echo "$msg" >/dev/tty0 2>/dev/null || true
  exit 1
fi
log "deps ok, eMMC boot0 present"

# 答案从文件喂，不用管道：即使有什么东西读了 stdin 也不会污染这两行
printf '%s\n%s\n' "$BOXID" "$FILETYPE" > /run/x96-answers
sleep 3
log "running: armbian-install -m yes -a no < /run/x96-answers"
# -m yes : 写主线 u-boot。2026-11-14 复查：301 号在 /etc/model_database.conf 里的
#          MAINLINE_UBOOT=x96max-u-boot.bin.sd.bin 在 /usr/lib/u-boot 下确实存在，
#          UBOOT_OVERLOAD=u-boot-x96max.bin 也在 /boot 下。用 -m no 就只还原原厂
#          bootloader，再叠 u-boot.emmc 正是 §7.1-4 记的黑屏组合。
# -a no  : 禁用 ampart（§7.1-3 真机结论；ampart 那条路在这台机上没成功过）
/usr/sbin/armbian-install -m yes -a no < /run/x96-answers
rc=$?
log "armbian-install rc=$rc"

if [ "$rc" -ne 0 ]; then
  log "INSTALL FAILED rc=$rc -> keep going so next boot retries"
  echo "x96-autoinstall FAILED rc=$rc, see $LOG" >/dev/tty0 2>/dev/null || true
  sync
  exit "$rc"
fi

# 成功判定：eMMC 上真的出现了一个 ext4/btrfs 根分区
EMMC=$(lsblk -l -o NAME | grep -oE 'mmcblk[0-9]?boot0' | sed 's/boot0//' | head -1)
if [ -n "$EMMC" ] && blkid "/dev/${EMMC}p2" >/dev/null 2>&1; then
  log "verified eMMC root partition: /dev/${EMMC}p2 -> $(blkid /dev/${EMMC}p2)"
  touch "$DONE"
  sync
  sleep 2
  log "=== done, poweroff ==="
  systemctl poweroff
  exit 0
fi

log "INSTALL REPORTED OK BUT /dev/${EMMC}p2 NOT FOUND -> not marking done"
echo "x96-autoinstall: eMMC root partition missing, not marking done" >/dev/tty0 2>/dev/null || true
exit 1

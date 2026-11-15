#!/bin/bash
# enable-autologin.sh — 给 X96 Max 的 rootfs 打开「免密码自动登录」
#
# 背景：build-image.sh 默认 X96_ROOT_PASSWORD 为空 → root 密码锁定，只能 SSH key。
#       控制台上 `x96src login:` 打 root + 空密码必然失败，看起来像键盘坏了/卡死。
#       本脚本做四件事（幂等，可反复跑）：
#         1) 解锁 root 密码（shadow 密码字段清空 = 空密码，非锁定）
#         2) getty@tty1（HDMI）自动登录 root
#         3) serial-getty@ttyAML0（串口）自动登录 root
#         4) 关掉 armbian-firstlogin，免得自动登录后又被向导拦住
#
# 用法：
#   sudo ./x96max/enable-autologin.sh              # 按 LABEL=ROOTFS 找卡
#   sudo ./x96max/enable-autologin.sh /dev/sdb2    # 显式指定 rootfs 分区
#   X96_ROOT_LABEL=OTHER sudo ./x96max/enable-autologin.sh
#
# 注意：卡要先**拔下来插到这台 PC**，不能在板子上跑的时候改（会写坏）。
set -euo pipefail

LABEL="${X96_ROOT_LABEL:-ROOTFS}"
USER_NAME="${X96_AUTOLOGIN_USER:-root}"

DEV="${1:-}"
if [ -z "$DEV" ]; then
  DEV=$(blkid -L "$LABEL" 2>/dev/null || true)
  [ -n "$DEV" ] || {
    echo "X 没找到 LABEL=$LABEL 的分区。"
    echo "  → 把 U 盘/SD 卡插到这台 PC 再跑，或显式给设备：$0 /dev/sdX2"
    echo "  → 当前可见分区："
    lsblk -o NAME,SIZE,LABEL,FSTYPE | grep -v loop || true
    exit 1
  }
fi
[ -b "$DEV" ] || { echo "X $DEV 不是块设备"; exit 1; }

echo "rootfs 分区: $DEV"

sudo -n true 2>/dev/null || { echo "X 需要免密码 sudo"; exit 1; }

TMPMNT=0
MNT=$(findmnt -no TARGET "$DEV" 2>/dev/null | head -1 || true)
if [ -z "$MNT" ]; then
  MNT=$(mktemp -d)
  sudo mount "$DEV" "$MNT"
  TMPMNT=1
  trap 'sudo umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT
fi
echo "挂载点: $MNT"

[ -f "$MNT/etc/shadow" ] || { echo "X $DEV 里没有 /etc/shadow，不是 rootfs"; exit 1; }
[ -f "$MNT/etc/os-release" ] || { echo "X $DEV 里没有 /etc/os-release，不是 rootfs"; exit 1; }

# ---- 0) 先看清楚现在是什么状态 ----
echo
echo "=== 改之前 ==="
sudo grep -E "^${USER_NAME}:" "$MNT/etc/shadow" | cut -d: -f1,2 | sed 's/:.*\$/:\$6\$...（有密码）/' || true
sudo systemctl --root="$MNT" is-enabled "getty@tty1.service" 2>/dev/null || true

# ---- 1) 解锁 root 密码：密码字段清空（空密码，不是 ! 锁定）----
# shadow 格式：name:passwd:lastchg:min:max:warn:inactive:expire:reserved
sudo cp -a "$MNT/etc/shadow" "$MNT/etc/shadow.bak.x96"
sudo awk -F: -v u="$USER_NAME" 'BEGIN{OFS=":"} $1==u{$2=""} {print}' \
  "$MNT/etc/shadow.bak.x96" | sudo tee "$MNT/etc/shadow" >/dev/null
sudo chmod 640 "$MNT/etc/shadow"
sudo chown 0:42 "$MNT/etc/shadow" 2>/dev/null || sudo chown 0:0 "$MNT/etc/shadow"
echo "✓ root 密码已清空（空密码登录），备份在 /etc/shadow.bak.x96"

# ---- 2) HDMI 控制台自动登录 ----
D="$MNT/etc/systemd/system/getty@tty1.service.d"
sudo mkdir -p "$D"
sudo tee "$D/autologin.conf" >/dev/null <<EOF
# x96max/enable-autologin.sh — HDMI 控制台免密码自动登录
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
EOF
echo "✓ getty@tty1 自动登录 ${USER_NAME}"

# ---- 3) 串口控制台自动登录（console=ttyAML0）----
D2="$MNT/etc/systemd/system/serial-getty@ttyAML0.service.d"
sudo mkdir -p "$D2"
sudo tee "$D2/autologin.conf" >/dev/null <<EOF
# x96max/enable-autologin.sh — 串口控制台免密码自动登录
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\\\u' --autologin ${USER_NAME} --keep-baud 115200,38400,9600 %I \$TERM
EOF
echo "✓ serial-getty@ttyAML0 自动登录 ${USER_NAME}"

# ---- 4) 关掉 Armbian 首启向导（否则自动登录后会卡在改密码/建用户）----
for u in armbian-firstlogin armbian-firstrun armbian-firstrun-config; do
  if [ -e "$MNT/etc/systemd/system/$u.service" ] || [ -e "$MNT/lib/systemd/system/$u.service" ]; then
    sudo ln -sf /dev/null "$MNT/etc/systemd/system/$u.service"
    echo "✓ 屏蔽 $u.service"
  fi
done
for f in armbian-check-first-login.sh armbian-firstlogin.sh; do
  if [ -f "$MNT/etc/profile.d/$f" ]; then
    sudo mv "$MNT/etc/profile.d/$f" "$MNT/etc/profile.d/$f.disabled"
    echo "✓ 停用 /etc/profile.d/$f"
  fi
done

# ---- 5) 确保 getty 已启用 ----
sudo systemctl --root="$MNT" enable "getty@tty1.service" 2>/dev/null || \
  sudo ln -sf /lib/systemd/system/getty@.service "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || \
  { sudo mkdir -p "$MNT/etc/systemd/system/getty.target.wants"; sudo ln -sf /lib/systemd/system/getty@.service "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service"; }
echo "✓ getty@tty1 已 enable"

# ---- 6) 顺手把内核日志压下去，免得 login 提示被刷掉 ----
UENV_FOUND=no
for p in "$MNT/../uEnv.txt" "$MNT/uEnv.txt"; do :; done
BOOTDEV=$(lsblk -no PKNAME "$DEV" | head -1)
if [ -n "$BOOTDEV" ] && [ -b "/dev/${BOOTDEV}1" ]; then
  BM=$(mktemp -d)
  if sudo mount -o ro "/dev/${BOOTDEV}1" "$BM" 2>/dev/null; then
    if [ -f "$BM/uEnv.txt" ]; then
      UENV_FOUND=yes
      if grep -qE '^APPEND=.*quiet' "$BM/uEnv.txt"; then
        echo "✓ uEnv.txt 已有 quiet，跳过"
      else
        echo "! uEnv.txt 里 APPEND 没有 quiet —— boot 分区是只读挂的，"
        echo "  想安静启动就跑： sudo ./x96max/patch-bootargs.sh quiet loglevel=3"
      fi
    fi
    sudo umount "$BM"
  fi
  rmdir "$BM" 2>/dev/null || true
fi

# ---- 验收 ----
echo
echo "=== 改之后 ==="
sudo grep -E "^${USER_NAME}:" "$MNT/etc/shadow" | cut -d: -f1,2 | sed 's/^\([^:]*\):$/\1:（空密码，可登录）/'
sudo find "$MNT/etc/systemd/system" -name 'autologin.conf' | sed "s|$MNT||"
echo
echo "✓ 完成。拔卡插回盒子重启，应该直接进 shell（有 '# ' 提示符），不用打任何字。"

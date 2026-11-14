#!/usr/bin/env bash
# Reproducible X96 Max (S905X2) source-built image with first-boot auto-install.
#
# Usage:
#   x96max/build-image.sh                 # rebuild rootfs + image
#   x96max/build-image.sh --skip-rootfs   # reuse newest rootfs artifact
#   x96max/build-image.sh --skip-rootfs --write /dev/sdX
#
# Environment:
#   X96_BUILD_ROOT       build workspace (default: /data/x96-build)
#   X96_BASE_IMAGE       generic arm64 Armbian trixie image (default below)
#   X96_ROOT_PASSWORD    root password (default: empty = lock password;
#                        set only when console password login is needed)
#   X96_ROOT_SSH_KEY     public key to install for root (default: ~/.ssh/id_ed25519.pub)
#
# Prerequisites:
#   - kernel 7.2.12-x96 four packages under $OPHUB/build-armbian/kernel/stable/7.2.12/
#   - generic arm64 Armbian trixie base image
#   - Armbian build framework at $ROOT/armbian-build
#   - sudo (loop mounts + rebuild + dd)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${X96_BUILD_ROOT:-/data/x96-build}
ARMBIAN=$ROOT/armbian-build
OPHUB=$ROOT/amlogic-s9xxx-armbian
KERNEL=7.2.12
KNAME=${KERNEL}-x96
BOARD=s905x2
BASE=${X96_BASE_IMAGE:-$OPHUB/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img}
BOOTBAK=$ROOT/base-boot-backup
AUTO=$SCRIPT_DIR/x96-autoinstall.sh
UNIT=$SCRIPT_DIR/x96-autoinstall.service
ROOT_PASSWORD=${X96_ROOT_PASSWORD-}
ROOT_SSH_KEY=${X96_ROOT_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}
OUT=$ROOT/recovery

SKIP_ROOTFS=no
WRITE_DEV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-rootfs) SKIP_ROOTFS=yes ;;
    --write) WRITE_DEV=${2:?missing device}; shift ;;
    *) echo "usage: $0 [--skip-rootfs] [--write /dev/sdX]"; exit 1 ;;
  esac
  shift
done

mkdir -p "$OUT" "$BOOTBAK"

sudo -n true 2>/dev/null || { echo "passwordless sudo is required"; exit 1; }
[[ -x "$ARMBIAN/compile.sh" ]] || { echo "missing Armbian build framework: $ARMBIAN"; exit 1; }
[[ -x "$OPHUB/rebuild" ]] || { echo "missing ophub rebuild: $OPHUB"; exit 1; }
[[ -f "$BASE" ]] || { echo "missing base image: $BASE"; echo "set X96_BASE_IMAGE to a generic arm64 Armbian trixie image"; exit 1; }
[[ -f "$ROOT_SSH_KEY" ]] || { echo "missing root SSH public key: $ROOT_SSH_KEY"; exit 1; }
[[ -f "$AUTO" && -f "$UNIT" ]] || { echo "missing auto-install files next to this script"; exit 1; }
[[ -f "$SCRIPT_DIR/config-x96-source.conf" ]] || { echo "missing config-x96-source.conf"; exit 1; }

K=$OPHUB/build-armbian/kernel/stable/$KERNEL
for p in boot dtb-amlogic modules header; do
  [[ -f "$K/${p}-${KNAME}.tar.gz" ]] || {
    echo "missing kernel package: $K/${p}-${KNAME}.tar.gz"
    echo "run the kernel compile/package steps first"
    exit 1
  }
done

if [[ "$SKIP_ROOTFS" == no ]]; then
  install -m 644 "$SCRIPT_DIR/config-x96-source.conf" "$ARMBIAN/userpatches/config-x96-source.conf"
  (cd "$ARMBIAN" && ./compile.sh x96-source rootfs)
fi

ROOTFS=$(ls -1t "$ARMBIAN"/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst 2>/dev/null | head -1 || true)
[[ -n "$ROOTFS" ]] || { echo "missing source-built rootfs artifact"; exit 1; }
echo "ROOTFS=$ROOTFS"

# 1) Replace the base image's rootfs with the source-built rootfs.
LOOP=$(sudo losetup -Pf --show "$BASE")
sleep 1
sudo mkdir -p /mnt/base-root
sudo mount "${LOOP}p1" /mnt/base-root
sudo rsync -a /mnt/base-root/boot/ "$BOOTBAK"/
sudo find /mnt/base-root -mindepth 1 -maxdepth 1 -exec rm -rf {} +
zstd -dc "$ROOTFS" | sudo tar -xpf - --numeric-owner --xattrs --xattrs-include='*' -C /mnt/base-root
sudo rsync -a "$BOOTBAK"/ /mnt/base-root/boot/
sudo mkdir -p /mnt/base-root/usr/lib/modules /mnt/base-root/usr/src

# 2) SSH / network / hostname / root password.
if [[ -n "$ROOT_PASSWORD" ]]; then
  HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
  PASSWORD_AUTH=yes
else
  HASH='!'
  PASSWORD_AUTH=no
fi
sudo mkdir -p /mnt/base-root/root/.ssh
sudo cp "$ROOT_SSH_KEY" /mnt/base-root/root/.ssh/authorized_keys
sudo chmod 700 /mnt/base-root/root/.ssh
sudo chmod 600 /mnt/base-root/root/.ssh/authorized_keys
sudo sed -i "s|^root:[^:]*:|root:${HASH}:|" /mnt/base-root/etc/shadow
sudo mkdir -p /mnt/base-root/etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication %s\n' "$PASSWORD_AUTH" | sudo tee /mnt/base-root/etc/ssh/sshd_config.d/10-x96.conf >/dev/null
sudo mkdir -p /mnt/base-root/etc/systemd/network
printf '[Match]\nName=eth0\n[Network]\nDHCP=yes\n' | sudo tee /mnt/base-root/etc/systemd/network/20-eth.network >/dev/null
sudo mkdir -p /mnt/base-root/etc/systemd/system/multi-user.target.wants
sudo ln -sf /usr/lib/systemd/system/systemd-networkd.service /mnt/base-root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
sudo ln -sf /usr/lib/systemd/system/systemd-resolved.service /mnt/base-root/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
sudo ln -sf /usr/lib/systemd/system/ssh.service /mnt/base-root/etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
sudo ln -sf /dev/null /mnt/base-root/etc/systemd/system/armbian-firstrun.service 2>/dev/null || true
sudo ln -sf /dev/null /mnt/base-root/etc/systemd/system/armbian-firstrun-config.service 2>/dev/null || true
echo x96src | sudo tee /mnt/base-root/etc/hostname >/dev/null
sudo mkdir -p /mnt/base-root/etc
echo '127.0.1.1 x96src' | sudo tee -a /mnt/base-root/etc/hosts >/dev/null
: | sudo tee /mnt/base-root/etc/machine-id >/dev/null
echo 'LANG=C.UTF-8' | sudo tee /mnt/base-root/etc/default/locale >/dev/null
echo 'LANG=C.UTF-8' | sudo tee /mnt/base-root/etc/locale.conf >/dev/null

# 3) apt: tuna IPv4, disable Armbian repos for fast Debian installs.
sudo mkdir -p /mnt/base-root/etc/apt/sources.list.d /mnt/base-root/etc/apt/apt.conf.d
sudo tee /mnt/base-root/etc/apt/sources.list.d/debian.sources >/dev/null <<'EOF'
Types: deb
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
echo 'Acquire::ForceIPv4 "true";' | sudo tee /mnt/base-root/etc/apt/apt.conf.d/99force-ipv4 >/dev/null

# 4) First-boot auto-install service.
sudo install -m 755 "$AUTO" /mnt/base-root/usr/local/sbin/x96-autoinstall.sh
sudo install -m 644 "$UNIT" /mnt/base-root/etc/systemd/system/x96-autoinstall.service
sudo ln -sf /etc/systemd/system/x96-autoinstall.service /mnt/base-root/etc/systemd/system/multi-user.target.wants/x96-autoinstall.service

# 4b) rootfs-minimal 不自带 hexdump（bsdextrautils）。2026-11-14 首启安装就是被它整条静默掐死的：
#     x96-autoinstall.sh 的依赖自检 exit 1（只留一行日志 + tty0），而 armbian-install 的
#     check_depends 也 which hexdump（第 84 行）、200/352 行真的用它读 zImage/u-boot 魔数。
#     从 deb 直接解文件喂进去，不走 chroot apt：不依赖网络策略、也不碰首启的 stdin。
if [[ ! -x /mnt/base-root/usr/bin/hexdump ]]; then
  HXDEB=$(mktemp -d)
  HXURL="http://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/u/util-linux"
  HXFN=$(curl -sf "$HXURL/" | grep -oE 'bsdextrautils_[^"]*_arm64\.deb' | sort -V | tail -1)
  [[ -n "$HXFN" ]] || { echo "cannot locate bsdextrautils arm64 deb"; exit 1; }
  curl -sfL -o "$HXDEB/x.deb" "$HXURL/$HXFN" || { echo "download failed: $HXFN"; exit 1; }
  dpkg-deb -x "$HXDEB/x.deb" "$HXDEB/root"
  sudo install -m 755 -o root -g root "$HXDEB/root/usr/bin/hexdump" /mnt/base-root/usr/bin/hexdump
  rm -rf "$HXDEB"
  echo "installed hexdump ($HXFN)"
fi

# 4c) 构建期断言（rootfs 侧）：这些工具必须来自源码 rootfs —— rebuild 之后没人会补它们。
#     ampart / armbian-install 不在这里：它们是 ophub 的 platform-files/amlogic/rootfs 在
#     rebuild 阶段注入的，源码 rootfs 里本来就没有（查它们要等第 6 步，见 6b）。
assert_tools() {
  local root=$1 label=$2 c d found missing=""
  shift 2
  for c in "$@"; do
    found=""
    for d in usr/bin usr/sbin bin sbin; do
      [[ -x "$root/$d/$c" ]] && { found=1; break; }
    done
    [[ -n "$found" ]] || missing="$missing $c"
  done
  if [[ -n "$missing" ]]; then
    echo "$label missing tools:$missing (first-boot autoinstall would die silently)"
    exit 1
  fi
  echo "$label tools ok: $*"
}
ROOTFS_TOOLS=(hexdump parted mkfs.vfat mkfs.ext4 mkfs.btrfs losetup fdisk lsblk tar dbus-uuidgen)
assert_tools /mnt/base-root rootfs "${ROOTFS_TOOLS[@]}"

sudo umount /mnt/base-root
sudo losetup -d "$LOOP"

# 5) ophub rebuild with the self-built kernel.
(cd "$OPHUB" && sudo ./rebuild -b "$BOARD" -k "$KERNEL" -s 512/2560 -n x96src)

GZ=$(ls -1t "$OPHUB"/build/output/images/Armbian_*_${BOARD}_*_${KERNEL}_server_*.img.gz 2>/dev/null | head -1 || true)
[[ -n "$GZ" ]] || { echo "rebuild produced no image"; exit 1; }
echo "REBUILT=$GZ"
RAW=$OUT/x96src-autoinstall.img
gzip -dc "$GZ" > "$RAW"

# 6) Prune firmware/docs/headers in the final image; keep installer tools.
LOOP=$(sudo losetup -Pf --show "$RAW")
sleep 1
sudo mkdir -p /mnt/final-root
sudo mount "${LOOP}p2" /mnt/final-root
sudo rm -rf /mnt/final-root/usr/share/doc/* /mnt/final-root/usr/share/man/* \
  /mnt/final-root/usr/share/info/* /mnt/final-root/usr/share/locale/* \
  /mnt/final-root/usr/share/fonts/* /mnt/final-root/usr/share/i18n/* \
  /mnt/final-root/usr/share/groff/* /mnt/final-root/usr/share/perl/* 2>/dev/null || true
sudo rm -rf /mnt/final-root/usr/src/linux-headers-* 2>/dev/null || true
sudo rm -f "/mnt/final-root/usr/lib/modules/${KNAME}/build" \
  "/mnt/final-root/usr/lib/modules/${KNAME}/source" 2>/dev/null || true
(cd /mnt/final-root/lib/firmware && for d in *; do
  [ -d "$d" ] || continue
  case "$d" in rtl_nic|amlogic|meson) ;; *) sudo rm -rf "$d" ;; esac
done)
sudo rm -rf /mnt/final-root/var/cache/apt/* /mnt/final-root/var/lib/apt/lists/* \
  /mnt/final-root/tmp/* /mnt/final-root/var/log/* 2>/dev/null || true
sudo mv /mnt/final-root/etc/apt/sources.list.d/armbian.sources \
  /mnt/final-root/etc/apt/sources.list.d/armbian.sources.disabled 2>/dev/null || true
sudo mv /mnt/final-root/etc/apt/sources.list.d/armbian-config.sources \
  /mnt/final-root/etc/apt/sources.list.d/armbian-config.sources.disabled 2>/dev/null || true
sudo rm -f /mnt/final-root/etc/x96-autoinstall.done
sudo mkdir -p /mnt/final-root/etc/systemd/system/multi-user.target.wants
sudo ln -sf /etc/systemd/system/x96-autoinstall.service /mnt/final-root/etc/systemd/system/multi-user.target.wants/x96-autoinstall.service
# 6b) 交付镜像断言：这里是唯一「盒子上会真的跑的那份 rootfs」。ampart / armbian-install 到这一步
#     才存在（ophub rebuild 注入 platform-files），所以断言放这儿；顺带钉死 -m yes 与「没有 done 标记」，
#     这两条一破就是首启静默装死或黑屏。
assert_tools /mnt/final-root "final image" "${ROOTFS_TOOLS[@]}" ampart armbian-install
sudo grep -q -- 'armbian-install -m yes -a no' /mnt/final-root/usr/local/sbin/x96-autoinstall.sh \
  || { echo "final image: x96-autoinstall.sh is not 'armbian-install -m yes -a no'"; exit 1; }
if sudo test -e /mnt/final-root/etc/x96-autoinstall.done; then
  echo "final image: /etc/x96-autoinstall.done must not exist"; exit 1
fi
echo "final image assertions ok"
sudo umount /mnt/final-root
sudo losetup -d "$LOOP"

gzip -9 -f "$RAW"
echo "IMAGE=$RAW.gz"

if [[ -n "$WRITE_DEV" ]]; then
  [[ -b "$WRITE_DEV" ]] || { echo "not a block device: $WRITE_DEV"; exit 1; }
  gzip -dc "$RAW.gz" | sudo dd of="$WRITE_DEV" bs=4M status=progress conv=fsync
  sync
  echo "WROTE=$WRITE_DEV"
fi

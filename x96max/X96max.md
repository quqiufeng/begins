# X96 Max（Amlogic S905X2）— 硬件记录与源码构建/刷机流程

> 设备：X96 Max 4GB（AMedia X96 Max / Amlogic S905X2）
> 主机名：`x96src`；局域网 IP：`192.168.1.121`（DHCP，可能变化）
> 当前系统：eMMC 上的**源码构建 + 裁剪 rootfs**（Armbian build framework + mmdebstrap，Armbian 26.8.3 trixie，155 包）+ 自编译 `7.2.12-x96`（主线 U-Boot）；原商家系统为 Debian 12 bookworm + `6.12.112-ophub`。
> 本文目标：记录硬件、现有系统打包方式，以及**从 Linux 7.2.12 源码编译内核 → 源码构建 rootfs → ophub 打包 → SD/U 盘验证 → eMMC 安装 → 体积裁剪** 的完整过程。
> 状态：**已成功从 eMMC 启动裁剪后的源码系统**（155 包，rootfs ~568M；主线 U-Boot；Wi-Fi/蓝牙关闭，只保留有线网络）。
> 仓库脚本：`x96max/`（一键镜像脚本、rootfs 配置、首启自动安装、最终内核配置）。

---

## 1. 硬件配置

| 项目 | 实测值 |
|---|---|
| 型号 | X96 Max（DTB `meson-g12a-x96-max.dtb`，compatible `amediatech,x96-max` / `amlogic,g12a`） |
| SoC | Amlogic S905X2，4×Cortex-A53（aarch64，`meson-g12a`） |
| GPU | Mali-G31（Panfrost，`panfrost ffe40000.gpu`） |
| 内存 | 4GB 标称，Linux 可见约 3.24GiB（`MemTotal 3397224 kB`） |
| 存储 | eMMC 64GB（`064G30`，58.2GiB / 122142720 sectors），`mmcblk2`，另有 `mmcblk2boot0/1` 各 4MiB |
| 有线网卡 | Amlogic `meson8b-dwmac`（Synopsys DWMAC1000），外置 **RTL8211F** PHY，1Gbps |
| 无线 | **RTL8822BS**（SDIO `024c:b822`），Wi-Fi + 蓝牙二合一；本项目**不使用** |
| 显示 | `meson-dw-hdmi`（HDMI TX v2.01a），DRM `meson-drm`，支持 1920×1080 |
| 音频 | `axg-sound-card`（`X96-MAX`），AXG TDM/SPDIF + G12A TOHDMITX/TOACODEC |
| 视频硬解 | `meson_vdec`（V4L2 mem2mem） |
| USB | USB 3.0 ×1（5000M，1 port）+ USB 2.0 ×2（480M，2 ports），`dwc3-meson-g12a` + xHCI |
| 红外 | `meson_ir`（服务器用途可禁用） |
| RTC | `meson-vrtc`（`ff8000a8.rtc`，掉电不保时） |
| 温度 | 空闲约 35–49°C |
| 以太网 MAC | `02:00:00:10:25:01`（`ethtool -P` 永久地址；内核 cmdline 另有 `mac=90:0e:b3:10:cc:69`，未生效） |
| Wi-Fi MAC | `c4:3a:35:58:ce:bc`（不使用） |

USB 拓扑实测：

```text
Bus 002: xhci-hcd/1p, 5000M   （USB 3.0）
Bus 001: xhci-hcd/2p, 480M    （USB 2.0）
```

---

## 2. 当前系统与 ophub 打包方式

### 2.1 系统信息

| 项目 | 值 |
|---|---|
| 发行版 | Armbian OS 26.11.0（ophub 重打包） |
| 用户态 | Debian 12.15 bookworm |
| 内核 | `6.12.112-ophub` |
| 默认包数量 | 约 484 个（含编译工具链、文档、`armbian-config`、`zsh`、`aptitude` 等，未裁剪） |
| SSH | `root@192.168.1.120`，已配置免密（`~/.ssh/config` 的 `Host x96`） |
| 凭据 | 密码保存在 `~/.env` 的 `X96_PASS`；**不要写进仓库文档** |

### 2.2 为什么“官方 Armbian 不支持但能跑”

X96 Max 不在官方 Armbian 的板型列表里。商家使用的是社区项目：

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)

它的流程是：

```text
官方 Armbian 通用镜像（如 Odroidn2）
        ↓
ophub rebuild：替换 U-Boot/DTB/内核/启动脚本
        ↓
X96 Max 可启动镜像
```

盒子上的文件可以证明：

```text
/etc/armbian.txt     → Board: Odroidn2
/etc/ophub-release   → MODEL_ID=301, MODEL_NAME=X96-Max-4GB, SOC=s905x2
                       KERNEL_REPO=ophub/kernel
                       REBUILD_REPOSITORY=github.com/ophub/amlogic-s9xxx-armbian
                       FDTFILE=meson-g12a-x96-max.dtb
                       UBOOT_OVERLOAD=u-boot-x96max.bin
```

因此：**盒子由 ophub 支持，不是官方 Armbian 原生板型**。我们复现时使用同一套 ophub 流程。

### 2.3 当前分区与启动

**原厂（商家）布局**：

```text
/dev/mmcblk2      58.2G
├─ mmcblk2p1      511M  FAT32  /boot      start=239616 sectors（约 117MiB）
└─ mmcblk2p2      57.6G ext4   /          start=1288192 sectors
```

**安装主线 U-Boot 后的当前布局**（`armbian-install -m yes -a no`）：

```text
/dev/mmcblk1      58.2G
├─ mmcblk1p1      511M  FAT32 BOOT_EMMC   /boot   start=139264 sectors（68MiB）
└─ mmcblk1p2      56.9G ext4  ROOTFS_EMMC /       start=2764800 sectors（1350MiB）
```

- 原厂布局前约 117MiB 是 Amlogic U-Boot/启动链保留区。
- 主线 U-Boot 位于 eMMC 起始区；原厂启动区备份在 `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`。

`/boot` 关键文件：

```text
uEnv.txt                          启动参数
zImage / vmlinuz-7.2.12-x96       当前内核
uInitrd / initrd.img-...          initramfs
dtb/amlogic/meson-g12a-x96-max.dtb
u-boot.emmc                       6.x+ 内核重载 U-Boot（主线安装时会生成）
u-boot-x96max.bin                 原厂/overload U-Boot
u-boot.sd / u-boot.usb            SD/USB U-Boot
emmc_autoscript                   从 eMMC 拉起
boot.scr                          启动脚本
```

`uEnv.txt` 示例：

```text
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/meson-g12a-x96-max.dtb
APPEND=root=UUID=<uuid> rootflags=data=writeback rw rootfstype=ext4 \
       console=ttyAML0,115200n8 console=tty0 ... video=HDMI-A-1:1920x1080@60e
```

---

## 3. 驱动映射（有线-only）

| 硬件 | Linux 驱动 | 内核配置 |
|---|---|---|
| SoC / 时钟 | `meson-g12a` | `CONFIG_COMMON_CLK_MESON_*`、`CONFIG_PINCTRL_MESON_G12A` |
| 有线网卡 | `meson8b-dwmac` / `stmmac` | `CONFIG_STMMAC_ETH=y`、`CONFIG_DWMAC_MESON=y` |
| 以太网 PHY | RTL8211F | `CONFIG_REALTEK_PHY=y`、`CONFIG_MDIO_BUS_MUX_MESON_G12A=y` |
| eMMC/SD/SDIO | `meson-gx-mmc` | `CONFIG_MMC_MESON_GX=y` |
| HDMI / DRM | `meson-drm` + `meson-dw-hdmi` | `CONFIG_DRM_MESON=y`、`CONFIG_DRM_MESON_DW_HDMI=y` |
| GPU | Panfrost | `CONFIG_DRM_PANFROST=m` |
| 音频 | AXG sound card | `CONFIG_SND_MESON_AXG_*`、`CONFIG_SND_MESON_G12A_TOHDMITX`、`CONFIG_SND_MESON_G12A_TOACODEC` |
| 视频硬解 | `meson_vdec` | `CONFIG_VIDEO_MESON_VDEC=m` |
| USB | DWC3 + xHCI | `CONFIG_USB_DWC3_MESON_G12A=y`、`CONFIG_USB_XHCI_HCD=y` |
| RTC | `rtc_meson_vrtc` | `CONFIG_RTC_DRV_MESON_VRTC=m` |
| 看门狗 | Meson watchdog | `CONFIG_MESON_WATCHDOG=y` |
| 红外 | `meson_ir` | `CONFIG_IR_MESON=m`（可关） |

**关闭项**（按需求不使用无线）：

```text
CONFIG_WLAN
CONFIG_CFG80211
CONFIG_MAC80211
CONFIG_RTW88 / RTW88_SDIO / RTW88_8822B / RTW88_8822BS
CONFIG_BT / BT_HCIUART / BT_HCIUART_RTL
CONFIG_RFKILL
```

---

## 4. 构建环境

| 项目 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04（noble），6 核，23GiB 内存 |
| 工作目录 | `/data/x96-build` |
| ophub 仓库 | `/data/x96-build/amlogic-s9xxx-armbian` |
| 内核源码 | `/opt/linux/src/linux-7.2.12` |
| 内核构建目录 | `/data/x96-build/kbuild-7.2.12` |
| 交叉工具链 | `aarch64-linux-gnu-gcc` 13.3.0 |
| 模拟器 | `qemu-aarch64-static` + binfmt（用于 arm64 chroot） |

安装依赖：

```bash
cd /data/x96-build/amlogic-s9xxx-armbian
sudo apt-get update
sudo apt-get install -y $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)
```

---

## 5. 内核 7.2.12 源码编译

### 5.1 源码与配置

> 本次最终 `.config` 已保存到 `x96max/kernel/config-7.2.12-x96`；直接复制即可复现。下面是从 6.18 基线重建/理解配置的步骤。

源码：`/opt/linux/src/linux-7.2.12`（Makefile：`VERSION=7 PATCHLEVEL=2 SUBLEVEL=12`）。

先清理源码树（树内构建产物会导致 out-of-tree 构建报错）：

```bash
cd /opt/linux/src/linux-7.2.12
make ARCH=arm64 mrproper
```

以内核 6.18 的 ophub stable 配置为基线，适配 7.2.12：

```bash
OUT=/data/x96-build/kbuild-7.2.12
mkdir -p "$OUT"
cp /tmp/ophub-cfg/config-6.18 "$OUT/.config"
```

关闭 debug info/BTF（否则体积和时间显著增加）：

```bash
cd /opt/linux/src/linux-7.2.12
for s in DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES \
         DEBUG_INFO_DWARF5 DEBUG_INFO_COMPRESSED_NONE \
         DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_DWARF4 \
         DEBUG_INFO_REDUCED DEBUG_INFO_SPLIT; do
  ./scripts/config --file "$OUT/.config" -d "$s"
done
./scripts/config --file "$OUT/.config" -e DEBUG_INFO_NONE
```

关闭无线/BT：

```bash
for s in WLAN CFG80211 MAC80211 RTW88 RTW88_SDIO RTW88_8822B \
         RTW88_8822BS BT BT_HCIUART BT_HCIUART_RTL RFKILL; do
  ./scripts/config --file "$OUT/.config" -d "$s"
done
```

设置本内核签名：

```bash
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-x96"/' "$OUT/.config"
```

生成最终 `.config`：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

关键项检查：

```bash
grep -E 'CONFIG_(DWMAC_MESON|STMMAC_ETH|REALTEK_PHY|MDIO_BUS_MUX_MESON_G12A|MMC_MESON_GX|DRM_MESON|DRM_MESON_DW_HDMI|DRM_PANFROST|VIDEO_MESON_VDEC|USB_DWC3_MESON_G12A|USB_XHCI_HCD|SND_MESON_AXG_SOUND_CARD|SND_MESON_G12A_TOHDMITX)' "$OUT/.config" | sort
grep -E 'CONFIG_(WLAN|RTW88|BT|BT_HCIUART|RFKILL)' "$OUT/.config" | sort
```

### 5.2 编译

```bash
cd /opt/linux/src/linux-7.2.12
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j5 Image modules
```

只编译需要的 DTB（不要直接 `make dtbs`，会构建所有 ARM64 板型）：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  amlogic/meson-g12a-x96-max.dtb
```

> DTB 目标要写成 `amlogic/...`；写成 `arch/arm64/boot/dts/amlogic/...` 会被 Makefile 再次拼接，报目标不存在。

安装 modules 到临时目录：

```bash
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$OUT/modules" modules_install
```

产物：

```text
$OUT/arch/arm64/boot/Image
$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb
$OUT/modules/lib/modules/7.2.12-x96/
```

> 后台编译务必用 `setsid`/`nohup` 脱离当前 shell；否则终端超时会终止整个进程组。
> 不要用 `pkill -f kbuild-7.2.12`，会匹配到当前 shell 自身；用进程组 `kill -- -PGID`。

---

## 6. 生成 arm64 initrd / uInitrd

`uInitrd` 必须是 **arm64**，不能在 x86 主机上直接 `update-initramfs`。做法：用 arm64 rootfs + `qemu-aarch64-static` chroot。

```bash
# 1) 用基础镜像或最终镜像的 rootfs 分区
IMG=/data/x96-build/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
LOOP=$(sudo losetup -Pf --show "$IMG")
sudo mkdir -p /mnt/x96root
sudo mount ${LOOP}p2 /mnt/x96root

# 2) 放入新内核与模块
sudo cp -a "$OUT/modules/lib/modules/7.2.12-x96" /mnt/x96root/lib/modules/
sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-7.2.12-x96
sudo cp "$OUT/.config" /mnt/x96root/boot/config-7.2.12-x96
sudo cp "$OUT/System.map" /mnt/x96root/boot/System.map-7.2.12-x96

# 3) chroot 生成 initrd
sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c \
  "depmod -a 7.2.12-x96 && update-initramfs -c -k 7.2.12-x96"

# 4) 取出 initrd 并做 uInitrd
sudo cp /mnt/x96root/boot/initrd.img-7.2.12-x96 /data/x96-build/
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
  -d /data/x96-build/initrd.img-7.2.12-x96 /data/x96-build/uInitrd-7.2.12-x96
```

---

## 7. 打包成 ophub 可用的内核文件

`rebuild` 需要 4 个压缩包，目录：

```text
/data/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/
├── boot-7.2.12-x96.tar.gz
├── dtb-amlogic-7.2.12-x96.tar.gz
├── modules-7.2.12-x96.tar.gz
├── header-7.2.12-x96.tar.gz
└── sha256sums
```

参考 ophub 6.18 包的布局：

```text
boot-6.18.59-ophub.tar.gz
├── config-6.18.59-ophub
├── initrd.img-6.18.59-ophub
├── System.map-6.18.59-ophub
├── uInitrd-6.18.59-ophub
└── vmlinuz-6.18.59-ophub

modules-6.18.59-ophub.tar.gz
└── 6.18.59-ophub/...
```

对应 7.2.12：

```bash
K=/data/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
mkdir -p "$K/boot" "$K/dtb" "$K/modules" "$K/header"

# boot
cp "$OUT/.config"                      "$K/boot/config-7.2.12-x96"
cp "$OUT/System.map"                   "$K/boot/System.map-7.2.12-x96"
cp "$OUT/arch/arm64/boot/Image"        "$K/boot/vmlinuz-7.2.12-x96"
cp /data/x96-build/initrd.img-7.2.12-x96 "$K/boot/initrd.img-7.2.12-x96"
cp /data/x96-build/uInitrd-7.2.12-x96    "$K/boot/uInitrd-7.2.12-x96"
tar -czf "$K/boot-7.2.12-x96.tar.gz" -C "$K/boot" .

# dtb（只放需要的）
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-7.2.12-x96.tar.gz" -C "$K/dtb" .

# modules
tar -czf "$K/modules-7.2.12-x96.tar.gz" -C "$OUT/modules/lib/modules" 7.2.12-x96

# header：按 ophub collect_headers 规则生成（scripts、include/generated、.config 等）
# 完整可执行命令见 19.5；也可用 compile-kernel 的打包逻辑生成，确保 rebuild 能找到 header-*.tar.gz

(cd "$K" && sha256sum *.tar.gz > sha256sums)
```

> `rebuild` 会检查 `boot-*`、`dtb-amlogic-*`、`modules-*`、`header-*` 四个包都存在；缺一个会报 `The 4 kernel missing.`

---

## 8. 用 ophub rebuild 打包镜像

基础镜像放在：

```text
/data/x96-build/amlogic-s9xxx-armbian/build/output/images/*-trunk_*.img
```

执行：

```bash
cd /data/x96-build/amlogic-s9xxx-armbian
sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96custom
```

参数：

| 参数 | 含义 |
|---|---|
| `-b s905x2` | 板型代号（model_database.conf 第 301 行 X96-Max-4GB） |
| `-k 7.2.12` | 使用本地 `build-armbian/kernel/stable/7.2.12/` |
| `-s 512/2560` | BOOTFS 512MiB / ROOTFS 2560MiB |
| `-n x96custom` | 构建者签名 |

产物：

```text
build/output/images/Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_*.img.gz
```

---

## 9. rootfs 裁剪（自定义默认包）

`rebuild` 只负责替换板级内核/U-Boot，**不会自动裁剪**基础镜像的包。当前基础镜像约 484 个包、2.0GiB。

### 9.1 保留

```text
systemd / udev / systemd-networkd / systemd-resolved
openssh-server
iproute2 / iputils-ping / ethtool
ca-certificates / curl / wget / rsync
e2fsprogs / dosfstools / kmod / procps / util-linux
bash / coreutils / findutils / grep / sed / gawk
tzdata / locales（可选）
initramfs-tools
```

### 9.2 移除（示例）

```text
build-essential gcc g++ cpp make autoconf automake libtool
bison flex binutils dkms device-tree-compiler
git git-man patch libc6-dev linux-libc-dev
python3-dev libpython3-dev
armbian-config armbian-zsh zsh aptitude apt-file debsums
plymouth armbian-plymouth-theme fonts-* fontconfig
vim man-db manpages groff-base info html2text
bluez wpasupplicant wireless-regdb iw rfkill
f2fs-tools btrfs-progs nfs-kernel-server rpcbind avahi-*
htop iotop iozone3 iperf3 fping expect dialog whiptail figlet bc
```

### 9.3 chroot 裁剪

```bash
IMG=/data/x96-build/amlogic-s9xxx-armbian/build/output/images/<final>.img
LOOP=$(sudo losetup -Pf --show "$IMG")
sudo mount ${LOOP}p2 /mnt/x96root
sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/

sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y <移除列表>
  apt-get autoremove --purge -y
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /root/.cache
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
'
```

### 9.4 网络与 SSH

```bash
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c '
  echo x96max > /etc/hostname
  cat > /etc/systemd/network/20-eth.network <<EOF
[Match]
Name=eth0
[Network]
DHCP=yes
EOF
  systemctl enable systemd-networkd systemd-resolved ssh
  mkdir -p /root/.ssh
  # 公钥从 ~/.ssh/id_ed25519.pub 写入
  systemctl disable NetworkManager 2>/dev/null || true
'
```

### 9.5 固件裁剪

只保留有线/显示/音频需要的固件，删除无线：

```bash
sudo rm -rf /mnt/x96root/lib/firmware/rtw88
sudo rm -rf /mnt/x96root/lib/firmware/rtl_bt
sudo rm -rf /mnt/x96root/lib/firmware/brcm
# 保留 rtl_nic（RTL8211F 可能使用）、amlogic、meson 等
```

清理后卸载、重新压缩：

```bash
sudo umount /mnt/x96root/{dev,proc,sys}
sudo umount /mnt/x96root
sudo losetup -d "$LOOP"
gzip -9 -k -f "$IMG"
```

---

## 10. 写 U 盘与启动验证

### 10.1 写盘（在主电脑上）

```bash
lsblk -o NAME,SIZE,MODEL,TRAN          # 先确认 U 盘设备，不要选错
sudo dd if=<final>.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

> `dd` 会覆盖整个 U 盘；务必确认 `/dev/sdX` 是 U 盘，不是系统盘。

### 10.2 盒子从 U 盘启动

- X96 Max 的 U-Boot 通常 **USB 启动优先于 eMMC**。
- 插入 U 盘、上电；若仍进 eMMC：
  - 通过 SSH 把 eMMC 的 `/boot/boot.scr` 改名：`mv /boot/boot.scr /boot/boot.scr.bak`，再重启。
  - 或从串口/HDMI 看 U-Boot 输出，手动 `usb start; usb storage`。

### 10.3 验证

```bash
ssh root@<新IP>
ip -brief addr
ethtool eth0
ip route
systemctl status systemd-networkd
lsmod
dmesg | grep -iE "meson8b-dwmac|RTL8211F|panfrost|meson-drm|snd|mmc"
aplay -l
```

预期：

- `eth0` 有 IPv4，`RTL8211F` 链路 1Gbps
- SSH 可登录
- 无 `rtw88` / `bt` 模块
- `panfrost`、`meson-drm`、AXG 音频、`meson_vdec` 正常

---

## 11. 安装到 eMMC（本机最终成功方法）

**本机必须使用主线 U-Boot**。X96 Max S905X2 在 6.18/7.2 内核下：

- 用原厂 U-Boot + `u-boot.emmc` 重载 → eMMC 黑屏
- 手工 rsync / 只替换 p1、p2 → eMMC 黑屏
- **`armbian-install -m yes -a no` → 成功**

从 SD/U 盘启动后执行：

```bash
armbian-install -m yes -a no
# 设备选择 301（X96-Max-4GB,Tx5-Max）
# 文件系统选择 1（ext4）
```

参数含义：

- `-m yes`：写主线 U-Boot `x96max-u-boot.bin.sd.bin`
- `-a no`：禁用 ampart，使用主线 U-Boot 的固定布局

成功后的实际分区布局：

```text
mmcblk1p1  511M  FAT32 BOOT_EMMC   start=139264 sectors  (68MiB)
mmcblk1p2  56.9G ext4  ROOTFS_EMMC start=2764800 sectors (1350MiB)
```

`/etc/ophub-release` 关键值：

```text
MLUBOOT_STATUS='yes'
MAINLINE_UBOOT='/usr/lib/u-boot/x96max-u-boot.bin.sd.bin'
AMPART_STATUS='no'
DISK_TYPE='emmc'
ROOTFS_TYPE='ext4'
```

安装完成后：关机 → 拔 SD/U 盘 → 上电，从 eMMC 启动。

> 旧的手工 `rsync`/只替换 p1、p2 方法会黑屏，不要再用。
> 写主线 U-Boot 会覆盖 eMMC 启动区，安装前必须备份；备份在 NAS `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`（本地暂存 `~/x96-backup/emmc-original-backup/`）。

---

## 12. 风险与回滚

1. **不要先写 eMMC**：先在 U 盘验证网络/SSH/驱动。
2. **保留商家原镜像/备份**：U 盘可启动 + eMMC 备份是最低要求。
3. **U-Boot**：本机最终使用**主线 U-Boot**（`-m yes`），不是原厂 U-Boot；这是解决 eMMC 黑屏的关键。
   - 写主线 U-Boot 会覆盖 eMMC 启动区，**必须先备份**：原厂启动区 117MiB、p1、p2 在 NAS `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`（本地暂存 `~/x96-backup/emmc-original-backup/`）。
   - 手工只替换 p1/p2 而不写主线 U-Boot，会黑屏；不要再用。
   - 若要回退原厂系统：从 SD 启动，把备份的启动区/p1/p2 写回，或按原厂线刷流程恢复。
4. **eMMC 前 117MiB 保留区**不要手写。
5. **失败恢复**：
   - 仍能 USB 启动：重新写 U 盘镜像即可。
   - 不能 USB 启动：用 Amlogic USB Burning Tool + 原厂/备份镜像救砖（需 USB 双公头线）。
6. 凭据只放 `~/.env`，不要写进仓库。

---

## 13. 当前进度

| 步骤 | 状态 |
|---|---|
| 硬件/系统/驱动分析 | 完成 |
| ophub 构建环境 | 完成 |
| 基础镜像 + 6.18.59 重打包（未裁剪，用于验证流程） | 完成 |
| 7.2.12 源码与配置（有线-only，关闭 Wi-Fi/BT） | 完成 |
| 7.2.12 `Image` / `modules` 编译 | 完成 |
| DTB `meson-g12a-x96-max.dtb` | 完成 |
| initrd / uInitrd | 完成（arm64 chroot 生成） |
| 内核 4 个 tar 包 | 完成 |
| `rebuild` 最终镜像 | 完成 |
| rootfs 裁剪（第一版验证） | 完成（484 → 312 包） |
| 源码 rootfs（Armbian build + mmdebstrap） | 完成（253 包，6:52） |
| 源码 rootfs 注入 + `rebuild` | 完成（7.2.12-x96） |
| SD/U 盘启动验证 | 完成（源码系统 `x96src`） |
| eMMC 安装 | 完成（主线 U-Boot，`-m yes -a no`） |
| eMMC 启动验证 | 完成（源码系统，`/dev/mmcblk1p2`，7.2.12-x96） |

> 最终 rootfs 是 **Armbian build framework + mmdebstrap 源码构建**；内核 7.2.12 是自编译。

---

## 14. 关键路径速查

```text
构建仓库      /data/x96-build/amlogic-s9xxx-armbian
Armbian build /data/x96-build/armbian-build
源码 rootfs   /data/x96-build/armbian-build/cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst
内核源码      /opt/linux/src/linux-7.2.12
内核构建      /data/x96-build/kbuild-7.2.12
基础镜像      /data/x96-build/amlogic-s9xxx-armbian/build/output/images/
内核包目录    /data/x96-build/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12/
最终镜像      /data/x96-build/amlogic-s9xxx-armbian/build/output/images/
仓库脚本      /home/quqiufeng/kernel/x96max/
输出镜像      /data/x96-build/recovery/x96src-autoinstall.img.gz
源码镜像      Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz
eMMC 备份     dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/
NAS 备份目录  dav://192.168.1.53:5005/sata11-18072858035/x96-backup/
              http://192.168.1.53:5005/sata11-18072858035/x96-backup/
              含 x96src-autoinstall.img.gz、x96src-fixed.img.gz、
              x96src-small.img.gz、emmc-original-backup/、SHA256SUMS
本地暂存      ~/x96-backup/
设备          root@192.168.1.121（DHCP，可能变化；ssh 用 IP）
```

---

## 15. 本次踩坑（重要）

1. **不要直接用 USB 镜像的 p1 覆盖 eMMC p1**：会把 `aml_autoscript` / `u-boot.emmc` 带进去，eMMC 黑屏。
2. **不要手工 rsync p1/p2**：即使 UUID、fstab 都正确，eMMC 启动脚本不对也会黑屏。
3. **`armbian-install` 默认 `-a yes` 不够**：本机必须用 `-m yes -a no`（主线 U-Boot + 禁用 ampart）。
4. **`u-boot.emmc` 是 6.x+ 内核的重载 U-Boot**：原厂 U-Boot + 它会黑屏；主线 U-Boot 流程可以正常接管。
5. **eMMC 启动验证前先 SD 启动**：SD 是可靠的救援盘；失败可随时插 SD 回来修。
6. **Amlogic Maskrom 的 `update` 工具在本机控制传输不稳定**：T95 的 Allwinner FEL 经验不能直接套用；能 SD 启动就不要再纠结 Maskrom。
7. **备份先行**：原厂启动区 117MiB、p1、p2 都在 `dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`；写主线 U-Boot 前必须保留。

---

## 16. 源码 rootfs 构建（Armbian build framework，最终方案）

> 目标：不用 ophub 预编译 rootfs，也不靠手工裁剪；用官方 Armbian build framework + mmdebstrap 从 Debian trixie 包构建 rootfs，再与自编译 7.2.12 内核打包。

### 16.1 构建 rootfs

> 仓库内已提供 `x96max/build-image.sh`，会自动安装 `x96max/config-x96-source.conf` 并执行以下步骤；也可按本节手工执行。

```bash
git clone https://github.com/armbian/build /data/x96-build/armbian-build
cd /data/x96-build/armbian-build

./compile.sh rootfs \
  BOARD=odroidn2 BRANCH=current RELEASE=trixie \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  EXPERT=yes PREFER_DOCKER=no ARTIFACT_IGNORE_CACHE=yes
```

关键：

- `BOARD=odroidn2`：官方 Armbian 没有 X96 Max 板型；沿用商家镜像的 OdroidN2 基础（`/etc/armbian.txt` 也是 Odroidn2）。
- `ARTIFACT_IGNORE_CACHE=yes`：**必须**。否则 Armbian 会从 ghcr.io 拉预编译 rootfs 缓存，不是源码构建。
- 原生 x86 构建会用 `mmdebstrap` + qemu 构建 arm64 rootfs；实测约 **6:52**。
- 产物：`cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst`（约 108M）。

### 16.2 注入通用 Armbian 镜像

`rebuild` 需要 `.img` 基础镜像。把源码 rootfs 替换进官方通用镜像：

```bash
BASE=.../Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img
R=.../cache/rootfs/rootfs-arm64-trixie-minimal_*.tar.zst
LOOP=$(sudo losetup -Pf --show "$BASE"); sudo mount ${LOOP}p1 /mnt/base-root
sudo rsync -a /mnt/base-root/boot/ /data/x96-build/base-boot-backup/
sudo find /mnt/base-root -mindepth 1 -maxdepth 1 -exec rm -rf {} +
zstd -dc "$R" | sudo tar -xpf - --numeric-owner --xattrs --xattrs-include='*' -C /mnt/base-root
sudo rsync -a /data/x96-build/base-boot-backup/ /mnt/base-root/boot/
# 源码 rootfs 是空目录结构，rebuild 需要这两个目录
sudo mkdir -p /mnt/base-root/usr/lib/modules /mnt/base-root/usr/src
# SSH/网络
sudo mkdir -p /mnt/base-root/root/.ssh
sudo cp ~/.ssh/id_ed25519.pub /mnt/base-root/root/.ssh/authorized_keys
# 设置 root 密码、sshd_config、/etc/systemd/network/20-eth.network
sudo umount /mnt/base-root; sudo losetup -d "$LOOP"
```

### 16.3 打包 7.2.12 镜像

```bash
cd /data/x96-build/amlogic-s9xxx-armbian
sudo ./rebuild -b s905x2 -k 7.2.12 -s 512/2560 -n x96src
```

产物：

```text
build/output/images/Armbian_26.11.0_amlogic_s905x2_trixie_7.2.12_server_2026.11.02.img.gz (375M)
```

- 首次 `rebuild` 若报 `tar: .../usr/lib/modules: No such file`，就是 16.2 的两个目录没建。
- `rm: ... Device or resource busy` 来自上一次失败 `rebuild` 的临时挂载；清理 `build/tmp_dir` 的 loop mount 即可，不影响本次产物。

### 16.4 写盘与验证

```bash
sudo dd if=<source>.img of=/dev/sdX bs=4M status=progress conv=fsync
```

盒子按复位从 U 盘/SD 启动，确认：

```text
hostname  x96src
uname -r  7.2.12-x96
findmnt / /dev/sda2（U 盘）或 /dev/mmcblk0p2（SD）
```

### 16.5 安装到 eMMC

从源码系统启动后：

```bash
armbian-install -m yes -a no
# 301 / ext4
```

关机、拔 U 盘/SD、上电；eMMC 启动后：

```text
hostname  x96src
uname -r  7.2.12-x96
findmnt / /dev/mmcblk1p2
dpkg -l | grep -c ^ii   # 253
```

- `/etc/ophub-release`：`MLUBOOT_STATUS='yes'`、`MAINLINE_UBOOT='/usr/lib/u-boot/x96max-u-boot.bin.sd.bin'`、`AMPART_STATUS='no'`。
- eMMC 布局：p1 68MiB 起 511M，p2 1350MiB 起 56.9G。

### 16.6 结果

最终系统 = **源码构建 rootfs（Armbian 26.8.3 trixie，从 253 包裁剪到 155 包）+ 自编译 Linux 7.2.12-x96 + 主线 U-Boot**。  
Wi-Fi/蓝牙模块未启用；有线 RTL8211F 1Gbps；Panfrost/AXG audio/meson_vdec 正常。  
裁剪后 rootfs 约 568M，`/lib/firmware` 9.4M，`/usr/share` 14M。

## 17. 源码构建踩坑

1. `ARTIFACT_IGNORE_CACHE=yes` 必须加，否则拿到的是 OCI 预编译 rootfs。
2. `rebuild` 要求 rootfs 存在 `/usr/lib/modules` 和 `/usr/src`；源码 rootfs 没有，需手动创建。
3. 源码 rootfs 的 `/boot` 是空的；注入基础镜像时先备份/恢复基础镜像的 `/boot`，再由 `rebuild` 替换内核。
4. 源码 rootfs 的时间戳可能超前，`tar` 会刷 `time stamp ... is in the future`，无害。
5. 源码 rootfs 默认 253 包；如要更小，可在 `userpatches/customize-image.sh` 或构建后继续裁。

---

## 18. 体积裁剪（最终，155 包）

在源码系统上执行 `apt-get purge --auto-remove`，**253 → 155 包**，不碰 `openssh-server` / `systemd` / `apt` / `initramfs-tools`。

移除列表（显式包；依赖会连带删除，共 96 个）：

```text
# 无线
iw wpasupplicant wireless-regdb
# 本地控制台/键盘
console-setup console-setup-linux kbd keyboard-configuration xkb-data
# 文档/交互工具
man-db groff-base debsums figlet toilet toilet-fonts
htop jq lsof dialog bc bash-completion nano less
# 存储/硬件工具
btrfs-progs mtd-utils mmc-utils gpiod pahole usbutils wireguard-tools
parted fdisk dosfstools dmsetup apt-utils debconf-utils
# 服务
cron cron-daemon-common rsyslog logrotate fake-hwclock
# 音频/网络工具
alsa-utils curl wget rsync
# 其他
sudo u-boot-tools perl perl-modules-5.40 locales
```

清理文件：

```bash
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
       /usr/share/locale/* /usr/share/fonts/* /usr/share/i18n/*
rm -rf /usr/src/linux-headers-*
rm -f  /usr/lib/modules/7.2.12-x96/build
cd /lib/firmware
for d in *; do [ -d "$d" ] || continue; case "$d" in rtl_nic|amlogic|meson) ;; *) rm -rf "$d" ;; esac; done
rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/* /var/log/*
apt-get clean
```

apt 源改为清华 IPv4（原 `deb.debian.org` 的 IPv6 会超时）：

```bash
# /etc/apt/sources.list.d/debian.sources
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian
URIs: http://mirrors.tuna.tsinghua.edu.cn/debian-security
# /etc/apt/apt.conf.d/99force-ipv4
Acquire::ForceIPv4 "true";
```

结果（重启后实测）：

```text
包数      155
rootfs    568M used
firmware  9.4M
/usr/share 14M
内核      7.2.12-x96
网络      eth0 1Gbps
固件缺失  无
failed units 无
```

需要时可随时装回：

```bash
apt-get install -y nano less curl wget rsync sudo alsa-utils
apt-get install -y sudo u-boot-tools parted btrfs-progs   # 以后要 armbian-install / 内核更新
```

---

## 19. 从源码到 eMMC：端到端操作流程

> 本节是按顺序执行的清单；原理、参数解释和踩坑见第 4–18 节。仓库脚本在 `x96max/`。

### 19.1 产物与前置

| 项 | 值 |
|---|---|
| 构建机 | x86_64 Ubuntu 24.04，6 核 / 23GiB（实测） |
| 工作目录 | `/data/x96-build` |
| 内核源码 | `/opt/linux/src/linux-7.2.12` |
| 内核构建 | `/data/x96-build/kbuild-7.2.12` |
| ophub 仓库 | `/data/x96-build/amlogic-s9xxx-armbian` |
| Armbian build | `/data/x96-build/armbian-build` |
| 基础镜像 | `.../build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img` |
| 仓库脚本 | `x96max/build-image.sh`、`config-x96-source.conf`、`x96-autoinstall.*` |
| 最终内核配置 | `x96max/kernel/config-7.2.12-x96` |
| 输出镜像 | `/data/x96-build/recovery/x96src-autoinstall.img.gz` |

> 基础镜像约 2.5G、内核 4 个 tar 包、rootfs 缓存和 recovery 镜像都**不入库**；仓库只保留脚本和配置。

### 19.2 一次性准备

```bash
sudo apt-get update
sudo apt-get install -y \
  git curl wget rsync zstd xz-utils cpio kmod openssl sudo \
  build-essential flex bison bc libssl-dev libelf-dev libncurses-dev \
  qemu-user-static binfmt-support u-boot-tools aarch64-linux-gnu-gcc

# ophub（rebuild + kernel packaging）
git clone --depth 1 https://github.com/ophub/amlogic-s9xxx-armbian \
  /data/x96-build/amlogic-s9xxx-armbian
cd /data/x96-build/amlogic-s9xxx-armbian
sudo apt-get install -y \
  $(cat compile-kernel/tools/script/ubuntu2404-build-armbian-depends)

# Armbian build framework（源码 rootfs）
git clone https://github.com/armbian/build /data/x96-build/armbian-build

# 内核源码：本次使用 /opt/linux/src/linux-7.2.12
# 基础镜像：放到上面的默认路径，或通过 X96_BASE_IMAGE 指定
```

### 19.3 编译内核 7.2.12-x96

```bash
REPO=/home/quqiufeng/kernel
KSRC=/opt/linux/src/linux-7.2.12
OUT=/data/x96-build/kbuild-7.2.12

# 仅首次或源码树有树内产物时执行；会删除 .config
# (cd "$KSRC" && make ARCH=arm64 mrproper)

mkdir -p "$OUT"
cp "$REPO/x96max/kernel/config-7.2.12-x96" "$OUT/.config"

cd "$KSRC"
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image modules
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  amlogic/meson-g12a-x96-max.dtb
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  INSTALL_MOD_PATH="$OUT/modules" modules_install
```

产物：

```text
$OUT/arch/arm64/boot/Image
$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb
$OUT/modules/lib/modules/7.2.12-x96/
```

检查：

```bash
grep '^CONFIG_LOCALVERSION=' "$OUT/.config"   # "-x96"
```

### 19.4 生成 arm64 initrd / uInitrd

用基础镜像的 rootfs + `qemu-aarch64-static` chroot：

```bash
ROOT=/data/x96-build
OUT=$ROOT/kbuild-7.2.12
BASE=$ROOT/amlogic-s9xxx-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.60.img

LOOP=$(sudo losetup -Pf --show "$BASE")
sudo mkdir -p /mnt/x96root
sudo mount "${LOOP}p2" /mnt/x96root

sudo cp -a "$OUT/modules/lib/modules/7.2.12-x96" /mnt/x96root/lib/modules/
sudo cp "$OUT/arch/arm64/boot/Image" /mnt/x96root/boot/vmlinuz-7.2.12-x96
sudo cp "$OUT/.config" /mnt/x96root/boot/config-7.2.12-x96
sudo cp "$OUT/System.map" /mnt/x96root/boot/System.map-7.2.12-x96

sudo mount --bind /dev  /mnt/x96root/dev
sudo mount --bind /proc /mnt/x96root/proc
sudo mount --bind /sys  /mnt/x96root/sys
sudo cp /usr/bin/qemu-aarch64-static /mnt/x96root/usr/bin/
sudo chroot /mnt/x96root /usr/bin/qemu-aarch64-static /bin/bash -c \
  "depmod -a 7.2.12-x96 && update-initramfs -c -k 7.2.12-x96"
sudo cp /mnt/x96root/boot/initrd.img-7.2.12-x96 "$ROOT/"

sudo umount /mnt/x96root/sys /mnt/x96root/proc /mnt/x96root/dev
sudo umount /mnt/x96root
sudo losetup -d "$LOOP"

mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
  -d "$ROOT/initrd.img-7.2.12-x96" "$ROOT/uInitrd-7.2.12-x96"
```

### 19.5 打包 4 个内核包

```bash
ROOT=/data/x96-build
OUT=$ROOT/kbuild-7.2.12
KSRC=/opt/linux/src/linux-7.2.12
K=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/7.2.12
KNAME=7.2.12-x96

mkdir -p "$K"/{boot,dtb,modules,header}

# boot
cp "$OUT/.config"                         "$K/boot/config-$KNAME"
cp "$OUT/System.map"                      "$K/boot/System.map-$KNAME"
cp "$OUT/arch/arm64/boot/Image"           "$K/boot/vmlinuz-$KNAME"
cp "$ROOT/initrd.img-7.2.12-x96"          "$K/boot/initrd.img-$KNAME"
cp "$ROOT/uInitrd-7.2.12-x96"             "$K/boot/uInitrd-$KNAME"
tar -czf "$K/boot-$KNAME.tar.gz" -C "$K/boot" .

# dtb（只放 X96 Max）
cp "$OUT/arch/arm64/boot/dts/amlogic/meson-g12a-x96-max.dtb" "$K/dtb/"
tar -czf "$K/dtb-amlogic-$KNAME.tar.gz" -C "$K/dtb" .

# modules
tar -czf "$K/modules-$KNAME.tar.gz" -C "$OUT/modules/lib/modules" "$KNAME"

# header（复刻 ophub collect_headers；源码树 + out-of-tree 生成物）
H=$K/header
rm -rf "$H"/*
(
  cd "$KSRC"
  head_list=$(mktemp)
  obj_list=$(mktemp)
  {
    find . arch/arm64 -maxdepth 1 -name 'Makefile*'
    find include scripts -type f -o -type l
    find arch/arm64 -name Kbuild.platforms -o -name Platform
    find $(find arch/arm64 -name include -o -name scripts -type d) -type f
  } >"$head_list"
  {
    [[ -n "$(grep '^CONFIG_OBJTOOL=y' "$OUT/include/config/auto.conf" 2>/dev/null)" ]] && echo tools/objtool/objtool
    find arch/arm64/include include scripts -type f
    [[ -f Module.symvers ]] && echo Module.symvers
    [[ -n "$(grep '^CONFIG_GCC_PLUGINS=y' "$OUT/include/config/auto.conf" 2>/dev/null)" ]] && find scripts/gcc-plugins -name '*.so'
  } >"$obj_list"
  tar --exclude '*.orig' -cf - -T "$head_list" | tar -xf - -C "$H"
  tar --exclude '*.orig' -cf - -T "$obj_list"  | tar -xf - -C "$H"
  rm -f "$head_list" "$obj_list"
)
mkdir -p "$H/include" "$H/arch/arm64/include" "$H/scripts"
cp -a "$OUT/include/."                "$H/include/"
cp -a "$OUT/arch/arm64/include/."     "$H/arch/arm64/include/"
cp -a "$OUT/scripts/."                "$H/scripts/"
cp -a "$OUT/.config" "$OUT/Module.symvers" "$H/"
tar -czf "$K/header-$KNAME.tar.gz" -C "$H" .

(cd "$K" && sha256sum *.tar.gz > sha256sums)
ls -lh "$K"
```

> 该 header 配方已在本次构建中校验：生成结果与已有 `header-7.2.12-x96.tar.gz` 的 13800 个文件一致。
>
> `rebuild` 检查 `boot-*`、`dtb-amlogic-*`、`modules-*`、`header-*` 四件套，缺一不可。

### 19.6 构建可刷镜像

> 前提：19.3–19.5 已产出 `boot/dtb-amlogic/modules/header` 四个内核包。

```bash
cd /home/quqiufeng/kernel

# 完整构建：源码 rootfs + 注入 + rebuild + 裁剪 + gzip
./x96max/build-image.sh

# 复用已有 rootfs，只重打包
./x96max/build-image.sh --skip-rootfs

# 直接写 U 盘/SD（危险，确认设备名）
./x96max/build-image.sh --skip-rootfs --write /dev/sdX
```

可用环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `X96_BUILD_ROOT` | `/data/x96-build` | 工作目录 |
| `X96_BASE_IMAGE` | 上面的 6.18.60 通用镜像 | 基础镜像 |
| `X96_ROOT_PASSWORD` | 空 | 默认锁定 root 密码，仅 SSH key；需要控制台密码登录时显式设置 |
| `X96_ROOT_SSH_KEY` | `~/.ssh/id_ed25519.pub` | 写入镜像的 root 公钥 |

脚本会检查 sudo、基础镜像、4 个内核包、auto-install 文件和 rootfs 产物。输出：

```text
/data/x96-build/recovery/x96src-autoinstall.img.gz
```

### 19.7 写盘、首启与 eMMC 安装

```bash
# 写 U 盘/SD（二选一）
gzip -dc /data/x96-build/recovery/x96src-autoinstall.img.gz | \
  sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
# 或
./x96max/build-image.sh --skip-rootfs --write /dev/sdX
```

盒子从 U 盘/SD 启动后确认：

```bash
hostname          # x96src
uname -r          # 7.2.12-x96
findmnt -no SOURCE /
```

镜像内已启用 `x96-autoinstall.service`，首启会自动执行：

```text
armbian-install -m yes -a no
# 301 / ext4
```

查看：

```bash
systemctl status x96-autoinstall
cat /var/log/x96-autoinstall.log
```

安装完成后服务会 `poweroff`；拔掉 U 盘/SD，上电从 eMMC 启动。若自动安装未触发，手动执行：

```bash
armbian-install -m yes -a no
# 设备 301（X96-Max-4GB），文件系统 1（ext4）
```

### 19.8 安装后验证

```bash
hostname
uname -r
findmnt -no SOURCE /
dpkg -l | grep -c '^ii'          # 基础镜像 155；装运行依赖后会增加
ip -br a
aplay -l
arecord -l
v4l2-ctl --list-devices
```

当前盒子装完 LuaJIT/音频/摄像头运行依赖后为 **177 包**；155 是裁剪后的基础系统包数。

### 19.9 回滚与安全

- **不要**用 U 盘镜像的 p1 直接覆盖 eMMC p1；会带入 `u-boot.emmc` 导致黑屏。
- 原厂启动区 117MiB、p1、p2 在 NAS：`dav://192.168.1.53:5005/sata11-18072858035/x96-backup/emmc-original-backup/`。
- eMMC 黑屏时用主线 U-Boot：`armbian-install -m yes -a no`，详见第 11、15 节。
- 产品镜像默认不设 root 密码（脚本留空即锁定），只保留 SSH key；确需控制台密码时再显式设置 `X96_ROOT_PASSWORD='强密码'`。
- 固定基础镜像和内核源码版本/校验和；API key 按设备下发或走后端代理，不能共用同一把 key。

---

*文档版本: 1.4 · 更新: 2026-11-02 · 设备: X96 Max / S905X2*
